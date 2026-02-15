#!/usr/bin/env bash
set -euo pipefail

# Setup HorizontalPodAutoscalers for Online Boutique microservices
# This script configures HPA with customizable CPU thresholds and replica counts

KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
CPU_THRESHOLD="${CPU_THRESHOLD:-25}"  # CPU percentage to trigger scaling
MIN_REPLICAS="${MIN_REPLICAS:-1}"     # Minimum replicas per service
MAX_REPLICAS="${MAX_REPLICAS:-8}"     # Maximum replicas per service

echo "Setting up HorizontalPodAutoscalers..."
echo "  CPU Threshold: ${CPU_THRESHOLD}%"
echo "  Min Replicas: ${MIN_REPLICAS}"
echo "  Max Replicas: ${MAX_REPLICAS}"
echo ""

# Services to autoscale (frontend needs higher max due to higher load)
SERVICES=(
  "frontend"
  "productcatalogservice"
  "recommendationservice"
  "checkoutservice"
  "cartservice"
)

# Delete existing HPAs
echo "Removing existing HPAs..."
for service in "${SERVICES[@]}"; do
  kubectl --kubeconfig "${KUBECONFIG_PATH}" delete hpa "${service}" 2>/dev/null || true
done

echo ""
echo "Creating new HPAs..."

# Frontend handles most load, so give it more replicas
echo "  frontend: min=${MIN_REPLICAS}, max=$((MAX_REPLICAS + 2)), cpu=${75}%"
kubectl --kubeconfig "${KUBECONFIG_PATH}" autoscale deployment frontend \
  --cpu-percent="${75}" \
  --min="${MIN_REPLICAS}" \
  --max="$((MAX_REPLICAS + 2))"

# Backend services with standard limits
for service in "${SERVICES[@]:1}"; do
  echo "  ${service}: min=${MIN_REPLICAS}, max=${MAX_REPLICAS}, cpu=${CPU_THRESHOLD}%"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" autoscale deployment "${service}" \
    --cpu-percent="${CPU_THRESHOLD}" \
    --min="${MIN_REPLICAS}" \
    --max="${MAX_REPLICAS}"
done

echo ""
echo "✓ HPAs configured successfully"
echo ""
echo "Monitor autoscaling with:"
echo "  kubectl get hpa"
echo "  kubectl get hpa -w"
echo ""
