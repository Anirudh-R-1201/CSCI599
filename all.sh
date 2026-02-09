#!/usr/bin/env bash
set -e

echo "[COMMON] Updating system and installing base packages"

sudo apt update
sudo apt install -y \
  containerd \
  docker.io \
  git \
  make \
  gcc \
  conntrack \
  jq \
  curl \
  ca-certificates

echo "[COMMON] Adding user to docker group"
sudo usermod -aG docker $USER

echo "[COMMON] Configuring containerd"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl restart docker
sudo systemctl enable docker

echo "[COMMON] Preparing kubelet configuration for containerd"
sudo mkdir -p /etc/systemd/system/kubelet.service.d
sudo tee /etc/systemd/system/kubelet.service.d/10-containerd.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

echo "[COMMON] Kernel and sysctl settings"
sudo modprobe br_netfilter || true
echo 'br_netfilter' | sudo tee /etc/modules-load.d/k8s.conf

# Make sysctl settings persistent
sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system

echo "[COMMON] Disabling swap"
sudo swapoff -a || true
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "[COMMON] Installing Kubernetes (v1.29)"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
| sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "[COMMON] Starting and enabling kubelet"
sudo systemctl daemon-reload
sudo systemctl enable kubelet
sudo systemctl start kubelet

echo "[COMMON] Done"
echo ""
echo "IMPORTANT: Docker group membership has been added."
echo "To use Docker without sudo, you need to either:"
echo "  1. Log out and log back in, OR"
echo "  2. Run: newgrp docker"
echo ""