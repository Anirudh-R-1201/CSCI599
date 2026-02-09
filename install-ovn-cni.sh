#!/usr/bin/env bash
set -euo pipefail

# OVN-Kubernetes CNI Installation Script for CloudLab
# This script automates the build and deployment of OVN-Kubernetes CNI

OVN_REPO="git@github.com:Anirudh-R-1201/ovn-kubernetes.git"
OVN_BRANCH="${OVN_BRANCH:-master}"
OVN_DIR="${HOME}/ovn-kubernetes"
GO_VERSION="1.21.7"
POD_CIDR="10.128.0.0/14"
SVC_CIDR="172.30.0.0/16"

echo "=========================================="
echo "OVN-Kubernetes CNI Installation"
echo "=========================================="
echo "Repository: ${OVN_REPO}"
echo "Branch: ${OVN_BRANCH}"
echo "Pod CIDR: ${POD_CIDR}"
echo "Service CIDR: ${SVC_CIDR}"
echo "=========================================="

# Step 1: Clone OVN-Kubernetes repository
if [ ! -d "${OVN_DIR}" ]; then
  echo "[1/7] Cloning OVN-Kubernetes repository..."
  git clone "${OVN_REPO}" "${OVN_DIR}"
  cd "${OVN_DIR}"
  git checkout "${OVN_BRANCH}"
else
  echo "[1/7] OVN-Kubernetes repository already exists, pulling latest..."
  cd "${OVN_DIR}"
  git fetch origin
  git checkout "${OVN_BRANCH}"
  git pull origin "${OVN_BRANCH}"
fi

# Step 2: Install Go if not present
if ! command -v go >/dev/null 2>&1; then
  echo "[2/7] Installing Go ${GO_VERSION}..."
  cd ~
  curl -LO "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
  echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
  export PATH=$PATH:/usr/local/go/bin
  rm "go${GO_VERSION}.linux-amd64.tar.gz"
  go version
else
  echo "[2/7] Go already installed: $(go version)"
fi

# Step 3: Build OVN-Kubernetes image
echo "[3/7] Building OVN-Kubernetes Ubuntu image (this may take 10-15 minutes)..."
cd "${OVN_DIR}/dist/images"
make ubuntu-image

# Step 4: Tag the image
echo "[4/7] Tagging image as ovn-kube:latest..."
docker tag ovn-kube-ubuntu:latest ovn-kube:latest

# Step 5: Distribute image to worker nodes
echo "[5/7] Distributing image to worker nodes..."
cd ~
docker save ovn-kube:latest | gzip > ovn-kube.tar.gz

# Get list of worker nodes (excluding control plane)
WORKER_NODES=$(kubectl get nodes --no-headers | grep -v "control-plane" | awk '{print $1}')

if [ -z "${WORKER_NODES}" ]; then
  echo "Warning: No worker nodes found. Skipping image distribution."
else
  for node in ${WORKER_NODES}; do
    echo "  -> Copying image to ${node}..."
    scp -o StrictHostKeyChecking=no ovn-kube.tar.gz "${node}:~/" || {
      echo "    Warning: Failed to copy to ${node}. You may need to do this manually."
    }
    echo "  -> Loading image on ${node}..."
    ssh -o StrictHostKeyChecking=no "${node}" "gunzip -c ~/ovn-kube.tar.gz | docker load" || {
      echo "    Warning: Failed to load image on ${node}. You may need to do this manually."
    }
  done
fi

rm ovn-kube.tar.gz

# Step 6: Generate OVN-Kubernetes manifest
echo "[6/7] Generating OVN-Kubernetes manifest..."
cd "${OVN_DIR}"
./dist/images/daemonset.sh \
  --image=ovn-kube:latest \
  --net-cidr="${POD_CIDR}" \
  --svc-cidr="${SVC_CIDR}" \
  > ovn-kubernetes.yaml

# Step 7: Deploy OVN-Kubernetes CNI
echo "[7/7] Deploying OVN-Kubernetes CNI..."
kubectl apply -f ovn-kubernetes.yaml

echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo ""
echo "Waiting for OVN-Kubernetes pods to be ready..."
echo "(This may take 2-3 minutes)"
echo ""

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app=ovnkube-node -n ovn-kubernetes --timeout=300s || {
  echo "Warning: Some pods are not ready yet. Check status with:"
  echo "  kubectl get pods -n ovn-kubernetes"
}

echo ""
echo "Checking node status..."
kubectl get nodes -o wide

echo ""
echo "Checking OVN-Kubernetes pods..."
kubectl get pods -n ovn-kubernetes -o wide

echo ""
echo "=========================================="
echo "Next steps:"
echo "1. Verify all nodes are 'Ready'"
echo "2. Deploy your workload"
echo "=========================================="
