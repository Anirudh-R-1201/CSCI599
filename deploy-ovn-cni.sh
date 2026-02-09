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

# Verify workers have the image in containerd (optional check)
echo "Checking if worker nodes have the ovn-kube:latest image in containerd..."
WORKER_NODES=$(kubectl get nodes --no-headers | grep -v "control-plane" | awk '{print $1}' | cut -d'.' -f1)

if [ -n "${WORKER_NODES}" ]; then
  for node in ${WORKER_NODES}; do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${node}" "sudo ctr -n k8s.io image ls" 2>/dev/null | grep -q "ovn-kube:latest"; then
      echo "  ✓ ${node} has ovn-kube:latest in containerd"
    else
      echo "  ✗ ${node} might not have ovn-kube:latest (or SSH unavailable)"
      echo "    If deployment fails, please load the image on ${node}:"
      echo "    sudo ctr -n k8s.io image import ~/ovn-kube.tar"
    fi
  done
  echo ""
fi

# Generate OVN-Kubernetes manifests
echo "Generating OVN-Kubernetes manifests..."
cd "${OVN_DIR}"

# daemonset.sh generates manifests to dist/yaml/ directory
./dist/images/daemonset.sh \
  --image=ovn-kube:latest \
  --net-cidr="${POD_CIDR}" \
  --svc-cidr="${SVC_CIDR}" \
  --kind=kind

echo "Applying CNI manifests..."
# Apply core OVN manifests (some CRDs may fail due to K8s version compatibility, that's OK)
kubectl apply -f dist/yaml/ovn-setup.yaml 2>&1 | grep -v "unable to recognize" || true
kubectl apply -f dist/yaml/ovnkube-db.yaml
kubectl apply -f dist/yaml/ovnkube-master.yaml
kubectl apply -f dist/yaml/ovnkube-node.yaml

echo "✓ Core OVN manifests applied (some CRD warnings are expected)"

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
