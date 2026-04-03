#!/usr/bin/env bash
set -euo pipefail

# Setup HorizontalPodAutoscalers for Online Boutique microservices
# This script configures HPA with customizable CPU thresholds and replica counts

KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
CPU_THRESHOLD="${CPU_THRESHOLD:-75}"  # Use 50 for more aggressive scaling (more replicas at same load)
FRONTEND_EXTRA_CPU="${FRONTEND_EXTRA_CPU:-0}" # Frontend target = CPU_THRESHOLD + this (0 = same as others)

# REPLICA_MODE controls scaling behaviour:
#   fixed  → min=max=MIN_REPLICAS (default 4) — no autoscaling; best for apples-to-apples comparison
#   scale  → min=1, max=MAX_REPLICAS (default 4) — normal HPA autoscaling
REPLICA_MODE="${REPLICA_MODE:-fixed}"

# MIN_REPLICAS: set the fixed replica count (fixed mode) or floor (scale mode).
# Typical values: 2 (lighter baseline, less resource pressure) or 4 (stronger baseline).
# Frontend always gets +2 on top of this value.
MIN_REPLICAS="${MIN_REPLICAS:-4}"
MAX_REPLICAS="${MAX_REPLICAS:-4}"

case "${REPLICA_MODE}" in
  fixed)
    # Pin min=max=MIN_REPLICAS so HPA never scales up or down.
    MAX_REPLICAS="${MIN_REPLICAS}"
    ;;
  scale)
    # Floor is MIN_REPLICAS, ceiling is MAX_REPLICAS.
    # Default min=1 (cold-start from scratch) unless caller overrides.
    MIN_REPLICAS="${MIN_REPLICAS:-1}"
    ;;
  *)
    echo "Error: REPLICA_MODE must be 'fixed' or 'scale' (got '${REPLICA_MODE}')"
    exit 1
    ;;
esac

echo "Setting up HorizontalPodAutoscalers..."
echo "  REPLICA_MODE:  ${REPLICA_MODE}"
echo "  MIN_REPLICAS:  ${MIN_REPLICAS} (backend)  $((MIN_REPLICAS + 2)) (frontend)"
echo "  MAX_REPLICAS:  ${MAX_REPLICAS} (backend)  $((MAX_REPLICAS + 2)) (frontend)"
echo "  CPU Threshold: ${CPU_THRESHOLD}%"
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
FRONTEND_CPU_TARGET=$((CPU_THRESHOLD + FRONTEND_EXTRA_CPU))
echo "  frontend: min=$((MIN_REPLICAS + 2)), max=$((MAX_REPLICAS + 2)), cpu=${FRONTEND_CPU_TARGET}%"
kubectl --kubeconfig "${KUBECONFIG_PATH}" autoscale deployment frontend \
  --cpu-percent="${FRONTEND_CPU_TARGET}" \
  --min="$((MIN_REPLICAS + 2))" \
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
