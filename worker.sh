#!/usr/bin/env bash
set -e

if [ "$#" -lt 1 ]; then
  echo "Usage: ./worker.sh \"<kubeadm join command>\""
  exit 1
fi

JOIN_CMD="$@"

echo "[WORKER] Resetting node"
sudo kubeadm reset -f || true
sudo rm -rf /etc/cni/net.d ~/.kube || true
sudo systemctl restart kubelet

echo "[WORKER] Joining cluster"
sudo ${JOIN_CMD}

echo "[WORKER] Join complete"