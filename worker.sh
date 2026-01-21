#!/usr/bin/env bash
set -e

MASTER_IP="$1"

if [[ -z "$MASTER_IP" ]]; then
  echo "Usage: ./worker.sh <MASTER_IP>"
  exit 1
fi

echo "[WORKER] Resetting node (safe even if fresh)"
sudo kubeadm reset -f || true
sudo rm -rf /etc/cni/net.d ~/.kube || true
sudo systemctl restart kubelet

echo "[WORKER] Joining cluster"
sudo kubeadm join ${MASTER_IP}:6443 \
  --token $(ssh ${MASTER_IP} "kubeadm token list | tail -n1 | awk '{print \$1}'") \
  --discovery-token-ca-cert-hash \
  sha256:$(ssh ${MASTER_IP} "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
    | openssl rsa -pubin -outform der 2>/dev/null \
    | sha256sum | awk '{print \$1}'")

echo "[WORKER] Join complete"