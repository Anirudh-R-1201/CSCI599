#!/usr/bin/env bash
set -euo pipefail

# This script distributes the OVN image to worker nodes and deploys the CNI
# Prerequisites: SSH access to worker nodes must be configured

OVN_DIR="${HOME}/ovn-kubernetes"
POD_CIDR="10.128.0.0/14"
SVC_CIDR="172.30.0.0/16"

echo "=========================================="
echo "Distributing OVN Image & Deploying CNI"
echo "=========================================="

# Check if image exists
if [ ! -f ~/ovn-kube.tar.gz ]; then
  echo "ERROR: ~/ovn-kube.tar.gz not found!"
  echo "Please run ./install-ovn-cni.sh first to build the image."
  exit 1
fi

# Get list of worker nodes (excluding control plane)
WORKER_NODES=$(kubectl get nodes --no-headers | grep -v "control-plane" | awk '{print $1}' | cut -d'.' -f1)

if [ -z "${WORKER_NODES}" ]; then
  echo "Warning: No worker nodes found in cluster."
  echo "Skipping image distribution."
else
  echo "Found worker nodes: ${WORKER_NODES}"
  echo ""
  
  for node in ${WORKER_NODES}; do
    echo "Processing ${node}..."
    
    # Test SSH connectivity first
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${node}" "echo 'SSH OK'" >/dev/null 2>&1; then
      echo "  ✗ SSH to ${node} failed. Skipping."
      echo "    Please set up SSH keys or distribute image manually."
      continue
    fi
    
    echo "  -> Copying image to ${node}..."
    if scp -o StrictHostKeyChecking=no ~/ovn-kube.tar.gz "${node}:~/" ; then
      echo "  ✓ Image copied successfully"
      
      echo "  -> Loading image on ${node}..."
      # Try with docker group first, fallback to sudo
      if ssh -o StrictHostKeyChecking=no "${node}" "docker load < <(gunzip -c ~/ovn-kube.tar.gz)" 2>/dev/null; then
        echo "  ✓ Image loaded successfully"
      elif ssh -o StrictHostKeyChecking=no "${node}" "sudo docker load < <(gunzip -c ~/ovn-kube.tar.gz)"; then
        echo "  ✓ Image loaded successfully (with sudo)"
      else
        echo "  ✗ Failed to load image on ${node}"
        echo "    Please manually run on ${node}:"
        echo "    gunzip -c ~/ovn-kube.tar.gz | sudo docker load"
      fi
    else
      echo "  ✗ Failed to copy image to ${node}"
      echo "    Please distribute manually using your local machine."
    fi
    echo ""
  done
fi

# Generate and deploy OVN-Kubernetes manifest
echo "=========================================="
echo "Deploying OVN-Kubernetes CNI"
echo "=========================================="

if [ ! -d "${OVN_DIR}" ]; then
  echo "ERROR: OVN-Kubernetes directory not found at ${OVN_DIR}"
  echo "Please run ./install-ovn-cni.sh first."
  exit 1
fi

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
