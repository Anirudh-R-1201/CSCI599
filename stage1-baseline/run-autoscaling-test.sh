#!/usr/bin/env bash
set -euo pipefail

# Complete workflow for running an autoscaling baseline test
# This script sets up HPA, runs load tests, and collects all metrics

KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "Autoscaling Baseline Test Workflow"
echo "========================================"
echo ""

# Step 1: Verify prerequisites
echo "Step 1: Checking prerequisites..."
if ! kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes &>/dev/null; then
  echo "Error: Cannot connect to Kubernetes cluster"
  exit 1
fi

if ! kubectl --kubeconfig "${KUBECONFIG_PATH}" get deployment metrics-server -n kube-system &>/dev/null; then
  echo "Warning: metrics-server not found. Installing..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
  
  echo "Waiting for metrics-server to be ready..."
  kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=180s
fi

echo "✓ Prerequisites verified"
echo ""

# Step 2: Deploy workload
echo "Step 2: Deploying Online Boutique workload..."
if ! kubectl --kubeconfig "${KUBECONFIG_PATH}" get deployment frontend &>/dev/null; then
  kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ROOT_DIR}/online-boutique.yaml"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Available deployment --all -n default --timeout=600s
else
  echo "✓ Workload already deployed"
fi
echo ""

# Step 3: Setup HPA
echo "Step 3: Configuring HorizontalPodAutoscalers (15% CPU threshold for better backend scaling)..."
CPU_THRESHOLD=25 "${ROOT_DIR}/07-setup-hpa.sh"
echo ""

# Step 4: Wait for metrics to stabilize
echo "Step 4: Waiting for metrics to stabilize (30 seconds)..."
sleep 30
echo "✓ Metrics ready"
echo ""

# Step 5: Run load test
echo "Step 5: Running high-intensity load test..."
export RUN_ID=$(date +"%Y%m%d-%H%M%S")
echo "  Run ID: ${RUN_ID}"
echo ""

echo "Starting pod placement monitoring in background..."
INTERVAL_SEC=5 COUNT=1000 "${ROOT_DIR}/05-snapshot-pod-placement.sh" > /tmp/placement-${RUN_ID}.log 2>&1 &
PLACEMENT_PID=$!
echo "  Pod placement monitor PID: ${PLACEMENT_PID}"

sleep 2

echo ""
echo "Starting concurrent multi-service load generation..."
echo "  Pattern: Concurrent load on 3 endpoints (home, product, cart)"
echo "  Total QPS: 240 (100 + 80 + 60)"
echo "  Total threads: 72 (24 per endpoint)"
echo "  Duration: 10 minutes"
echo ""
echo "This pattern exercises all backend services simultaneously:"
echo "  - Home endpoint → productcatalog, recommendation, ad, cart"
echo "  - Product endpoint → productcatalog, recommendation, currency"
echo "  - Cart endpoint → cart, currency"
echo ""
echo "Monitor autoscaling in another terminal with:"
echo "  kubectl get hpa -w"
echo ""

DURATION=600 QPS_HOME=100 QPS_PRODUCT=80 QPS_CART=60 THREADS_PER_ENDPOINT=24 \
  "${ROOT_DIR}/03c-concurrent-multiservice-load.sh"

echo ""
echo "Stopping pod placement monitoring..."
kill $PLACEMENT_PID 2>/dev/null || true
echo "✓ Load test complete"
echo ""

# Step 6: Collect baseline metrics
echo "Step 6: Collecting baseline metrics..."
"${ROOT_DIR}/04-collect-baseline.sh"
echo ""

# Step 7: Generate graphs
echo "Step 7: Generating visualization graphs..."
if command -v python3 &>/dev/null && python3 -c "import matplotlib" 2>/dev/null; then
  "${ROOT_DIR}/06-generate-graphs.sh"
  echo ""
else
  echo "Warning: matplotlib not installed. Skipping graph generation."
  echo "Install with: pip3 install matplotlib"
  echo ""
fi

# Step 8: Display summary
echo "========================================"
echo "Test Complete!"
echo "========================================"
echo ""
echo "Results directory: ${ROOT_DIR}/data/${RUN_ID}"
echo ""
echo "Quick analysis:"
echo "  kubectl get hpa"
echo "  kubectl get deployments -o wide"
echo "  cat ${ROOT_DIR}/data/${RUN_ID}/graphs/summary_stats.txt"
echo ""
echo "View graphs:"
echo "  open ${ROOT_DIR}/data/${RUN_ID}/graphs/"
echo ""
