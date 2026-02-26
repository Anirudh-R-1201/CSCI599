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
BURSTS="${BURSTS:-18}"
BASE_BURST_SECONDS="${BASE_BURST_SECONDS:-25}"
MAX_BURST_SECONDS="${MAX_BURST_SECONDS:-75}"
MAX_SLEEP_SECONDS="${MAX_SLEEP_SECONDS:-15}"
THREADS_PER_ENDPOINT="${THREADS_PER_ENDPOINT:-48}"
QPS_FLOOR="${QPS_FLOOR:-180}"
QPS_CEIL="${QPS_CEIL:-1400}"
SPIKE_PROBABILITY="${SPIKE_PROBABILITY:-0.35}"

# Relative endpoint weights for generated total QPS.
WEIGHT_HOME="${WEIGHT_HOME:-0.45}"
WEIGHT_PRODUCT="${WEIGHT_PRODUCT:-0.35}"
WEIGHT_CART="${WEIGHT_CART:-0.20}"

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
  local sources
  sources=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -n default \
    -l "app in (frontend,productcatalogservice,recommendationservice,cartservice,checkoutservice)" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  if [ -z "${sources}" ]; then
    return
  fi

  while IFS= read -r source_pod; do
    [ -z "${source_pod}" ] && continue
    local source_node
    source_node=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get pod "${source_pod}" -n default -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")

    IFS=',' read -ra target_array <<< "${targets}"
    for target in "${target_array[@]}"; do
      local t
      t="$(echo "${target}" | xargs)"
      [ -z "${t}" ] && continue
      for ((k=0; k<S2S_PROBE_REPEAT; k++)); do
        local probe
        probe=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec -n default "${source_pod}" -- \
          sh -c "curl -sS -o /dev/null \
            -w 'dns=%{time_namelookup} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total} code=%{http_code}' \
            --max-time 5 http://${t}:80/" 2>/dev/null || true)

        if [ -n "${probe}" ]; then
          printf '{"timestamp":"%s","source_pod":"%s","source_node":"%s","target_service":"%s","probe":"%s"}\n' \
            "${timestamp}" "${source_pod}" "${source_node}" "${t}" "${probe}" >> "${S2S_FILE}"
        fi
      done
    done
  done <<< "${sources}"
}

monitor_loop() {
  while [ ! -f "${NET_DIR}/.monitor-stop" ]; do
    local ts
    ts="$(date +"%Y%m%d-%H%M%S")"
    capture_cluster_snapshot "${ts}"
    probe_service_latencies "${ts}" "${TARGET_SERVICES_CSV}"
    sleep "${SAMPLE_INTERVAL}"
  done
}

: > "${S2S_FILE}"
echo "Starting telemetry monitoring in background (interval=${SAMPLE_INTERVAL}s)..."
monitor_loop > "${NET_DIR}/monitoring.log" 2>&1 &
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
max_sleep = int(os.environ["MAX_SLEEP_SECONDS"])
qps_floor = int(os.environ["QPS_FLOOR"])
qps_ceil = int(os.environ["QPS_CEIL"])
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
    sleep_s = random.randint(2, max_sleep)

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
