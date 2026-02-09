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
if [ ! -f ~/ovn-kube.tar ]; then
  echo "ERROR: ~/ovn-kube.tar not found!"
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
    if scp -o StrictHostKeyChecking=no ~/ovn-kube.tar "${node}:~/" ; then
      echo "  ✓ Image copied successfully"
      
      echo "  -> Loading image into containerd on ${node}..."
      if ssh -o StrictHostKeyChecking=no "${node}" "sudo ctr -n k8s.io image import ~/ovn-kube.tar"; then
        echo "  ✓ Image loaded successfully into containerd"
      else
        echo "  ✗ Failed to load image on ${node}"
        echo "    Please manually run on ${node}:"
        echo "    sudo ctr -n k8s.io image import ~/ovn-kube.tar"
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

# Ensure jinjanator is installed
if ! command -v jinjanate &> /dev/null; then
  echo "Installing jinjanator..."
  pip3 install --user jinjanator
  export PATH="${HOME}/.local/bin:${PATH}"
fi

echo "Generating OVN-Kubernetes manifests..."
cd "${OVN_DIR}"

# Check if daemonset.sh exists
if [ ! -f "./dist/images/daemonset.sh" ]; then
  echo "ERROR: daemonset.sh not found at ${OVN_DIR}/dist/images/daemonset.sh"
  exit 1
fi

# Make sure we're using the correct PATH for jinjanate
export PATH="${HOME}/.local/bin:${PATH}"

# Get the Kubernetes API server address
K8S_APISERVER="https://$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | cut -d: -f1):6443"

# daemonset.sh generates manifests to dist/yaml/ directory
echo "Running daemonset.sh to generate manifests..."
./dist/images/daemonset.sh \
  --image=ovn-kube:latest \
  --net-cidr="${POD_CIDR}" \
  --svc-cidr="${SVC_CIDR}" \
  --gateway-mode="local" \
  --k8s-apiserver="${K8S_APISERVER}" \
  --kind=kind || {
    echo "ERROR: Manifest generation failed"
    echo "Trying alternative approach..."
    
    # Alternative: use pushd/popd to ensure correct directory context
    pushd "${OVN_DIR}/dist/images" > /dev/null
    ./daemonset.sh \
      --image=ovn-kube:latest \
      --net-cidr="${POD_CIDR}" \
      --svc-cidr="${SVC_CIDR}" \
      --gateway-mode="local" \
      --k8s-apiserver="${K8S_APISERVER}" \
      --kind=kind
    popd > /dev/null
  }

# Verify manifests were generated
if [ ! -f "${OVN_DIR}/dist/yaml/ovnkube-node.yaml" ]; then
  echo "ERROR: Manifests were not generated in ${OVN_DIR}/dist/yaml/"
  echo "Checking what files exist:"
  ls -la "${OVN_DIR}/dist/yaml/" || echo "Directory does not exist"
  exit 1
fi

echo "✓ Manifests generated successfully"
echo ""

echo "Applying CNI manifests..."
cd "${OVN_DIR}"

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
