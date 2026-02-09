#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-ovn-baseline}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${ROOT_DIR}/kubeconfig-${CLUSTER_NAME}}"
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml}"

echo "Deploying Online Boutique workload..."
echo "KUBECONFIG_PATH=${KUBECONFIG_PATH}"
echo "MANIFEST_URL=${MANIFEST_URL}"

kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${MANIFEST_URL}"

echo "Waiting for workload deployments to be Available..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Available deploy --all --timeout=600s

kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -o wide
echo "Workload deployed."
