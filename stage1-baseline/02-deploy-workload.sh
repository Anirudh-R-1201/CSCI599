#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-cloudlab-cluster}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
LOCAL_MANIFEST="${ROOT_DIR}/online-boutique.yaml"

echo "Deploying Online Boutique workload..."
echo "KUBECONFIG_PATH=${KUBECONFIG_PATH}"

# Use local manifest if it exists (for CloudLab/environments without DNS)
# Otherwise fall back to fetching from URL
if [ -f "${LOCAL_MANIFEST}" ]; then
  echo "Using local manifest: ${LOCAL_MANIFEST}"
  MANIFEST="${LOCAL_MANIFEST}"
else
  echo "Local manifest not found, will fetch from URL"
  MANIFEST="https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml"
fi

kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${MANIFEST}"

echo "Waiting for workload deployments to be Available..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Available deploy --all -n default --timeout=600s

kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -o wide
echo "Workload deployed."
