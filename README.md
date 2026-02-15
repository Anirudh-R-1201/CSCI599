# Kubernetes + OVN-Kubernetes Setup on CloudLab

This guide describes how to provision a multi-node Kubernetes cluster on CloudLab and manually build/deploy OVN-Kubernetes CNI.

---

## Prerequisites

- CloudLab experiment with **2+ Ubuntu 22.04 nodes**
  - `node0`: control plane
  - `node1`, `node2`, ...: worker nodes
- SSH access to all nodes
- Internet connectivity on all nodes
- Git access to `Anirudh-R-1201/ovn-kubernetes` (nw-affinity branch)

**Clone this repository:**
```bash
git clone https://github.com/Anirudh-R-1201/CSCI599.git
cd CSCI599
```

**IMPORTANT:** CloudLab nodes have DNS issues that must be fixed **before** proceeding. See Step 5 in Part 1 below.
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

### Step 5: Fix DNS Permanently (ALL Nodes) - CRITICAL

**CloudLab Issue:** systemd-resolved often fails on CloudLab, causing DNS resolution to break. This prevents image pulls and API server access.

**Fix DNS permanently on ALL nodes before proceeding:**

**On each node (node0, node1, node2, ...):**

```bash
# Stop systemd-resolved from managing DNS
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved

# Remove the symlink
sudo rm -f /etc/resolv.conf

# Create a real DNS configuration file
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
search utah.cloudlab.us
EOF'

# Make it immutable (prevents systemd from overwriting)
sudo chattr +i /etc/resolv.conf

# Test DNS
nslookup google.com
```

**From node0, fix all nodes at once:**

```bash
# Fix node0 (local)
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo rm -f /etc/resolv.conf
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
search utah.cloudlab.us
EOF'
sudo chattr +i /etc/resolv.conf

# Fix node1
ssh node1 "sudo systemctl stop systemd-resolved && \
           sudo systemctl disable systemd-resolved && \
           sudo rm -f /etc/resolv.conf && \
           sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
search utah.cloudlab.us
EOF' && \
           sudo chattr +i /etc/resolv.conf"

# Fix node2
ssh node2 "sudo systemctl stop systemd-resolved && \
           sudo systemctl disable systemd-resolved && \
           sudo rm -f /etc/resolv.conf && \
           sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
search utah.cloudlab.us
EOF' && \
           sudo chattr +i /etc/resolv.conf"

# Verify DNS on all nodes
nslookup github.com
ssh node1 "nslookup github.com"
ssh node2 "nslookup github.com"
```

**Why this is important:**
- Without working DNS, container image pulls will fail
- OVN pods won't be able to reach the Kubernetes API server
- Nodes will remain NotReady
- This fix is **permanent** and survives reboots

---

## Part 2: OVN-Kubernetes CNI Deployment

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
sudo apt install python3-pip
pip3 install --user jinjanator
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
```

---

### Step 2: Clone and Patch OVN-Kubernetes (node0)

```bash
# Clone your custom OVN-Kubernetes fork
cd ~
git clone https://github.com/Anirudh-R-1201/ovn-kubernetes.git
cd ovn-kubernetes
#git checkout <branch>

# CRITICAL: Patch kubectl commands to fix API server discovery issues
sed -i.bak 's/ apply -f/ apply --validate=false -f/g' dist/images/ovnkube.sh
sed -i.bak 's/ create -f/ create --validate=false -f/g' dist/images/ovnkube.sh
sed -i.bak 's/ patch / patch --validate=false /g' dist/images/ovnkube.sh

# Verify patch was applied
grep "apply --validate=false" dist/images/ovnkube.sh
```

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

**From local (your laptop):**

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

# Ensure jinjanator is in PATH
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
sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data && sudo chmod 755 /var/lib/ovn /var/lib/ovn/etc /var/lib/ovn/data
```

---

### Step 7: Deploy OVN-Kubernetes (node0)

```bash
cd ~/ovn-kubernetes

# Apply setup (creates namespaces and ConfigMap)
kubectl apply -f dist/yaml/ovn-setup.yaml

# CRITICAL: Fix API server address in ConfigMap
CORRECT_API_SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
kubectl patch configmap ovn-config -n ovn-kubernetes --type merge -p "{\"data\":{\"k8s_apiserver\":\"${CORRECT_API_SERVER}\"}}"

# Verify the fix
kubectl get configmap -n ovn-kubernetes ovn-config -o jsonpath='{.data.k8s_apiserver}'
echo ""

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

# Wait for pods to start
sleep 10
```

---

### Step 8: Approve Certificate Signing Requests (node0)

**CRITICAL:** OVN-Kubernetes pods request certificates for authentication. These must be manually approved the first time.

```bash
# Check for pending CSRs
kubectl get csr

# Approve all pending CSRs
kubectl get csr -o name | xargs kubectl certificate approve

# Verify all are approved (should show "Approved,Issued")
kubectl get csr
```

**Expected:** All CSRs should show `CONDITION: Approved,Issued`

---

### Step 8b: Enable Automatic CSR Approval (OPTIONAL but Recommended)

To avoid having to manually approve CSRs every time OVN pods restart, set up automatic approval:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: csr-approver
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: csr-approver
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
subjects:
- kind: ServiceAccount
  name: csr-approver
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: csr-approver-approve
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
subjects:
- kind: ServiceAccount
  name: csr-approver
  namespace: kube-system
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: csr-approver
  namespace: kube-system
spec:
  schedule: "*/1 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: csr-approver
          restartPolicy: OnFailure
          containers:
          - name: approver
            image: bitnami/kubectl:latest
            command:
            - /bin/sh
            - -c
            - |
              kubectl get csr -o json | \
              jq -r '.items[] | select(.status.conditions == null) | .metadata.name' | \
              xargs -r kubectl certificate approve
EOF
```

**What this does:**
- Creates a CronJob that runs every minute
- Automatically approves any pending CSRs
- Prevents OVN pods from crashing due to certificate expiration

**Verify it's working:**
```bash
# Check cronjob exists
kubectl get cronjob -n kube-system csr-approver

# Check if jobs are running
kubectl get jobs -n kube-system | grep csr-approver
```

---

### Step 9: Restart Services on Worker Nodes

**CRITICAL:** Containerd and kubelet must be restarted to detect the CNI configuration.

**On each worker node (node1, node2, ...):**

```bash
# Fix CNI config permissions (if needed)
sudo chmod 644 /etc/cni/net.d/10-ovn-kubernetes.conf

# Restart containerd to reload CNI configuration
sudo systemctl restart containerd

# Wait for containerd to fully restart
sleep 10

# Restart kubelet to initialize CNI
sudo systemctl restart kubelet

# Verify kubelet is running
sudo systemctl status kubelet

# Check for CNI errors (should see no more "plugin not initialized")
sudo journalctl -u kubelet -n 20 --no-pager | grep -i cni
```

---

### Step 10: Verify Deployment

**Wait 30-60 seconds** after restarting kubelet, then check:

```bash
# Check pod status
kubectl get pods -n ovn-kubernetes -o wide

# Check node status (ALL nodes should now be Ready)
kubectl get nodes -o wide

# Verify CNI is working
kubectl get pods -A
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

## Critical CloudLab Setup Summary

For a successful deployment on CloudLab, follow this exact order:

### 1. Fix DNS FIRST (Before Everything)
```bash
# On all nodes, permanently fix DNS
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo rm -f /etc/resolv.conf
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF'
sudo chattr +i /etc/resolv.conf
```

**Why:** Without working DNS, nothing will work - no image pulls, no git, no package installs.

### 2. Setup Kubernetes Cluster (Part 1)
```bash
# All nodes: ./all.sh
# node0: ./node0.sh
# Workers: ./worker.sh "<join command>"
```

### 3. Build and Deploy OVN-Kubernetes (Part 2, Steps 1-7)
- Patch kubectl commands with `--validate=false`
- Build and distribute image
- Generate manifests
- Deploy OVN components

### 4. Approve CSRs Manually (First Time)
```bash
kubectl get csr -o name | xargs kubectl certificate approve
```

**Why:** OVN pods need certificates to communicate with API server. First approval must be manual.

### 5. Setup Auto-CSR Approval (One-Time)
Deploy the CSR approver CronJob (Step 8b) so you never have to manually approve again.

### 6. Restart Worker Services
```bash
# On each worker
sudo chmod 644 /etc/cni/net.d/10-ovn-kubernetes.conf
sudo systemctl restart containerd && sleep 10 && sudo systemctl restart kubelet
```

**Why:** Kubelet and containerd need to reload CNI configuration.

### 7. Verify Everything
```bash
kubectl get nodes  # All Ready
kubectl get pods -n ovn-kubernetes  # All 3/3 Running
```

---

## Common Mistakes

### ❌ Deploying without fixing DNS first
**Result:** Image pulls fail, pods stuck in ImagePullBackOff

### ❌ Forgetting to approve CSRs
**Result:** ovnkube-node pods crash with "certificate not signed"

### ❌ Not restarting containerd after DNS fix
**Result:** Containerd cached old DNS, image pulls still fail

### ❌ Patching after building the image
**Result:** ovnkube-db crashes with API server validation errors

### ❌ Not restarting kubelet on workers
**Result:** Nodes stay NotReady with "cni plugin not initialized"

---

## Quick Start (Complete Workflow)

For experienced users, here's the complete workflow:

```bash
# === Part 1: Kubernetes Cluster ===

# On all nodes: Fix DNS FIRST
sudo systemctl stop systemd-resolved && sudo systemctl disable systemd-resolved
sudo rm -f /etc/resolv.conf
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF'
sudo chattr +i /etc/resolv.conf

# On all nodes: Setup Kubernetes
cd ~/CSCI599
./all.sh && newgrp docker

# On node0: Initialize control plane
./node0.sh
cat join.sh

# On workers: Join cluster
./worker.sh "<join command from node0>"

# === Part 2: OVN-Kubernetes CNI ===

# On node0: Install dependencies
curl -LO https://go.dev/dl/go1.21.7.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.7.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
pip3 install --user jinjanator
export PATH="$HOME/.local/bin:$PATH"

# On node0: Clone and patch OVN-Kubernetes
git clone https://github.com/Anirudh-R-1201/ovn-kubernetes.git
cd ovn-kubernetes
sed -i 's/ apply -f/ apply --validate=false -f/g' dist/images/ovnkube.sh
sed -i 's/ create -f/ create --validate=false -f/g' dist/images/ovnkube.sh
sed -i 's/ patch / patch --validate=false /g' dist/images/ovnkube.sh

# Build and distribute
cd dist/images && make ubuntu-image
docker tag ovn-kube-ubuntu:latest ovn-kube:latest
docker save ovn-kube:latest -o ~/ovn-kube.tar
sudo ctr -n k8s.io image import ~/ovn-kube.tar

# From laptop: distribute to workers
scp node0:~/ovn-kube.tar .
scp ovn-kube.tar node1:~/
scp ovn-kube.tar node2:~/

# On workers: import image
ssh node1 "sudo ctr -n k8s.io image import ~/ovn-kube.tar"
ssh node2 "sudo ctr -n k8s.io image import ~/ovn-kube.tar"

# On all nodes: prepare directories
sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data
ssh node1 "sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data"
ssh node2 "sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data"

# On node0: generate and deploy
cd ~/ovn-kubernetes/dist/images
./daemonset.sh --image=ovn-kube:latest --net-cidr=10.128.0.0/14 --svc-cidr=172.30.0.0/16

cd ~/ovn-kubernetes
kubectl apply -f dist/yaml/ovn-setup.yaml
CORRECT_API_SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
kubectl patch configmap ovn-config -n ovn-kubernetes --type merge -p "{\"data\":{\"k8s_apiserver\":\"${CORRECT_API_SERVER}\"}}"
kubectl apply -f dist/yaml/rbac-ovnkube-db.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-master.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-node.yaml
kubectl apply -f dist/yaml/ovs-node.yaml
sleep 30
kubectl apply -f dist/yaml/ovnkube-db.yaml
sleep 60
kubectl apply -f dist/yaml/ovnkube-master.yaml
kubectl apply -f dist/yaml/ovnkube-node.yaml

# Approve CSRs (FIRST TIME - MANUAL)
sleep 10
kubectl get csr -o name | xargs kubectl certificate approve

# Setup auto-approval (see Step 8b for full YAML)
kubectl apply -f csr-approver.yaml

# On workers: restart services
ssh node1 "sudo chmod 644 /etc/cni/net.d/10-ovn-kubernetes.conf && \
           sudo systemctl restart containerd && sleep 10 && \
           sudo systemctl restart kubelet"
ssh node2 "sudo chmod 644 /etc/cni/net.d/10-ovn-kubernetes.conf && \
           sudo systemctl restart containerd && sleep 10 && \
           sudo systemctl restart kubelet"

# Verify
kubectl get nodes
kubectl get pods -n ovn-kubernetes -o wide
```

---

## References

- [OVN-Kubernetes Documentation](https://github.com/ovn-org/ovn-kubernetes)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [kubeadm Setup](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
