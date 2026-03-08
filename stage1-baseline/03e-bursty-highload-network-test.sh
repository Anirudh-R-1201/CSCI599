#!/usr/bin/env bash
set -euo pipefail

# Bursty high-load traffic + network telemetry collector.
# Designed to stress HPAs configured near 75% CPU target.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

RUN_ID="${RUN_ID:-$(date +"%Y%m%d-%H%M%S")}"
DATA_DIR_BASE="${ROOT_DIR}/data/${RUN_ID}"
LOAD_DIR="${DATA_DIR_BASE}/loadgen"
NET_DIR="${DATA_DIR_BASE}/network-analysis"

mkdir -p "${LOAD_DIR}" "${NET_DIR}"

# Traffic settings.
# Longer inter-burst gaps (MIN/MAX_SLEEP) give time for HPA to scale down between bursts.
BURSTS="${BURSTS:-18}"
BASE_BURST_SECONDS="${BASE_BURST_SECONDS:-45}"
MAX_BURST_SECONDS="${MAX_BURST_SECONDS:-90}"
MIN_SLEEP_SECONDS="${MIN_SLEEP_SECONDS:-45}"
MAX_SLEEP_SECONDS="${MAX_SLEEP_SECONDS:-120}"
THREADS_PER_ENDPOINT="${THREADS_PER_ENDPOINT:-12}"
QPS_FLOOR="${QPS_FLOOR:-80}"
QPS_CEIL="${QPS_CEIL:-500}"
SPIKE_PROBABILITY="${SPIKE_PROBABILITY:-0.35}"

# Relative endpoint weights for generated total QPS.
WEIGHT_HOME="${WEIGHT_HOME:-0.45}"
WEIGHT_PRODUCT="${WEIGHT_PRODUCT:-0.35}"
WEIGHT_CART="${WEIGHT_CART:-0.20}"

# Export so inline Python (burst plan) can read them
export BURSTS BASE_BURST_SECONDS MAX_BURST_SECONDS MIN_SLEEP_SECONDS MAX_SLEEP_SECONDS
export QPS_FLOOR QPS_CEIL SPIKE_PROBABILITY
export WEIGHT_HOME WEIGHT_PRODUCT WEIGHT_CART

# Monitoring settings.
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-8}"
S2S_PROBE_REPEAT="${S2S_PROBE_REPEAT:-3}"
TARGET_SERVICES_CSV="${TARGET_SERVICES_CSV:-frontend,productcatalogservice,recommendationservice,cartservice,checkoutservice,paymentservice,shippingservice,currencyservice}"

META_FILE="${LOAD_DIR}/bursts.jsonl"
S2S_FILE="${NET_DIR}/service-to-service-latency.jsonl"

echo "=========================================="
echo "Bursty High-Load Network Test"
echo "=========================================="
echo "Run ID: ${RUN_ID}"
echo "Output: ${DATA_DIR_BASE}"
echo ""

echo "Deploying or refreshing fortio load generator..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ROOT_DIR}/fortio-loadgen.yaml" >/dev/null
kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready pod/fortio-loadgen --timeout=180s >/dev/null

# Prefer s2s-prober for HTTP service-to-service probes (client → boutique services); fall back to fortio-loadgen.
# gRPC services are always probed via fortio-loadgen using fortio's built-in gRPC health check.
S2S_SOURCE_POD=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -l app=s2s-prober -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "${S2S_SOURCE_POD}" ]; then
  S2S_SOURCE_POD="fortio-loadgen"
  echo "Using fortio-loadgen for HTTP s2s probes (s2s-prober not found)."
else
  echo "Using ${S2S_SOURCE_POD} for HTTP s2s probes; fortio-loadgen for gRPC probes."
fi
export S2S_SOURCE_POD

# ── gRPC pre-flight check ─────────────────────────────────────────────────────
# Verify that fortio can run a gRPC probe and produce JSON on stdout.
# Stderr is captured separately so log noise doesn't break JSON parsing.
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
    print('ok:' + str(codes))
except Exception as e:
    print('fail:' + str(e))
" 2>/dev/null || echo "fail:python-error")
if [[ "${grpc_preflight_ok}" == ok:* ]]; then
  echo "  gRPC pre-flight passed: ${grpc_preflight_ok}"
  GRPC_PROBE_ENABLED=1
else
  echo "  ⚠ gRPC pre-flight FAILED: ${grpc_preflight_ok}"
  echo "  stderr: $(cat "${_pf_err_file}" 2>/dev/null | head -3)"
  echo "  stdout: $(echo "${grpc_preflight_json}" | head -3)"
  echo "  → Falling back to HTTP-only s2s probes (gRPC services will show no data)."
  GRPC_PROBE_ENABLED=0
fi
rm -f "${_pf_err_file}"
export GRPC_PROBE_ENABLED

# Map each service to its protocol and port.
# HTTP services are probed via curl (fast timing breakdown: dns/connect/ttfb/total).
# gRPC services are probed via fortio health check (total latency only).
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

echo "Checking HPA targets (expecting 75% if configured that way)..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" get hpa -o wide > "${NET_DIR}/hpa-before.txt" || true

PRODUCT_ID=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  sh -c "curl -s http://frontend:80/ | sed -n 's|.*href=\"/product/\\([^\"]*\\)\".*|\\1|p' | head -1" 2>/dev/null || true)
PRODUCT_ID="${PRODUCT_ID:-OLJCESPC7Z}"

HOME_URL="http://frontend:80/"
PRODUCT_URL="http://frontend:80/product/${PRODUCT_ID}"
CART_URL="http://frontend:80/cart"

capture_cluster_snapshot() {
  local timestamp="$1"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -n default -o json > "${NET_DIR}/pod-network-${timestamp}.json" || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get endpoints -n default -o json > "${NET_DIR}/service-endpoints-${timestamp}.json" || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o json > "${NET_DIR}/node-network-${timestamp}.json" || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get hpa -n default -o json > "${NET_DIR}/hpa-${timestamp}.json" || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" top pods -n default --no-headers > "${NET_DIR}/top-pods-${timestamp}.txt" 2>/dev/null || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" top nodes --no-headers > "${NET_DIR}/top-nodes-${timestamp}.txt" 2>/dev/null || true
}

probe_service_latencies() {
  local timestamp="$1"
  local targets="$2"
  local http_pod="${S2S_SOURCE_POD:-fortio-loadgen}"
  local grpc_pod="fortio-loadgen"

  # Resolve source node for the HTTP prober (used for topology graphs).
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

    local proto_port
    proto_port="$(get_service_proto_port "${t}")"
    local proto="${proto_port%%:*}"
    local port="${proto_port##*:}"

    for ((k=0; k<S2S_PROBE_REPEAT; k++)); do
      local probe source_pod source_node

      if [ "${proto}" = "grpc" ] && [ "${GRPC_PROBE_ENABLED:-0}" = "1" ]; then
        # ── gRPC probe via fortio health check ──────────────────────────────
        # Uses the standard gRPC health check protocol (grpc.health.v1.Health/Check).
        # All Online Boutique gRPC services expose this endpoint (confirmed via K8s grpc probes).
        # NOTE: Do NOT pass -grpc-health-svc "" — some fortio versions emit no JSON with that flag.
        # Just -grpc alone invokes the health check with an empty (server-wide) service name.
        # gRPC codes: 0=OK, 2=UNKNOWN, 12=UNIMPLEMENTED, 14=UNAVAILABLE
        source_pod="${grpc_pod}"
        source_node="${grpc_node}"
        local raw grpc_err_file
        grpc_err_file="/tmp/grpc-err-${t}-${k}-$$"
        raw=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec "${grpc_pod}" -- \
          fortio load -grpc \
            -c 1 -n 1 -qps 0 -json - "${t}:${port}" \
          2>"${grpc_err_file}" || true)
        if [ -z "${raw}" ]; then
          echo "⚠ gRPC probe empty for ${t}:${port} (stderr: $(cat "${grpc_err_file}" 2>/dev/null | head -1))" >&2
        fi
        rm -f "${grpc_err_file}"
        probe=$(echo "${raw}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    h = d.get('DurationHistogram') or {}
    avg_ms = float(h.get('Avg', 0)) * 1000
    pcts = {float(p['Percentile']): float(p['Value']) * 1000
            for p in h.get('Percentiles', []) if 'Percentile' in p and 'Value' in p}
    p50_ms = pcts.get(50.0, avg_ms)
    codes = d.get('RetCodes') or {}
    # Pick the dominant response code (most frequent key in RetCodes)
    code = sorted(codes.items(), key=lambda x: -x[1])[0][0] if codes else 0
    print('dns=0 connect=0 ttfb={:.2f} total={:.2f} code={} grpc=1'.format(
        p50_ms, avg_ms, int(code)))
except Exception as e:
    sys.stderr.write('grpc-probe-parse-error: {}\n'.format(e))
" 2>/dev/null || true)

      elif [ "${proto}" = "grpc" ]; then
        # gRPC probing disabled (pre-flight failed) — skip silently
        probe=""

      elif [ "${http_pod}" = "fortio-loadgen" ]; then
        # ── HTTP probe via fortio (no curl available in fortio image) ────────
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
    # Approximate timing breakdown (fortio HTTP does not expose dns/connect/ttfb separately)
    print('dns=0 connect={:.2f} ttfb={:.2f} total={:.2f} code={}'.format(
        avg_ms * 0.05, avg_ms * 0.6, avg_ms, int(code)))
except Exception:
    pass
" 2>/dev/null || true)

      else
        # ── HTTP probe via curl (s2s-prober pod — gives full timing breakdown) ──
        # curl write-out fields are in seconds; convert to ms.
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
echo "Starting telemetry monitoring in background (interval=${SAMPLE_INTERVAL}s)..."
# One initial probe — output goes to monitoring.log so errors are captured
ts0="$(date +"%Y%m%d-%H%M%S")"
( set +e; probe_service_latencies "${ts0}" "${TARGET_SERVICES_CSV}"; ) >> "${NET_DIR}/monitoring.log" 2>&1
monitor_loop >> "${NET_DIR}/monitoring.log" 2>&1 &
MONITOR_PID=$!

echo "Generating burst plan..."
python3 - <<'PY' > "${META_FILE}"
import json
import os
import random
import time

bursts = int(os.environ["BURSTS"])
min_dur = int(os.environ["BASE_BURST_SECONDS"])
max_dur = int(os.environ["MAX_BURST_SECONDS"])
min_sleep = int(os.environ.get("MIN_SLEEP_SECONDS", "2"))
max_sleep = int(os.environ["MAX_SLEEP_SECONDS"])
# Ensure valid ranges (randint requires min <= max)
min_dur, max_dur = min(min_dur, max_dur), max(min_dur, max_dur)
min_sleep, max_sleep = min(min_sleep, max_sleep), max(min_sleep, max_sleep)
qps_floor = int(os.environ["QPS_FLOOR"])
qps_ceil = int(os.environ["QPS_CEIL"])
qps_floor, qps_ceil = min(qps_floor, qps_ceil), max(qps_floor, qps_ceil)
spike_prob = float(os.environ["SPIKE_PROBABILITY"])

w_home = float(os.environ["WEIGHT_HOME"])
w_prod = float(os.environ["WEIGHT_PRODUCT"])
w_cart = float(os.environ["WEIGHT_CART"])
total_weight = w_home + w_prod + w_cart

random.seed(int(time.time()))

for i in range(bursts):
    # Heavy-tail baseline + occasional extreme spike.
    if random.random() < spike_prob:
        total_qps = random.randint(int(0.8 * qps_ceil), qps_ceil)
        burst_type = "spike"
    else:
        pareto = random.paretovariate(1.25)
        total_qps = min(qps_ceil, max(qps_floor, int(qps_floor * pareto)))
        burst_type = "heavy_tail"

    duration = random.randint(min_dur, max_dur)
    sleep_s = random.randint(min_sleep, max_sleep)

    q_home = max(1, int(total_qps * (w_home / total_weight)))
    q_prod = max(1, int(total_qps * (w_prod / total_weight)))
    q_cart = max(1, total_qps - q_home - q_prod)

    print(json.dumps({
        "burst_index": i,
        "burst_type": burst_type,
        "total_qps": total_qps,
        "duration_s": duration,
        "sleep_s": sleep_s,
        "qps_home": q_home,
        "qps_product": q_prod,
        "qps_cart": q_cart
    }))
PY

echo ""
echo "Executing burst schedule..."
echo "Targeting endpoints concurrently each burst for backend-wide pressure."

while IFS= read -r burst; do
  idx=$(echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["burst_index"])')
  burst_type=$(echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["burst_type"])')
  total_qps=$(echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_qps"])')
  duration_s=$(echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["duration_s"])')
  sleep_s=$(echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sleep_s"])')
  qps_home=$(echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["qps_home"])')
  qps_product=$(echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["qps_product"])')
  qps_cart=$(echo "${burst}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["qps_cart"])')

  echo "Burst ${idx} [${burst_type}] total_qps=${total_qps} duration=${duration_s}s sleep=${sleep_s}s"
  echo "  split: home=${qps_home}, product=${qps_product}, cart=${qps_cart}"

  kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
    fortio load -qps "${qps_home}" -c "${THREADS_PER_ENDPOINT}" -t "${duration_s}s" \
    -p "50,90,95,99,99.9" -abort-on -1 -allow-initial-errors -json - \
    -labels "burst-${idx}-home-${burst_type}" "${HOME_URL}" \
    > "${LOAD_DIR}/fortio-burst-${idx}-home.json" 2> "${LOAD_DIR}/fortio-burst-${idx}-home.log" &
  p1=$!

  kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
    fortio load -qps "${qps_product}" -c "${THREADS_PER_ENDPOINT}" -t "${duration_s}s" \
    -p "50,90,95,99,99.9" -abort-on -1 -allow-initial-errors -json - \
    -labels "burst-${idx}-product-${burst_type}" "${PRODUCT_URL}" \
    > "${LOAD_DIR}/fortio-burst-${idx}-product.json" 2> "${LOAD_DIR}/fortio-burst-${idx}-product.log" &
  p2=$!

  kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
    fortio load -qps "${qps_cart}" -c "${THREADS_PER_ENDPOINT}" -t "${duration_s}s" \
    -p "50,90,95,99,99.9" -abort-on -1 -allow-initial-errors -json - \
    -labels "burst-${idx}-cart-${burst_type}" "${CART_URL}" \
    > "${LOAD_DIR}/fortio-burst-${idx}-cart.json" 2> "${LOAD_DIR}/fortio-burst-${idx}-cart.log" &
  p3=$!

  wait "${p1}" "${p2}" "${p3}"

  # Additional immediate sample right after each burst.
  capture_cluster_snapshot "$(date +"%Y%m%d-%H%M%S")"
  sleep "${sleep_s}"
done < "${META_FILE}"

touch "${NET_DIR}/.monitor-stop"
wait "${MONITOR_PID}" || true
rm -f "${NET_DIR}/.monitor-stop"

# Warn if no s2s data (graphs 07-11 need this)
s2s_lines=$(wc -l < "${S2S_FILE}" 2>/dev/null || echo "0")
if [ "${s2s_lines}" -eq 0 ]; then
  echo ""
  echo "⚠ WARNING: service-to-service-latency.jsonl is empty. Graphs 07-11 will not be generated."
  echo "  Check: kubectl get pod fortio-loadgen; kubectl get pod -l app=s2s-prober"
  echo "  Test:  kubectl exec <s2s-prober-pod> -- curl -s -o /dev/null -w '%{http_code}' http://frontend:80/"
  echo "  Log:   ${NET_DIR}/monitoring.log"
  echo ""
fi

kubectl --kubeconfig "${KUBECONFIG_PATH}" get hpa -o wide > "${NET_DIR}/hpa-after.txt" || true
kubectl --kubeconfig "${KUBECONFIG_PATH}" get events -n default --sort-by='.lastTimestamp' > "${NET_DIR}/events-scaling.txt" || true

echo ""
echo "=========================================="
echo "Test Complete"
echo "=========================================="
echo "Burst metadata: ${META_FILE}"
echo "Fortio outputs: ${LOAD_DIR}/fortio-burst-*-{home,product,cart}.json"
echo "Network telemetry: ${NET_DIR}"
echo ""
echo "Next:"
echo "  ./07-analyze-network-data.py data/${RUN_ID}"
echo ""
