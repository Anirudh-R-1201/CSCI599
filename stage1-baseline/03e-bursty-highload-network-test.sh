#!/usr/bin/env bash
set -euo pipefail

# Bursty high-load traffic + network telemetry collector.
# Load generation: k6 (supports stateful checkout flow).
# gRPC s2s probes: fortio-loadgen (health check probes to backend services).
# HTTP s2s probes: s2s-prober pod (curl with dns/connect/ttfb breakdown).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

RUN_ID="${RUN_ID:-$(date +"%Y%m%d-%H%M%S")}"
DATA_DIR_BASE="${ROOT_DIR}/data/${RUN_ID}"
LOAD_DIR="${DATA_DIR_BASE}/loadgen"
NET_DIR="${DATA_DIR_BASE}/network-analysis"

mkdir -p "${LOAD_DIR}" "${NET_DIR}"

# ── Traffic settings ──────────────────────────────────────────────────────────
# Total QPS across all frontend endpoints. At ~160 QPS total a 5-node cluster
# is already under heavy load; spikes go up to QPS_CEIL.
BURSTS="${BURSTS:-18}"
BASE_BURST_SECONDS="${BASE_BURST_SECONDS:-45}"
MAX_BURST_SECONDS="${MAX_BURST_SECONDS:-90}"
MIN_SLEEP_SECONDS="${MIN_SLEEP_SECONDS:-45}"
MAX_SLEEP_SECONDS="${MAX_SLEEP_SECONDS:-120}"
QPS_FLOOR="${QPS_FLOOR:-80}"
QPS_CEIL="${QPS_CEIL:-300}"
SPIKE_PROBABILITY="${SPIKE_PROBABILITY:-0.35}"

# Endpoint weights (must sum to 1.0).
# Checkout is a stateful 2-step flow (add-to-cart → submit); k6 VUs maintain
# their own cookie jar so each VU's cart is independent — checkout actually
# exercises the full downstream call chain on every iteration.
W_HOME="${W_HOME:-0.30}"
W_PRODUCT="${W_PRODUCT:-0.35}"
W_CART="${W_CART:-0.20}"
W_CHECKOUT="${W_CHECKOUT:-0.15}"

export BURSTS BASE_BURST_SECONDS MAX_BURST_SECONDS MIN_SLEEP_SECONDS MAX_SLEEP_SECONDS
export QPS_FLOOR QPS_CEIL SPIKE_PROBABILITY
export W_HOME W_PRODUCT W_CART W_CHECKOUT

# ── Monitoring settings ───────────────────────────────────────────────────────
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-8}"
S2S_PROBE_REPEAT="${S2S_PROBE_REPEAT:-3}"
TARGET_SERVICES_CSV="${TARGET_SERVICES_CSV:-frontend,productcatalogservice,recommendationservice,cartservice,checkoutservice,paymentservice,shippingservice,currencyservice}"

META_FILE="${LOAD_DIR}/bursts.jsonl"
S2S_FILE="${NET_DIR}/service-to-service-latency.jsonl"

echo "=========================================="
echo "Bursty High-Load Network Test (k6)"
echo "=========================================="
echo "Run ID: ${RUN_ID}"
echo "Output: ${DATA_DIR_BASE}"
echo ""

# ── Deploy pods ───────────────────────────────────────────────────────────────
echo "Deploying k6-loadgen (HTTP load) and fortio-loadgen (gRPC probes)..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ROOT_DIR}/k6-loadgen.yaml"    >/dev/null
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ROOT_DIR}/fortio-loadgen.yaml" >/dev/null
kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready pod/k6-loadgen     --timeout=180s >/dev/null
kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready pod/fortio-loadgen --timeout=180s >/dev/null

# Copy k6 script to the load generator pod
kubectl --kubeconfig "${KUBECONFIG_PATH}" cp \
  "${ROOT_DIR}/k6-load-test.js" k6-loadgen:/tmp/k6-load-test.js

# ── s2s probe pod ─────────────────────────────────────────────────────────────
S2S_SOURCE_POD=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" \
  get pods -l app=s2s-prober -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "${S2S_SOURCE_POD}" ]; then
  S2S_SOURCE_POD="fortio-loadgen"
  echo "Using fortio-loadgen for HTTP s2s probes (s2s-prober not found)."
else
  echo "Using ${S2S_SOURCE_POD} for HTTP s2s probes; fortio-loadgen for gRPC probes."
fi
export S2S_SOURCE_POD

# ── gRPC pre-flight check ─────────────────────────────────────────────────────
echo "Running gRPC pre-flight check (fortio-loadgen → productcatalogservice:3550)..."
_pf_err_file="/tmp/grpc-preflight-err-$$"
grpc_preflight_json=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  fortio load -grpc -c 1 -n 1 -qps 0 -json - productcatalogservice:3550 \
  2>"${_pf_err_file}" || true)
grpc_preflight_ok=$(echo "${grpc_preflight_json}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    codes = d.get('RetCodes') or {}
    ok = any(str(k).upper() in ('0','SERVING','OK') for k in codes)
    print('ok:' + str(codes) + (' [SERVING]' if ok else ' [FAILED]'))
except Exception as e:
    print('fail:' + str(e))
" 2>/dev/null || echo "fail:python-error")
if [[ "${grpc_preflight_ok}" == ok:* ]]; then
  echo "  gRPC pre-flight passed: ${grpc_preflight_ok}"
  GRPC_PROBE_ENABLED=1
else
  echo "  ⚠ gRPC pre-flight FAILED: ${grpc_preflight_ok}"
  echo "  stderr: $(cat "${_pf_err_file}" 2>/dev/null | head -3)"
  echo "  → Falling back to HTTP-only s2s probes."
  GRPC_PROBE_ENABLED=0
fi
rm -f "${_pf_err_file}"
export GRPC_PROBE_ENABLED

# ── Service protocol/port map ─────────────────────────────────────────────────
get_service_proto_port() {
  case "$1" in
    frontend)                echo "http:80"    ;;
    productcatalogservice)   echo "grpc:3550"  ;;
    recommendationservice)   echo "grpc:8080"  ;;
    cartservice)             echo "grpc:7070"  ;;
    checkoutservice)         echo "grpc:5050"  ;;
    paymentservice)          echo "grpc:50051" ;;
    shippingservice)         echo "grpc:50051" ;;
    currencyservice)         echo "grpc:7000"  ;;
    emailservice)            echo "grpc:5000"  ;;
    *)                       echo "http:80"    ;;
  esac
}

kubectl --kubeconfig "${KUBECONFIG_PATH}" get hpa -o wide > "${NET_DIR}/hpa-before.txt" || true

# ── Cluster snapshot function ─────────────────────────────────────────────────
capture_cluster_snapshot() {
  local timestamp="$1"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods     -n default -o json > "${NET_DIR}/pod-network-${timestamp}.json"      || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get endpoints -n default -o json > "${NET_DIR}/service-endpoints-${timestamp}.json" || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes     -o json             > "${NET_DIR}/node-network-${timestamp}.json"     || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get hpa       -n default -o json  > "${NET_DIR}/hpa-${timestamp}.json"              || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" top pods -n default --no-headers  > "${NET_DIR}/top-pods-${timestamp}.txt"  2>/dev/null || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" top nodes --no-headers            > "${NET_DIR}/top-nodes-${timestamp}.txt" 2>/dev/null || true
}

# ── s2s latency probe function ────────────────────────────────────────────────
probe_service_latencies() {
  local timestamp="$1"
  local targets="$2"
  local http_pod="${S2S_SOURCE_POD:-fortio-loadgen}"
  local grpc_pod="fortio-loadgen"

  local http_node grpc_node
  http_node=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get pod "${http_pod}" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")
  grpc_node=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get pod "${grpc_pod}" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")

  if [ -z "${http_node}" ] || [ "${http_node}" = "unknown" ]; then
    echo "⚠ probe_service_latencies: ${http_pod} has unknown node, skipping" >&2
    return 0
  fi

  IFS=',' read -ra target_array <<< "${targets}"
  for target in "${target_array[@]}"; do
    local t
    t="$(echo "${target}" | xargs)"
    [ -z "${t}" ] && continue

    local proto_port proto port
    proto_port="$(get_service_proto_port "${t}")"
    proto="${proto_port%%:*}"
    port="${proto_port##*:}"

    for ((k=0; k<S2S_PROBE_REPEAT; k++)); do
      local probe source_pod source_node

      if [ "${proto}" = "grpc" ] && [ "${GRPC_PROBE_ENABLED:-0}" = "1" ]; then
        source_pod="${grpc_pod}"
        source_node="${grpc_node}"
        local raw grpc_err_file
        grpc_err_file="/tmp/grpc-err-${t}-${k}-$$"
        raw=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec "${grpc_pod}" -- \
          fortio load -grpc -c 1 -n 1 -qps 0 -json - "${t}:${port}" \
          2>"${grpc_err_file}" || true)
        if [ -z "${raw}" ]; then
          echo "⚠ gRPC probe empty for ${t}:${port} (stderr: $(cat "${grpc_err_file}" 2>/dev/null | head -1))" >&2
        fi
        rm -f "${grpc_err_file}"
        probe=$(echo "${raw}" | python3 -c "
import json, sys
GRPC_CODE_MAP = {'SERVING': 0, 'NOT_SERVING': 2, 'SERVICE_UNKNOWN': 5,
                 'UNKNOWN': 2, 'UNAVAILABLE': 14, 'OK': 0}
try:
    d = json.load(sys.stdin)
    h = d.get('DurationHistogram') or {}
    avg_ms = float(h.get('Avg', 0)) * 1000
    pcts = {float(p['Percentile']): float(p['Value']) * 1000
            for p in h.get('Percentiles', []) if 'Percentile' in p and 'Value' in p}
    p50_ms = pcts.get(50.0, avg_ms)
    codes = d.get('RetCodes') or {}
    raw_code = sorted(codes.items(), key=lambda x: -x[1])[0][0] if codes else 0
    try:
        numeric_code = int(raw_code)
    except (ValueError, TypeError):
        numeric_code = GRPC_CODE_MAP.get(str(raw_code).upper(), 2)
    print('dns=0 connect=0 ttfb={:.2f} total={:.2f} code={} grpc=1'.format(
        p50_ms, avg_ms, numeric_code))
except Exception as e:
    sys.stderr.write('grpc-probe-parse-error: {}\n'.format(e))
" 2>/dev/null || true)

      elif [ "${proto}" = "grpc" ]; then
        probe=""  # gRPC disabled — skip silently

      elif [ "${http_pod}" = "fortio-loadgen" ]; then
        source_pod="${http_pod}"
        source_node="${http_node}"
        local raw
        raw=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec "${http_pod}" -- \
          fortio load -c 1 -n 1 -qps 0 -json - "http://${t}:${port}/" 2>/dev/null || true)
        probe=$(echo "${raw}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    h = d.get('DurationHistogram') or {}
    avg_ms = float(h.get('Avg', 0)) * 1000
    codes = d.get('RetCodes') or {}
    code = sorted(codes.items(), key=lambda x: -x[1])[0][0] if codes else 0
    print('dns=0 connect={:.2f} ttfb={:.2f} total={:.2f} code={}'.format(
        avg_ms * 0.05, avg_ms * 0.6, avg_ms, int(code)))
except Exception:
    pass
" 2>/dev/null || true)

      else
        source_pod="${http_pod}"
        source_node="${http_node}"
        probe=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec "${http_pod}" -- \
          curl -sS -o /dev/null \
            -w 'dns=%{time_namelookup} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total} code=%{http_code}' \
            --max-time 5 "http://${t}:${port}/" 2>/dev/null || true)
        probe=$(echo "${probe}" | python3 -c "
import sys
s = sys.stdin.read().strip()
out = []
for part in s.split():
    if '=' in part:
        k, v = part.split('=', 1)
        if k == 'code':
            out.append('{}={}'.format(k, v))
        else:
            try:
                out.append('{}={:.2f}'.format(k, float(v) * 1000))
            except ValueError:
                out.append(part)
    else:
        out.append(part)
print(' '.join(out))
" 2>/dev/null || true)
      fi

      if [ -n "${probe}" ]; then
        printf '{"timestamp":"%s","source_pod":"%s","source_node":"%s","target_service":"%s","probe":"%s"}\n' \
          "${timestamp}" "${source_pod}" "${source_node}" "${t}" "${probe}" >> "${S2S_FILE}"
      fi
    done
  done
}

# ── Background monitor loop ───────────────────────────────────────────────────
monitor_loop() {
  while [ ! -f "${NET_DIR}/.monitor-stop" ]; do
    local ts
    ts="$(date +"%Y%m%d-%H%M%S")"
    ( set +e; capture_cluster_snapshot "${ts}"; probe_service_latencies "${ts}" "${TARGET_SERVICES_CSV}"; )
    sleep "${SAMPLE_INTERVAL}"
  done
}

: > "${S2S_FILE}"
: > "${NET_DIR}/monitoring.log"
echo "Starting telemetry monitoring (interval=${SAMPLE_INTERVAL}s)..."
ts0="$(date +"%Y%m%d-%H%M%S")"
( set +e; probe_service_latencies "${ts0}" "${TARGET_SERVICES_CSV}"; ) >> "${NET_DIR}/monitoring.log" 2>&1
monitor_loop >> "${NET_DIR}/monitoring.log" 2>&1 &
MONITOR_PID=$!

# ── Burst plan ────────────────────────────────────────────────────────────────
echo "Generating burst plan..."
python3 - <<'PY' > "${META_FILE}"
import json, os, random, time

bursts      = int(os.environ["BURSTS"])
min_dur     = int(os.environ["BASE_BURST_SECONDS"])
max_dur     = int(os.environ["MAX_BURST_SECONDS"])
min_sleep   = int(os.environ.get("MIN_SLEEP_SECONDS", "2"))
max_sleep   = int(os.environ["MAX_SLEEP_SECONDS"])
min_dur,  max_dur   = min(min_dur,  max_dur),  max(min_dur,  max_dur)
min_sleep, max_sleep = min(min_sleep, max_sleep), max(min_sleep, max_sleep)
qps_floor   = int(os.environ["QPS_FLOOR"])
qps_ceil    = int(os.environ["QPS_CEIL"])
qps_floor,  qps_ceil = min(qps_floor, qps_ceil), max(qps_floor, qps_ceil)
spike_prob  = float(os.environ["SPIKE_PROBABILITY"])
w_home      = float(os.environ["W_HOME"])
w_product   = float(os.environ["W_PRODUCT"])
w_cart      = float(os.environ["W_CART"])
w_checkout  = float(os.environ["W_CHECKOUT"])

random.seed(int(time.time()))
for i in range(bursts):
    if random.random() < spike_prob:
        total_qps  = random.randint(int(0.8 * qps_ceil), qps_ceil)
        burst_type = "spike"
    else:
        pareto     = random.paretovariate(1.25)
        total_qps  = min(qps_ceil, max(qps_floor, int(qps_floor * pareto)))
        burst_type = "heavy_tail"
    print(json.dumps({
        "burst_index": i,
        "burst_type":  burst_type,
        "total_qps":   total_qps,
        "duration_s":  random.randint(min_dur,   max_dur),
        "sleep_s":     random.randint(min_sleep, max_sleep),
        "w_home":      w_home,
        "w_product":   w_product,
        "w_cart":      w_cart,
        "w_checkout":  w_checkout,
    }))
PY

# ── Burst execution ───────────────────────────────────────────────────────────
echo ""
echo "Executing burst schedule..."

while IFS= read -r burst; do
  idx=$(        echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["burst_index"])')
  burst_type=$( echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["burst_type"])')
  total_qps=$(  echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_qps"])')
  duration_s=$( echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["duration_s"])')
  sleep_s=$(    echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sleep_s"])')
  w_home=$(     echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["w_home"])')
  w_product=$(  echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["w_product"])')
  w_cart=$(     echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["w_cart"])')
  w_checkout=$( echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["w_checkout"])')

  echo "Burst ${idx} [${burst_type}] qps=${total_qps} duration=${duration_s}s sleep=${sleep_s}s"

  # Run k6 on the load generator pod.
  # k6 writes its per-endpoint summary to /tmp/k6-burst-{idx}.json on the pod.
  kubectl --kubeconfig "${KUBECONFIG_PATH}" exec k6-loadgen -- \
    k6 run \
      -e TOTAL_QPS="${total_qps}" \
      -e DURATION="${duration_s}s" \
      -e W_HOME="${w_home}" \
      -e W_PRODUCT="${w_product}" \
      -e W_CART="${w_cart}" \
      -e W_CHECKOUT="${w_checkout}" \
      -e BURST_INDEX="${idx}" \
      -e BURST_TYPE="${burst_type}" \
      --no-usage-report \
      /tmp/k6-load-test.js \
    > "${LOAD_DIR}/k6-burst-${idx}.log" 2>&1

  # Copy the summary JSON back from the pod
  kubectl --kubeconfig "${KUBECONFIG_PATH}" cp \
    "k6-loadgen:/tmp/k6-burst-${idx}.json" \
    "${LOAD_DIR}/k6-burst-${idx}.json" 2>/dev/null || \
    echo "  ⚠ Could not retrieve k6-burst-${idx}.json from pod"

  # Immediate telemetry snapshot after each burst
  capture_cluster_snapshot "$(date +"%Y%m%d-%H%M%S")"
  sleep "${sleep_s}"
done < "${META_FILE}"

# ── Cleanup ───────────────────────────────────────────────────────────────────
touch "${NET_DIR}/.monitor-stop"
wait "${MONITOR_PID}" || true
rm -f "${NET_DIR}/.monitor-stop"

s2s_lines=$(wc -l < "${S2S_FILE}" 2>/dev/null || echo "0")
if [ "${s2s_lines}" -eq 0 ]; then
  echo ""
  echo "⚠ WARNING: service-to-service-latency.jsonl is empty. Graphs 07-11 skipped."
  echo "  Log: ${NET_DIR}/monitoring.log"
fi

kubectl --kubeconfig "${KUBECONFIG_PATH}" get hpa -o wide > "${NET_DIR}/hpa-after.txt" || true
kubectl --kubeconfig "${KUBECONFIG_PATH}" get events -n default --sort-by='.lastTimestamp' \
  > "${NET_DIR}/events-scaling.txt" || true

echo ""
echo "=========================================="
echo "Test Complete"
echo "=========================================="
echo "Run ID:            ${RUN_ID}"
echo "k6 burst outputs:  ${LOAD_DIR}/k6-burst-*.json"
echo "k6 logs:           ${LOAD_DIR}/k6-burst-*.log"
echo "Network telemetry: ${NET_DIR}"
echo ""
echo "Next:"
echo "  python3 06-generate-graphs.py data/${RUN_ID}"
echo ""
