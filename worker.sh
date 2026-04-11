#!/usr/bin/env bash
set -e

if [ "$#" -lt 1 ]; then
  echo "Usage: ./worker.sh \"<kubeadm join command>\""
  exit 1
fi

JOIN_CMD="$@"

echo "[WORKER] Resetting node"
sudo kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock || true
sudo rm -rf /etc/cni/net.d ~/.kube || true

echo "[WORKER] Restarting containerd (reset may have stopped it)"
sudo systemctl start containerd
sleep 2
sudo systemctl restart kubelet

echo "[WORKER] Joining cluster"
sudo ${JOIN_CMD}

echo "[WORKER] Join complete"
