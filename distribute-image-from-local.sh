#!/usr/bin/env bash
set -euo pipefail

# Run this script FROM YOUR LOCAL MACHINE (laptop/desktop)
# It distributes the OVN image from node0 to all worker nodes via your laptop

# Configuration - UPDATE THESE
NODE0_HOST="${NODE0_HOST:-anirudh1@ms0835.utah.cloudlab.us}"
NODE1_HOST="${NODE1_HOST:-anirudh1@ms0844.utah.cloudlab.us}"
# Add more workers as needed:
# NODE2_HOST="${NODE2_HOST:-anirudh1@msXXXX.utah.cloudlab.us}"

IMAGE_FILE="ovn-kube.tar"

echo "=========================================="
echo "OVN Image Distribution Helper"
echo "=========================================="
echo "This script runs on YOUR LOCAL MACHINE"
echo ""
echo "Control plane: ${NODE0_HOST}"
echo "Worker 1:      ${NODE1_HOST}"
# echo "Worker 2:      ${NODE2_HOST}"  # Uncomment if you have more workers
echo "=========================================="
echo ""

# Step 1: Download image from node0
echo "[1/3] Downloading image from node0..."
if scp "${NODE0_HOST}:~/${IMAGE_FILE}" . ; then
  echo "✓ Image downloaded successfully"
  IMAGE_SIZE=$(du -h "${IMAGE_FILE}" | cut -f1)
  echo "  Size: ${IMAGE_SIZE}"
else
  echo "✗ Failed to download image from node0"
  echo "  Make sure the image exists on node0 at ~/${IMAGE_FILE}"
  echo "  Run ./install-ovn-cni.sh on node0 if you haven't already"
  exit 1
fi

echo ""

# Step 2: Upload to worker nodes
echo "[2/3] Uploading image to worker nodes..."

# Worker 1
echo "  -> Uploading to node1..."
if scp "${IMAGE_FILE}" "${NODE1_HOST}:~/" ; then
  echo "  ✓ Uploaded to node1"
else
  echo "  ✗ Failed to upload to node1"
  exit 1
fi

# Worker 2 (uncomment if you have a second worker)
# echo "  -> Uploading to node2..."
# if scp "${IMAGE_FILE}" "${NODE2_HOST}:~/" ; then
#   echo "  ✓ Uploaded to node2"
# else
#   echo "  ✗ Failed to upload to node2"
#   exit 1
# fi

echo ""

# Step 3: Load images into containerd on worker nodes
echo "[3/3] Loading images into containerd on worker nodes..."

# Worker 1
echo "  -> Loading on node1..."
if ssh "${NODE1_HOST}" "sudo ctr -n k8s.io image import ~/${IMAGE_FILE}" ; then
  echo "  ✓ Image loaded into containerd on node1"
else
  echo "  ✗ Failed to load image on node1"
  exit 1
fi

# Worker 2 (uncomment if you have a second worker)
# echo "  -> Loading on node2..."
# if ssh "${NODE2_HOST}" "sudo ctr -n k8s.io image import ~/${IMAGE_FILE}" ; then
#   echo "  ✓ Image loaded into containerd on node2"
# else
#   echo "  ✗ Failed to load image on node2"
#   exit 1
# fi

echo ""

# Cleanup
echo "Cleaning up local image file..."
rm -f "${IMAGE_FILE}"

echo ""
echo "=========================================="
echo "Distribution Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. SSH back to node0: ssh ${NODE0_HOST}"
echo "  2. Deploy the CNI: ./deploy-ovn-cni.sh"
echo ""
echo "Or deploy directly from your laptop:"
echo "  ssh ${NODE0_HOST} './deploy-ovn-cni.sh'"
echo "=========================================="
