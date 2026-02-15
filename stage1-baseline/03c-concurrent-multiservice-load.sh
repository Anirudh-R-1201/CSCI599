#!/usr/bin/env bash
set -euo pipefail

# Concurrent multi-service load generation
# Runs multiple fortio load generators in parallel hitting different endpoints
# This creates maximum load across all backend services simultaneously

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-cloudlab-cluster}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

DURATION="${DURATION:-300}"  # Total test duration in seconds (5 minutes default)
QPS_HOME="${QPS_HOME:-100}"   # QPS for home endpoint
QPS_PRODUCT="${QPS_PRODUCT:-80}"  # QPS for product endpoint
QPS_CART="${QPS_CART:-60}"    # QPS for cart endpoint
THREADS_PER_ENDPOINT="${THREADS_PER_ENDPOINT:-24}"

RUN_ID="${RUN_ID:-$(date +"%Y%m%d-%H%M%S")}"
DATA_DIR_BASE="${ROOT_DIR}/data/${RUN_ID}"
DATA_DIR="${DATA_DIR_BASE}/loadgen"

mkdir -p "${DATA_DIR}"
export LOADGEN_DIR="${DATA_DIR}"

echo "=========================================="
echo "Concurrent Multi-Service Load Test"
echo "=========================================="
echo "Duration: ${DURATION}s"
echo "Threads per endpoint: ${THREADS_PER_ENDPOINT}"
echo ""

echo "Deploying Fortio load generator pod..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ROOT_DIR}/fortio-loadgen.yaml"
kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready pod/fortio-loadgen --timeout=120s

# Get a product ID from the catalog
echo "Fetching product ID..."
PRODUCT_ID=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  curl -s http://frontend:80/ | grep -oP 'href="/product/\K[^"]+' | head -1 || echo "OLJCESPC7Z")

echo "Using product ID: ${PRODUCT_ID}"
echo ""

# Define concurrent load generators
echo "Starting concurrent load generators..."
echo ""

# Track PIDs for cleanup
PIDS=()

# 1. Home endpoint (exercises: productcatalog, recommendation, ad, cart)
echo "► Starting load on HOME endpoint (qps=${QPS_HOME}, threads=${THREADS_PER_ENDPOINT})"
echo "  Services exercised: productcatalog, recommendation, ad, cart"
kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  fortio load -c "${THREADS_PER_ENDPOINT}" -qps "${QPS_HOME}" -t "${DURATION}s" \
  -p "50,95,99,99.9" -abort-on -1 -allow-initial-errors \
  -json - -labels "concurrent-home-${RUN_ID}" \
  http://frontend:80/ > "${DATA_DIR}/concurrent-home.json" 2> "${DATA_DIR}/concurrent-home.log" &
PIDS+=($!)

sleep 2

# 2. Product endpoint (exercises: productcatalog, recommendation, currency)
echo "► Starting load on PRODUCT endpoint (qps=${QPS_PRODUCT}, threads=${THREADS_PER_ENDPOINT})"
echo "  Services exercised: productcatalog, recommendation, currency"
kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  fortio load -c "${THREADS_PER_ENDPOINT}" -qps "${QPS_PRODUCT}" -t "${DURATION}s" \
  -p "50,95,99,99.9" -abort-on -1 -allow-initial-errors \
  -json - -labels "concurrent-product-${RUN_ID}" \
  "http://frontend:80/product/${PRODUCT_ID}" > "${DATA_DIR}/concurrent-product.json" 2> "${DATA_DIR}/concurrent-product.log" &
PIDS+=($!)

sleep 2

# 3. Cart endpoint (exercises: cart, currency)
echo "► Starting load on CART endpoint (qps=${QPS_CART}, threads=${THREADS_PER_ENDPOINT})"
echo "  Services exercised: cart, currency"
kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  fortio load -c "${THREADS_PER_ENDPOINT}" -qps "${QPS_CART}" -t "${DURATION}s" \
  -p "50,95,99,99.9" -abort-on -1 -allow-initial-errors \
  -json - -labels "concurrent-cart-${RUN_ID}" \
  http://frontend:80/cart > "${DATA_DIR}/concurrent-cart.json" 2> "${DATA_DIR}/concurrent-cart.log" &
PIDS+=($!)

echo ""
echo "=========================================="
echo "All load generators started!"
echo "=========================================="
echo "Total concurrent QPS: $((QPS_HOME + QPS_PRODUCT + QPS_CART))"
echo "Total threads: $((THREADS_PER_ENDPOINT * 3))"
echo "Test duration: ${DURATION}s (~$((DURATION / 60)) minutes)"
echo ""
echo "Monitor with:"
echo "  kubectl get hpa -w"
echo "  kubectl top pods -n default"
echo ""
echo "Waiting for load test to complete..."

# Wait for all background processes
for pid in "${PIDS[@]}"; do
  wait $pid
done

echo ""
echo "=========================================="
echo "Load test complete!"
echo "=========================================="
echo ""
echo "Results stored in: ${DATA_DIR}"
echo ""
echo "Quick summary:"
for endpoint in home product cart; do
  if [ -f "${DATA_DIR}/concurrent-${endpoint}.json" ]; then
    echo ""
    echo "► ${endpoint^^} endpoint:"
    cat "${DATA_DIR}/concurrent-${endpoint}.json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f\"  Requests: {data.get('DurationHistogram', {}).get('Count', 'N/A')}\")
print(f\"  Actual QPS: {data.get('ActualQPS', 'N/A'):.2f}\")
p = {p['Percentile']: p['Value'] for p in data.get('DurationHistogram', {}).get('Percentiles', [])}
print(f\"  p50: {p.get(50, 0)*1000:.2f}ms\")
print(f\"  p95: {p.get(95, 0)*1000:.2f}ms\")
print(f\"  p99: {p.get(99, 0)*1000:.2f}ms\")
" 2>/dev/null || echo "  (parsing failed)"
  fi
done

echo ""
echo "Check HPA status:"
echo "  kubectl get hpa"
echo ""
