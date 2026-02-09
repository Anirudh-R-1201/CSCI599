#!/usr/bin/env bash
set -e

POD_CIDR="10.128.0.0/14"
SVC_CIDR="172.30.0.0/16"

echo "[MASTER] Initializing Kubernetes control plane"

sudo kubeadm init \
  --pod-network-cidr=${POD_CIDR} \
  --service-cidr=${SVC_CIDR}

echo "[MASTER] Setting up kubeconfig"
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "[MASTER] Generating join command"
kubeadm token create --print-join-command > join.sh
chmod +x join.sh

echo "[MASTER] Control plane initialized"
echo "[MASTER] Run the join command in join.sh on worker nodes"