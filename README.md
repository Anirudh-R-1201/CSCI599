# Kubernetes + OVN-Kubernetes Setup on CloudLab

This guide describes how to provision a multi-node Kubernetes cluster on CloudLab and manually build/deploy OVN-Kubernetes CNI.

---

## Repository Contents

```
CSCI599/
├── all.sh              # Common setup (containerd, Docker, Kubernetes v1.29, networking)
├── node0.sh            # Control-plane initialization with kubeadm
├── worker.sh           # Worker node join script
├── stage1-baseline/    # Kind-based baseline testing scripts
└── README.md           # This document
```

---

## Prerequisites

- CloudLab experiment with **2+ Ubuntu 22.04 nodes**
  - `node0`: control plane
  - `node1`, `node2`, ...: worker nodes
- SSH access to all nodes
- Internet connectivity on all nodes
- Git access to `Anirudh-R-1201/ovn-kubernetes` (nw-affinity branch)

---

## Part 1: Kubernetes Cluster Setup

### Step 1: Common Setup (ALL Nodes)

On **all nodes** (node0, node1, node2, ...):

```bash
cd ~/CSCI599
chmod +x all.sh
./all.sh
```

**What this does:**
- Installs containerd (Kubernetes ≥1.24 CRI)
- Installs Docker (for building images)
- Adds user to docker group
- Installs Kubernetes v1.29 (kubelet, kubeadm, kubectl)
- Configures kubelet for containerd
- Sets up networking (bridge-netfilter, ip_forward)
- Disables swap
- Enables kubelet service

**After running, activate Docker permissions:**
```bash
newgrp docker
# OR log out and log back in
```

---

### Step 2: Initialize Control Plane (node0 only)

On **node0**:

```bash
chmod +x node0.sh
./node0.sh
```

**What this does:**
- Runs `kubeadm init` with Pod CIDR `10.128.0.0/14` and Service CIDR `172.30.0.0/16`
- Copies kubeconfig to `~/.kube/config`
- Generates `join.sh` with the worker join command

**Save the join command:**
```bash
cat join.sh
```

---

### Step 3: Join Worker Nodes

On **each worker node** (node1, node2, ...):

```bash
chmod +x worker.sh
./worker.sh "<kubeadm join command from node0>"
```

**Example:**
```bash
./worker.sh "kubeadm join 128.110.217.119:6443 --token abc123... --discovery-token-ca-cert-hash sha256:xyz..."
```

---

### Step 4: Verify Cluster

On **node0**:

```bash
kubectl get nodes
# All nodes should show, but will be NotReady (no CNI yet)

kubectl get pods -A
# Only kube-system pods will be running
```

---

## Part 2: OVN-Kubernetes CNI Deployment (Manual)

### Step 1: Install Dependencies (node0)

```bash
# Install Go 1.21.7
cd ~
curl -LO https://go.dev/dl/go1.21.7.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.7.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
export PATH=$PATH:/usr/local/go/bin
go version

# Install jinjanator (for manifest generation)
pip3 install --user jinjanator
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
```

---

### Step 2: Clone and Patch OVN-Kubernetes (node0)

```bash
# Clone your custom OVN-Kubernetes fork
cd ~
git clone git@github.com:Anirudh-R-1201/ovn-kubernetes.git
cd ovn-kubernetes
git checkout nw-affinity

# CRITICAL: Patch kubectl commands to fix API server discovery issues
# This adds --validate=false to all kubectl commands in the startup scripts
sed -i.bak 's/kubectl apply -f/kubectl apply --validate=false -f/g' dist/images/ovnkube.sh
sed -i.bak 's/kubectl create -f/kubectl create --validate=false -f/g' dist/images/ovnkube.sh
sed -i.bak 's/kubectl patch \([^-]\)/kubectl patch --validate=false \1/g' dist/images/ovnkube.sh

# Verify patch was applied
grep "kubectl apply --validate=false" dist/images/ovnkube.sh
```

**Why this patch is needed:**
- CloudLab kubeadm clusters sometimes have API server discovery issues
- The error: "server rejected our request for an unknown reason"
- Without this patch, `ovnkube-db` pods will crash in CrashLoopBackOff
- The `--validate=false` flag bypasses the broken OpenAPI validation

---

### Step 3: Build OVN-Kubernetes Image (node0)

```bash
cd ~/ovn-kubernetes/dist/images

# Build Ubuntu-based image (10-15 minutes)
make ubuntu-image

# Tag for deployment
docker tag ovn-kube-ubuntu:latest ovn-kube:latest

# Save for distribution to workers
cd ~
docker save ovn-kube:latest -o ovn-kube.tar

# Import into local containerd
sudo ctr -n k8s.io image import ovn-kube.tar
```

---

### Step 4: Distribute Image to Workers

**From your laptop:**

```bash
# Download from node0
scp node0:~/ovn-kube.tar .

# Upload to each worker
scp ovn-kube.tar node1:~/
scp ovn-kube.tar node2:~/
```

**On each worker node:**

```bash
sudo ctr -n k8s.io image import ~/ovn-kube.tar

# Verify
sudo ctr -n k8s.io image ls | grep ovn-kube
```

---

### Step 5: Generate OVN Manifests (node0)

```bash
cd ~/ovn-kubernetes/dist/images

# Ensure jinjanate is in PATH
export PATH="$HOME/.local/bin:$PATH"

# Generate manifests
./daemonset.sh \
  --image=ovn-kube:latest \
  --net-cidr=10.128.0.0/14 \
  --svc-cidr=172.30.0.0/16

# Verify manifests were created
ls -lh ../yaml/
```

---

### Step 6: Prepare OVN Directories (All Nodes)

**On node0:**
```bash
sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data
sudo chmod 755 /var/lib/ovn /var/lib/ovn/etc /var/lib/ovn/data
```

**On each worker (node1, node2, ...):**
```bash
ssh node1 "sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data && sudo chmod 755 /var/lib/ovn /var/lib/ovn/etc /var/lib/ovn/data"
ssh node2 "sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data && sudo chmod 755 /var/lib/ovn /var/lib/ovn/etc /var/lib/ovn/data"
```

---

### Step 7: Deploy OVN-Kubernetes (node0)

```bash
cd ~/ovn-kubernetes

# Apply setup (creates namespaces and ConfigMap)
kubectl apply -f dist/yaml/ovn-setup.yaml

# Fix API server address in ConfigMap
CORRECT_API_SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||')
kubectl patch configmap ovn-config -n ovn-kubernetes --type merge -p "{\"data\":{\"k8s_apiserver\":\"${CORRECT_API_SERVER}\"}}"

# Apply RBAC manifests
kubectl apply -f dist/yaml/rbac-ovnkube-db.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-master.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-node.yaml

# Apply OpenVSwitch daemonset (must be first)
kubectl apply -f dist/yaml/ovs-node.yaml

# Wait for OVS to be ready
kubectl wait --for=condition=ready pod -l name=ovs-node -n ovn-kubernetes --timeout=120s

# Apply OVN database
kubectl apply -f dist/yaml/ovnkube-db.yaml

# Wait for database to initialize (60-90 seconds)
sleep 60
kubectl wait --for=condition=ready pod -l name=ovnkube-db -n ovn-kubernetes --timeout=180s

# Apply OVN master (control plane)
kubectl apply -f dist/yaml/ovnkube-master.yaml

# Apply OVN node (data plane)
kubectl apply -f dist/yaml/ovnkube-node.yaml
```

---

### Step 8: Verify Deployment

```bash
# Check pod status
kubectl get pods -n ovn-kubernetes -o wide

# Check node status (should now be Ready)
kubectl get nodes -o wide

# Check logs if issues
kubectl logs -n ovn-kubernetes -l name=ovnkube-db --all-containers --tail=50
kubectl logs -n ovn-kubernetes -l name=ovnkube-master --all-containers --tail=50
kubectl logs -n ovn-kubernetes -l app=ovnkube-node --all-containers --tail=30
```

**Expected result:**
```
NAME                READY   STATUS    RESTARTS   AGE
ovnkube-db-xxx      2/2     Running   0          5m
ovnkube-master-xxx  2/2     Running   0          4m
ovnkube-node-xxx    3/3     Running   0          3m
ovs-node-xxx        1/1     Running   0          6m
```

**Nodes should be Ready:**
```
NAME     STATUS   ROLES           AGE   VERSION
node0    Ready    control-plane   30m   v1.29.15
node1    Ready    <none>          29m   v1.29.15
```

---

## Troubleshooting

### Nodes Still NotReady

Check CNI status:
```bash
kubectl get pods -n ovn-kubernetes
kubectl logs -n ovn-kubernetes -l app=ovnkube-node --tail=50
```

### ovnkube-db CrashLoopBackOff

**Common causes:**
1. **Port conflicts** - Stale OVN processes on host
2. **API server discovery issues** - Missing kubectl patch
3. **Permission issues** - Database directories not writable

**Fix:**
```bash
# Kill stale processes
sudo pkill -9 ovsdb-server ovs-vswitchd ovn-northd ovn-controller

# Clean up
kubectl delete namespace ovn-kubernetes
sudo rm -rf /var/lib/ovn/* /var/run/ovn/* /etc/ovn/*

# On workers too
ssh node1 "sudo rm -rf /var/lib/ovn/* /var/run/ovn/*"

# Redeploy from Step 7
```

### API Server Discovery Errors

If you see:
```
Error from server (BadRequest): the server rejected our request for an unknown reason
error validating data: failed to download openapi
```

**You MUST patch the OVN startup scripts (Step 2):**
```bash
cd ~/ovn-kubernetes
sed -i.bak 's/kubectl apply -f/kubectl apply --validate=false -f/g' dist/images/ovnkube.sh
sed -i.bak 's/kubectl create -f/kubectl create --validate=false -f/g' dist/images/ovnkube.sh

# REBUILD the image
cd dist/images
make ubuntu-image
docker tag ovn-kube-ubuntu:latest ovn-kube:latest
docker save ovn-kube:latest -o ~/ovn-kube.tar
sudo ctr -n k8s.io image import ~/ovn-kube.tar

# Redistribute to workers and redeploy
```

### ImagePullBackOff on Workers

Workers don't have the image in containerd:
```bash
# On worker
sudo ctr -n k8s.io image ls | grep ovn-kube

# If missing, import it
sudo ctr -n k8s.io image import ~/ovn-kube.tar
```

---

## Complete Cleanup

To completely remove OVN and start over:

```bash
# Delete Kubernetes resources
kubectl delete namespace ovn-kubernetes ovn-host-network
kubectl delete clusterrole ovnkube-db ovnkube-master ovnkube-node ovnkube-node-reader
kubectl delete clusterrolebinding ovnkube-db ovnkube-master ovnkube-node ovnkube-node-reader

# Clean filesystem on all nodes
sudo rm -rf /var/lib/ovn/* /var/run/ovn/* /etc/ovn/* /var/log/ovn/*
ssh node1 "sudo rm -rf /var/lib/ovn/* /var/run/ovn/* /etc/ovn/*"
ssh node2 "sudo rm -rf /var/lib/ovn/* /var/run/ovn/* /etc/ovn/*"
```

---

## Network Configuration

**Default settings:**
- Pod CIDR: `10.128.0.0/14`
- Service CIDR: `172.30.0.0/16`
- MTU: `1400` (default)

**To change CIDRs:**
1. Modify `node0.sh` before cluster init
2. Use matching CIDRs in `daemonset.sh --net-cidr` and `--svc-cidr`

---

## Quick Reference

### Cluster Setup
```bash
# On all nodes
./all.sh && newgrp docker

# On node0
./node0.sh
cat join.sh  # Copy this command

# On each worker
./worker.sh "<join command>"
```

### OVN-Kubernetes Deployment
```bash
# On node0
cd ~
git clone git@github.com:Anirudh-R-1201/ovn-kubernetes.git
cd ovn-kubernetes
git checkout nw-affinity

# Patch (CRITICAL)
sed -i 's/kubectl apply -f/kubectl apply --validate=false -f/g' dist/images/ovnkube.sh

# Build and distribute
cd dist/images && make ubuntu-image
docker tag ovn-kube-ubuntu:latest ovn-kube:latest
docker save ovn-kube:latest -o ~/ovn-kube.tar
sudo ctr -n k8s.io image import ~/ovn-kube.tar

# Distribute to workers (from laptop)
scp node0:~/ovn-kube.tar . && scp ovn-kube.tar node1:~/
ssh node1 "sudo ctr -n k8s.io image import ~/ovn-kube.tar"

# Generate manifests
cd ~/ovn-kubernetes/dist/images
./daemonset.sh --image=ovn-kube:latest --net-cidr=10.128.0.0/14 --svc-cidr=172.30.0.0/16

# Prepare directories on all nodes
sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data && sudo chmod 755 /var/lib/ovn /var/lib/ovn/etc /var/lib/ovn/data
ssh node1 "sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data && sudo chmod 755 /var/lib/ovn /var/lib/ovn/etc /var/lib/ovn/data"

# Deploy
cd ~/ovn-kubernetes
kubectl apply -f dist/yaml/ovn-setup.yaml
kubectl patch configmap ovn-config -n ovn-kubernetes --type merge -p "{\"data\":{\"k8s_apiserver\":\"$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||')\"}}"
kubectl apply -f dist/yaml/rbac-ovnkube-db.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-master.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-node.yaml
kubectl apply -f dist/yaml/ovs-node.yaml
kubectl wait --for=condition=ready pod -l name=ovs-node -n ovn-kubernetes --timeout=120s
kubectl apply -f dist/yaml/ovnkube-db.yaml
sleep 60
kubectl apply -f dist/yaml/ovnkube-master.yaml
kubectl apply -f dist/yaml/ovnkube-node.yaml

# Verify
kubectl get nodes
kubectl get pods -n ovn-kubernetes
```

---

## stage1-baseline: Kind-Based Testing

For quick testing without CloudLab cluster issues, use the Kind-based setup:

```bash
cd ~/CSCI599/stage1-baseline
./00-localonly-kind-ovn-upstream.sh
```

This creates a self-contained Kind cluster with upstream OVN-Kubernetes.

**Baseline workflow:**
```bash
# 1. Create cluster
./00-localonly-kind-ovn-upstream.sh

# 2. Deploy workload
./02-deploy-workload.sh

# 3. Generate load
./03-generate-self-similar-load.sh

# 4. Collect results
./04-collect-baseline.sh

# 5. Snapshot placement
./05-snapshot-pod-placement.sh
```

---

## Important Notes

### 1. kubectl --validate=false Patch

**This is CRITICAL for CloudLab deployments.**

Without this patch, you'll see:
```
Error from server (BadRequest): the server rejected our request for an unknown reason
Failed to create endpoint for ovnkube-db service
```

The patch MUST be applied before building the image (Step 2).

### 2. Image Distribution

- Kubernetes uses **containerd** (not Docker) as the runtime
- Images MUST be imported with: `sudo ctr -n k8s.io image import`
- Do NOT use `docker load` on worker nodes

### 3. Deployment Order

The order matters:
1. ovn-setup (namespaces)
2. RBAC manifests
3. ovs-node (OpenVSwitch first)
4. ovnkube-db (database must be ready)
5. ovnkube-master (control plane)
6. ovnkube-node (data plane)

### 4. Node Communication

- Nodes communicate via internal IPs (usually `128.110.217.x`)
- SSH between nodes may require key setup
- Or distribute images via your laptop as intermediary

---

## Advanced

### Rebuild After Code Changes

```bash
cd ~/ovn-kubernetes
git pull origin nw-affinity

# Reapply the kubectl patch
sed -i 's/kubectl apply -f/kubectl apply --validate=false -f/g' dist/images/ovnkube.sh

# Rebuild
cd dist/images && make ubuntu-image
docker tag ovn-kube-ubuntu:latest ovn-kube:latest
docker save ovn-kube:latest -o ~/ovn-kube.tar
sudo ctr -n k8s.io image import ~/ovn-kube.tar

# Redistribute to workers
# ... (use laptop or SSH)

# Clean old deployment
kubectl delete namespace ovn-kubernetes
sudo rm -rf /var/lib/ovn/*

# Redeploy (Step 7 from Part 2)
```

---

## Quick Commands

```bash
# Cluster status
kubectl get nodes
kubectl get pods -A

# OVN status
kubectl get pods -n ovn-kubernetes -o wide
kubectl logs -n ovn-kubernetes -l name=ovnkube-db -c nb-ovsdb --tail=50
kubectl logs -n ovn-kubernetes -l name=ovnkube-db -c sb-ovsdb --tail=50

# Restart OVN components
kubectl rollout restart -n ovn-kubernetes deployment/ovnkube-db
kubectl rollout restart -n ovn-kubernetes deployment/ovnkube-master
kubectl rollout restart -n ovn-kubernetes daemonset/ovnkube-node

# Complete cleanup
kubectl delete namespace ovn-kubernetes
sudo rm -rf /var/lib/ovn/* /var/run/ovn/*
```

---

## References

- [OVN-Kubernetes Documentation](https://github.com/ovn-org/ovn-kubernetes)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [kubeadm Setup](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
