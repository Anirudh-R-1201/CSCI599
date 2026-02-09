#!/usr/bin/env bash
set -euo pipefail

# OVN-Kubernetes CNI Installation Script for CloudLab
# This script automates the build and deployment of OVN-Kubernetes CNI

OVN_REPO="git@github.com:Anirudh-R-1201/ovn-kubernetes.git"
OVN_BRANCH="${OVN_BRANCH:-nw-affinity}"
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

# Check Docker permissions
echo "[0/6] Checking Docker permissions..."
if ! docker ps >/dev/null 2>&1; then
  echo "Warning: Cannot access Docker daemon without sudo."
  echo "Attempting to fix by activating docker group membership..."
  
  if groups | grep -q docker; then
    echo "You are in the docker group but need to activate it."
    echo "Executing the rest of this script with correct permissions..."
    # Re-execute this script with newgrp to activate docker group
    exec sg docker "$0 $@"
  else
    echo "ERROR: You are not in the docker group."
    echo "Please run: sudo usermod -aG docker \$USER"
    echo "Then log out and log back in, or run: newgrp docker"
    exit 1
  fi
fi
echo "Docker permissions OK"

# Step 1: Clone OVN-Kubernetes repository
if [ ! -d "${OVN_DIR}" ]; then
  echo "[1/6] Cloning OVN-Kubernetes repository..."
  git clone "${OVN_REPO}" "${OVN_DIR}"
  cd "${OVN_DIR}"
  git checkout "${OVN_BRANCH}"
else
  echo "[1/6] OVN-Kubernetes repository already exists, pulling latest..."
  cd "${OVN_DIR}"
  git fetch origin
  git checkout "${OVN_BRANCH}"
  git pull origin "${OVN_BRANCH}"
fi

# Step 2: Install Go if not present
if ! command -v go >/dev/null 2>&1; then
  echo "[2/6] Installing Go ${GO_VERSION}..."
  cd ~
  curl -LO "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
  echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
  export PATH=$PATH:/usr/local/go/bin
  rm "go${GO_VERSION}.linux-amd64.tar.gz"
  go version
else
  echo "[2/6] Go already installed: $(go version)"
fi

# Step 3: Build OVN-Kubernetes image
echo "[3/6] Building OVN-Kubernetes Ubuntu image (this may take 10-15 minutes)..."
cd "${OVN_DIR}/dist/images"
make ubuntu-image

# Step 4: Tag the image
echo "[4/6] Tagging image as ovn-kube:latest..."
docker tag ovn-kube-ubuntu:latest ovn-kube:latest

# Step 5: Save image for distribution
echo "[5/6] Saving image for distribution to worker nodes..."
cd ~
docker save ovn-kube:latest | gzip > ovn-kube.tar.gz

echo ""
echo "=========================================="
echo "Image built and saved successfully!"
echo "=========================================="
echo ""
echo "Next steps for CloudLab clusters:"
echo ""
echo "Option A - Distribute via your local machine (RECOMMENDED for CloudLab):"
echo "  1. From your laptop: scp node0:~/ovn-kube.tar.gz ."
echo "  2. From your laptop: scp ovn-kube.tar.gz node1:~/"
echo "  3. On node1: gunzip -c ~/ovn-kube.tar.gz | sudo docker load"
echo "  4. Repeat for any additional worker nodes"
echo "  5. Come back to node0 and run: ./deploy-ovn-cni.sh"
echo ""
echo "Option B - Set up SSH keys between nodes:"
echo "  1. On each worker from your laptop:"
echo "     ssh worker 'echo \"$(cat ~/.ssh/id_ed25519.pub)\" >> ~/.ssh/authorized_keys'"
echo "  2. Test with: ssh node1 hostname"
echo "  3. Then run: ./distribute-and-deploy-cni.sh"
echo ""
echo "Image file location: ~/ovn-kube.tar.gz"
echo "=========================================="
