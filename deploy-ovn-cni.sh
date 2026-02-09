#!/usr/bin/env bash
set -euo pipefail

# This script deploys the OVN-Kubernetes CNI
# Use this AFTER manually distributing the ovn-kube:latest image to all worker nodes

OVN_DIR="${HOME}/ovn-kubernetes"
POD_CIDR="10.128.0.0/14"
SVC_CIDR="172.30.0.0/16"

echo "=========================================="
echo "Deploying OVN-Kubernetes CNI"
echo "=========================================="

# Check if OVN directory exists
if [ ! -d "${OVN_DIR}" ]; then
  echo "ERROR: OVN-Kubernetes directory not found at ${OVN_DIR}"
  echo "Please run ./install-ovn-cni.sh first."
  exit 1
fi

# Verify workers have the image (optional check)
echo "Checking if worker nodes have the ovn-kube:latest image..."
WORKER_NODES=$(kubectl get nodes --no-headers | grep -v "control-plane" | awk '{print $1}' | cut -d'.' -f1)

if [ -n "${WORKER_NODES}" ]; then
  for node in ${WORKER_NODES}; do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${node}" "docker images ovn-kube:latest --format '{{.Repository}}:{{.Tag}}'" 2>/dev/null | grep -q "ovn-kube:latest"; then
      echo "  ✓ ${node} has ovn-kube:latest"
    else
      echo "  ✗ ${node} might not have ovn-kube:latest (or SSH unavailable)"
      echo "    If deployment fails, please load the image on ${node}:"
      echo "    gunzip -c ~/ovn-kube.tar.gz | sudo docker load"
    fi
  done
  echo ""
fi

# Generate OVN-Kubernetes manifest
echo "Generating OVN-Kubernetes manifest..."
cd "${OVN_DIR}"
./dist/images/daemonset.sh \
  --image=ovn-kube:latest \
  --net-cidr="${POD_CIDR}" \
  --svc-cidr="${SVC_CIDR}" \
  > ~/ovn-kubernetes.yaml

echo "Applying CNI manifest..."
kubectl apply -f ~/ovn-kubernetes.yaml

echo ""
echo "=========================================="
echo "CNI Deployment Initiated"
echo "=========================================="
echo ""
echo "Waiting for OVN-Kubernetes pods to start (this may take 2-3 minutes)..."
echo ""

# Wait for namespace to be created
sleep 5

# Wait for pods to be ready
if kubectl wait --for=condition=ready pod -l app=ovnkube-node -n ovn-kubernetes --timeout=300s 2>/dev/null; then
  echo ""
  echo "✓ OVN-Kubernetes pods are ready!"
else
  echo ""
  echo "Warning: Some pods may not be ready yet. Checking status..."
fi

echo ""
echo "Current pod status:"
kubectl get pods -n ovn-kubernetes -o wide

echo ""
echo "Current node status:"
kubectl get nodes -o wide

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "If nodes are still NotReady, wait 1-2 minutes and check again:"
echo "  kubectl get nodes"
echo ""
echo "To troubleshoot:"
echo "  kubectl get pods -n ovn-kubernetes"
echo "  kubectl logs -n ovn-kubernetes -l app=ovnkube-node --tail=50"
echo "=========================================="
