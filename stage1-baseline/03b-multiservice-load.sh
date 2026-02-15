#!/usr/bin/env bash
set -euo pipefail

# Multi-service load generation - hits different endpoints to exercise different backends
# This creates concurrent load on frontend endpoints that heavily use specific backend services

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-cloudlab-cluster}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

BURSTS="${BURSTS:-30}"
BASE_QPS="${BASE_QPS:-10}"
MAX_QPS="${MAX_QPS:-150}"
BASE_DURATION="${BASE_DURATION:-30}"
MAX_DURATION="${MAX_DURATION:-90}"
ALPHA_QPS="${ALPHA_QPS:-1.5}"
ALPHA_DURATION="${ALPHA_DURATION:-1.4}"
MAX_SLEEP="${MAX_SLEEP:-10}"
THREADS="${THREADS:-16}"  # Per endpoint

RUN_ID="${RUN_ID:-$(date +"%Y%m%d-%H%M%S")}"
DATA_DIR_BASE="${ROOT_DIR}/data/${RUN_ID}"
DATA_DIR="${DATA_DIR_BASE}/loadgen"
META_FILE="${DATA_DIR}/bursts.jsonl"

mkdir -p "${DATA_DIR}"
export LOADGEN_DIR="${DATA_DIR}"

echo "Deploying Fortio load generator pod..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ROOT_DIR}/fortio-loadgen.yaml"
kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready pod/fortio-loadgen --timeout=120s

# Get a product ID from the catalog
echo "Fetching product list..."
PRODUCT_ID=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  curl -s http://frontend:80/ | grep -oP 'href="/product/\K[^"]+' | head -1 || echo "OLJCESPC7Z")

echo "Using product ID: ${PRODUCT_ID}"

# Define endpoints that exercise different backend services
declare -A ENDPOINTS=(
  ["home"]="http://frontend:80/"
  ["product"]="http://frontend:80/product/${PRODUCT_ID}"
  ["cart"]="http://frontend:80/cart"
)

declare -A ENDPOINT_SERVICES=(
  ["home"]="productcatalog,recommendation,ad,cart"
  ["product"]="productcatalog,recommendation,currency"
  ["cart"]="cart,currency"
)

echo "Generating burst schedule..."
python3 - <<'PY' > "${META_FILE}"
import json
import os
import random
import time

bursts = int(os.environ.get("BURSTS", "30"))
base_qps = int(os.environ.get("BASE_QPS", "10"))
max_qps = int(os.environ.get("MAX_QPS", "150"))
base_dur = int(os.environ.get("BASE_DURATION", "30"))
max_dur = int(os.environ.get("MAX_DURATION", "90"))
alpha_qps = float(os.environ.get("ALPHA_QPS", "1.5"))
alpha_dur = float(os.environ.get("ALPHA_DURATION", "1.4"))
max_sleep = int(os.environ.get("MAX_SLEEP", "10"))

random.seed(int(time.time()))

endpoints = ["home", "product", "cart"]

for i in range(bursts):
    # Rotate through endpoints to exercise different backends
    endpoint = endpoints[i % len(endpoints)]
    qps = min(max_qps, max(1, int(base_qps * random.paretovariate(alpha_qps))))
    dur = min(max_dur, max(10, int(base_dur * random.paretovariate(alpha_dur))))
    sleep_s = random.randint(1, max_sleep)
    print(json.dumps({
        "burst_index": i,
        "endpoint": endpoint,
        "qps": qps,
        "duration_s": dur,
        "sleep_s": sleep_s
    }))
PY

echo ""
echo "Running multi-service bursts (exercising different backends)..."
echo "Endpoints:"
for endpoint in "${!ENDPOINTS[@]}"; do
  echo "  ${endpoint}: ${ENDPOINTS[$endpoint]} -> exercises: ${ENDPOINT_SERVICES[$endpoint]}"
done
echo ""

burst_count=0
while read -r line; do
  idx=$(echo "${line}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["burst_index"])')
  endpoint=$(echo "${line}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["endpoint"])')
  qps=$(echo "${line}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["qps"])')
  dur=$(echo "${line}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["duration_s"])')
  sleep_s=$(echo "${line}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sleep_s"])')
  
  target_url="${ENDPOINTS[$endpoint]}"
  target_services="${ENDPOINT_SERVICES[$endpoint]}"
  
  echo "Burst ${idx} [${endpoint}]: qps=${qps} duration=${dur}s threads=${THREADS} (services: ${target_services}) sleep=${sleep_s}s"
  LOG_FILE="${DATA_DIR}/fortio-burst-${idx}.log"
  JSON_FILE="${DATA_DIR}/fortio-burst-${idx}.json"
  
  # Run fortio load with specified endpoint
  kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
    fortio load -c "${THREADS}" -qps "${qps}" -t "${dur}s" -p "50,95,99,99.9" \
    -abort-on -1 -allow-initial-errors -json - -labels "stage1-burst-${idx}-${endpoint}" \
    "${target_url}" > "${JSON_FILE}" 2> "${LOG_FILE}" &
  
  LOAD_PID=$!
  burst_count=$((burst_count + 1))
  
  # Wait for load to complete
  wait $LOAD_PID
  
  sleep "${sleep_s}"
done < "${META_FILE}"

echo ""
echo "Load generation complete. ${burst_count} bursts executed."
echo "Logs and metadata stored in ${DATA_DIR}"
echo ""
echo "Endpoints exercised:"
for endpoint in "${!ENDPOINT_SERVICES[@]}"; do
  count=$(grep "\"endpoint\":\"${endpoint}\"" "${META_FILE}" | wc -l | tr -d ' ')
  echo "  ${endpoint}: ${count} bursts (services: ${ENDPOINT_SERVICES[$endpoint]})"
done
