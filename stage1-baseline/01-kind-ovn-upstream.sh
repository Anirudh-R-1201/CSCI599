#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVN_KUBERNETES_DIR="${OVN_KUBERNETES_DIR:-${ROOT_DIR}/../ovn-kubernetes-upstream}"
OVN_REPO="${OVN_REPO:-https://github.com/ovn-org/ovn-kubernetes.git}"
OVN_GITREF="${OVN_GITREF:-}"
CLUSTER_NAME="${CLUSTER_NAME:-ovn-baseline}"
KIND_WORKERS="${KIND_WORKERS:-3}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${ROOT_DIR}/kubeconfig-${CLUSTER_NAME}}"

echo "Stage 1: Baseline - Upstream OVN-Kubernetes on kind"
echo "OVN_KUBERNETES_DIR=${OVN_KUBERNETES_DIR}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "KIND_WORKERS=${KIND_WORKERS}"
echo "KUBECONFIG_PATH=${KUBECONFIG_PATH}"
echo "OVN_REPO=${OVN_REPO}"
echo "OVN_GITREF=${OVN_GITREF}"

if ! command -v kind >/dev/null 2>&1; then
  echo "ERROR: kind is required but not found in PATH."
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is required but not found in PATH."
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is required but not found in PATH."
  exit 1
fi

if [ ! -d "${OVN_KUBERNETES_DIR}" ]; then
  echo "Cloning upstream ovn-kubernetes..."
  git clone "${OVN_REPO}" "${OVN_KUBERNETES_DIR}"
else
  echo "Using existing ovn-kubernetes directory."
fi

pushd "${OVN_KUBERNETES_DIR}" >/dev/null

if [ -n "${OVN_GITREF}" ]; then
  git fetch --all --tags
  git checkout "${OVN_GITREF}"
fi

echo "Building OVN-Kubernetes image (Fedora)..."
pushd dist/images >/dev/null
make fedora-image
popd >/dev/null

echo "Creating kind cluster and installing OVN-Kubernetes..."
pushd contrib >/dev/null
export KUBECONFIG="${KUBECONFIG_PATH}"
./kind.sh -wk "${KIND_WORKERS}" -cn "${CLUSTER_NAME}" -kc "${KUBECONFIG_PATH}"
popd >/dev/null

echo "Verifying cluster readiness..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o wide
kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -n ovn-kubernetes -o wide

popd >/dev/null

echo "Done. KUBECONFIG=${KUBECONFIG_PATH}"
