#!/usr/bin/env bash
set -e

echo "[COMMON] Updating system and installing base packages"

sudo apt update
sudo apt install -y \
  docker.io \
  git \
  make \
  gcc \
  conntrack \
  jq \
  curl \
  ca-certificates

echo "[COMMON] Enabling Docker"
sudo systemctl enable docker
sudo systemctl start docker

echo "[COMMON] Kernel and sysctl settings"
sudo modprobe br_netfilter || true
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1

echo "[COMMON] Disabling swap"
sudo swapoff -a || true

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

echo "[COMMON] Done"