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
git checkout <branch>

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

OVN-Kubernetes pods request certificates for authentication. These must be approved:

```bash
# Check for pending CSRs
kubectl get csr

# Approve all pending CSRs
kubectl get csr -o name | xargs kubectl certificate approve

# Verify all are approved
kubectl get csr
```

**Expected:** All CSRs should show `CONDITION: Approved,Issued`

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

## References

- [OVN-Kubernetes Documentation](https://github.com/ovn-org/ovn-kubernetes)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [kubeadm Setup](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
