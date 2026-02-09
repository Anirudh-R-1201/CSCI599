# CloudLab-Specific Setup Guide

This guide explains the CloudLab-specific changes made to handle SSH restrictions between nodes.

## The Problem

CloudLab nodes cannot SSH to each other by default because:
- Each node has independent SSH configuration
- No shared SSH keys between nodes
- Password authentication is disabled

This breaks the original `install-ovn-cni.sh` which tried to distribute Docker images via `scp` between nodes.

## The Solution

We split the CNI installation into three phases:

### Phase 1: Build (on node0)
**Script:** `install-ovn-cni.sh`
- Builds the OVN-Kubernetes Docker image
- Saves it as `~/ovn-kube.tar` (uncompressed for containerd)
- Imports into local containerd on node0
- Does NOT attempt distribution to workers

### Phase 2: Distribute (two options)

**Option A - Via Your Laptop (RECOMMENDED):**

**Script:** `distribute-image-from-local.sh` (run on your laptop)
- Downloads image from node0 to your laptop
- Uploads to all worker nodes
- Imports image into containerd on each worker (K8s 1.29 uses containerd, not Docker)

**Option B - With SSH Setup:**

**Script:** `distribute-and-deploy-cni.sh` (run on node0)
- Tests SSH connectivity to each worker
- Distributes image if SSH works
- Falls back gracefully if SSH fails
- Also deploys the CNI

### Phase 3: Deploy (on node0)
**Script:** `deploy-ovn-cni.sh`
- Installs `jinjanator` if needed (Python templating tool)
- Generates OVN-Kubernetes manifests to `dist/yaml/`
- Deploys to cluster (core manifests)
- Gracefully handles CRD validation errors (K8s version compatibility)
- Waits for pods to be ready

## Quick Start for CloudLab

### On node0:
```bash
# Build the image (~15 minutes)
./install-ovn-cni.sh
```

### On your laptop:
```bash
# Edit hostnames in the script first
vim distribute-image-from-local.sh

# Distribute the image (~2 minutes)
./distribute-image-from-local.sh
```

### Back on node0:
```bash
# Deploy the CNI (~3 minutes)
./deploy-ovn-cni.sh

# Verify
kubectl get nodes
kubectl get pods -n ovn-kubernetes
```

## Files Created/Modified

**New Scripts:**
- `install-ovn-cni.sh` - Build OVN image only
- `distribute-and-deploy-cni.sh` - Distribute + deploy (if SSH configured)
- `deploy-ovn-cni.sh` - Deploy CNI only (after manual distribution)
- `distribute-image-from-local.sh` - Helper for laptop-based distribution

**Modified:**
- `all.sh` - Added docker group membership
- `README.md` - Updated with CloudLab-specific instructions

**Unchanged:**
- `node0.sh` - Control plane initialization
- `worker.sh` - Worker join script

## Why This Approach?

1. **Works with CloudLab restrictions** - No inter-node SSH required
2. **Flexible** - Multiple distribution methods
3. **Fail-safe** - Each phase can be retried independently
4. **Clear feedback** - Scripts show exactly what's happening
5. **Maintains security** - Doesn't require lowering SSH security

## Troubleshooting

### "Permission denied (publickey)" when distributing
- This is expected on CloudLab
- Use Method A (laptop-based distribution)
- Or set up SSH keys manually (see README)

### Nodes stay NotReady
- Wait 2-3 minutes after deployment
- Check: `kubectl get pods -n ovn-kubernetes`
- Verify workers have image in containerd: `ssh worker 'sudo ctr -n k8s.io image ls | grep ovn-kube'`

### ImagePullBackOff
- Workers don't have the image **in containerd** (Kubernetes uses containerd, not Docker)
- Re-run distribution step
- Or load manually on worker: `sudo ctr -n k8s.io image import ~/ovn-kube.tar`

### CRD Validation Errors
- Some CRDs fail with "undeclared reference to 'isCIDR'" or similar CEL errors
- This is a K8s version compatibility issue (OVN-Kubernetes CRDs use CEL functions not in K8s 1.29)
- **This is OK** - core OVN functionality works without these advanced CRDs

## Alternative: Setting Up Inter-Node SSH

If you want nodes to communicate directly (optional):

```bash
# On your laptop, for each worker:
ssh node0 cat ~/.ssh/id_ed25519.pub  # Copy this output

ssh node1 "echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys"
ssh node2 "echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys"

# Test from node0
ssh node0
ssh node1 hostname  # Should work now
ssh node2 hostname  # Should work now

# Now you can use the all-in-one script
./distribute-and-deploy-cni.sh
```

But the laptop-based method is simpler and more reliable for CloudLab.
