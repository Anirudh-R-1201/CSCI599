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
**Merged cmd**

```bash
git clone https://github.com/Anirudh-R-1201/CSCI599.git && cd CSCI599 && chmod +x *.sh && ./all.sh && sleep 10 && newgrp docker
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


### Step 4.1: Traceroutes to find locatlity
```bash
traceroute -n node1.599test.csci599-pg0.utah.cloudlab.us
traceroute -n node2.599test.csci599-pg0.utah.cloudlab.us
traceroute -n node3.599test.csci599-pg0.utah.cloudlab.us
traceroute -n node4.599test.csci599-pg0.utah.cloudlab.us
traceroute -n node5.599test.csci599-pg0.utah.cloudlab.us
```
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

**Why this is important:**
- Without working DNS, container image pulls will fail
- OVN pods won't be able to reach the Kubernetes API server
- Nodes will remain NotReady
- This fix is **permanent** and survives reboots

---

## Part 2: OVN-Kubernetes CNI Deployment

> **Two build variants are supported.** Steps that differ between them are marked:
> - **[BASE]** — standard build, compiled on node0
> - **[TOPO]** — topology-aware build (`topo-aware` branch), pre-built on your laptop

---

### Step 1: Install Dependencies (node0)

```bash
# Install jinjanator (required for manifest generation — both variants)
sudo apt install python3-pip -y
pip3 install --user jinjanator matplotlib
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile
```

**[Both version]** Also install Go for compiling on node0:

```bash
curl -LO https://go.dev/dl/go1.21.7.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.7.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
export PATH=$PATH:/usr/local/go/bin
go version
```

---

### Step 2: Clone OVN-Kubernetes and apply CloudLab patches (node0)

```bash
cd ~
git clone https://github.com/Anirudh-R-1201/ovn-kubernetes.git
cd ovn-kubernetes

# [TOPO] checkout the topo-aware branch
git checkout topo-aware

# CRITICAL: patch kubectl calls to fix API server validation on CloudLab
sed -i 's/ apply -f/ apply --validate=false -f/g' dist/images/ovnkube.sh
sed -i 's/ create -f/ create --validate=false -f/g' dist/images/ovnkube.sh
sed -i 's/ patch / patch --validate=false /g' dist/images/ovnkube.sh

grep "apply --validate=false" dist/images/ovnkube.sh  # verify
```

---

### Step 3: Build or obtain the OVN-Kubernetes image

** Build on node0 (~15 minutes):**

```bash
cd ~/ovn-kubernetes/dist/images
make ubuntu-image
docker tag ovn-kube-ubuntu:latest ovn-kube:latest
docker save ovn-kube:latest -o ~/ovn-kube.tar
```


---

### Step 4: Distribute image to all nodes

**From node0**, push the tar to every node and import into containerd:

```bash

# Do on each node once distributed
sudo ctr -n k8s.io image import ~/ovn-kube.tar 
sudo ctr -n k8s.io image ls | grep ovn-kube
```

---

### Step 5: Prepare OVN data directories (All Nodes)

```bash
sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data
sudo chmod 755 /var/lib/ovn /var/lib/ovn/etc /var/lib/ovn/data


```

---

### Step 6: Generate OVN manifests (node0)

```bash
cd ~/ovn-kubernetes/dist/images
export PATH="$HOME/.local/bin:$PATH"
```

**[BASE]:**

```bash
./daemonset.sh \
  --image=ovn-kube:latest \
  --net-cidr=10.128.0.0/14 \
  --svc-cidr=172.30.0.0/16
```

**[TOPO]:**

```bash
OVN_ENABLE_TOPOLOGY_AWARE_LB=true ./daemonset.sh \
  --image=ovn-kube-topo:latest \
  --net-cidr=10.128.0.0/14 \
  --svc-cidr=172.30.0.0/16 \
  --enable-topology-aware-lb=true

# Verify the flag was baked in
grep "TOPOLOGY_AWARE" ../yaml/ovnkube-master.yaml
# Expected: value: "true"
```

---

### Step 7: Approve Certificate Signing Requests (node0, seperate terminal)

**CRITICAL:** OVN pods request certificates that must be manually approved the first time.

```bash
kubectl get csr -o name | xargs kubectl certificate approve
kubectl get csr   # all should show Approved,Issued
# or run
while true; do sleep 2 && kubectl get csr -o name | xargs kubectl certificate approve 2>/dev/null; done
```

---

---

### Step 8: Deploy OVN-Kubernetes (node0)



```bash
cd ~/ovn-kubernetes

kubectl apply -f dist/yaml/ovn-setup.yaml

# Fix API server address (CRITICAL on CloudLab)
CORRECT_API_SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
kubectl patch configmap ovn-config -n ovn-kubernetes --type merge \
  -p "{\"data\":{\"k8s_apiserver\":\"${CORRECT_API_SERVER}\"}}"
kubectl get configmap -n ovn-kubernetes ovn-config -o jsonpath='{.data.k8s_apiserver}'

kubectl apply -f dist/yaml/rbac-ovnkube-db.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-master.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-node.yaml
kubectl apply -f dist/yaml/ovs-node.yaml
kubectl wait --for=condition=ready pod -l name=ovs-node -n ovn-kubernetes --timeout=120s

kubectl apply -f dist/yaml/ovnkube-db.yaml
sleep 60
kubectl wait --for=condition=ready pod -l name=ovnkube-db -n ovn-kubernetes --timeout=180s

kubectl apply -f dist/yaml/ovnkube-master.yaml
kubectl apply -f dist/yaml/ovnkube-node.yaml
sleep 10
```
### If there are errors run 

```bash
TARBALL=$(ls ~/ovn-kube*.tar 2>/dev/null | head -1)
echo "Using tarball: ${TARBALL}"
# Import on node0 itself first
sudo ctr -n k8s.io images import ${TARBALL}
sudo ctr -n k8s.io images tag docker.io/library/ovn-kube:latest docker.io/library/ovn-kube-topo:latest 2>/dev/null || true
# Distribute and import on all workers in parallel
for node in node1 node2 node3; do
  (
    scp -o StrictHostKeyChecking=no ${TARBALL} ${node}:~/ovn-kube.tar
    ssh -o StrictHostKeyChecking=no ${node} "
      sudo ctr -n k8s.io images import ~/ovn-kube.tar
      sudo ctr -n k8s.io images tag docker.io/library/ovn-kube:latest docker.io/library/ovn-kube-topo:latest 2>/dev/null || true
      echo '${node}: done'
    "
  ) &
done
wait
echo "All nodes loaded"
# ── Delete stuck pods so they retry with local image
kubectl delete pod -n ovn-kubernetes \
  $(kubectl get pods -n ovn-kubernetes --no-headers \
    | awk '/ErrImagePull|ImagePullBackOff/{print $1}' | tr '\n' ' ')
kubectl get pods -n ovn-kubernetes -w



```


### Step 9: Restart services on worker nodes (node1, node2...)

**CRITICAL:** Workers need containerd and kubelet restarted to pick up the CNI config.

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

### Step 10: Verify deployment

```bash
sleep 30
kubectl get nodes -o wide          # all should be Ready
kubectl get pods -n ovn-kubernetes -o wide   # all Running


```

**Expected:**
```
NAME              READY   STATUS    RESTARTS
ovnkube-db        2/2     Running   0
ovnkube-master    2/2     Running   0
ovnkube-node      3/3     Running   0  (one per worker)
ovs-node          1/1     Running   0  (one per node)
```

---

### Step 11 [TOPO only]: Label nodes with topology zones and annotate services

**Node zone labels** — assign each worker to a zone. On CloudLab all nodes are typically on the same physical rack, so zones are logical groupings. Measure actual RTT with `ping` between nodes to determine real locality before assigning:

```bash
# Assign zones (adjust grouping based on measured RTT)
# recheck node names from kubectl get nodes -o wide
kubectl label node node1.599test.csci599-pg0.utah.cloudlab.us topology.kubernetes.io/zone=zone-a
kubectl label node node2.599test.csci599-pg0.utah.cloudlab.us topology.kubernetes.io/zone=zone-a
kubectl label node node3.599test.csci599-pg0.utah.cloudlab.us topology.kubernetes.io/zone=zone-a
kubectl label node node4.599test.csci599-pg0.utah.cloudlab.us topology.kubernetes.io/zone=zone-b 
kubectl label node node5.599test.csci599-pg0.utah.cloudlab.us topology.kubernetes.io/zone=zone-b 
kubectl get nodes --show-labels | grep topology
```

**Service opt-in annotation** — the feature only applies to services with this annotation:

```bash
# After deploying online-botique using ./stage1-baseline/00-deploy-boutique.sh
# Fix metrics-server TLS (CloudLab uses self-signed certs)
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl top nodes   # should show CPU/memory after ~60s

for svc in frontend productcatalogservice cartservice checkoutservice \
           currencyservice recommendationservice paymentservice \
           shippingservice emailservice adservice; do
  kubectl annotate service $svc service.kubernetes.io/topology-mode=Auto --overwrite
done

kubectl get services -o custom-columns='NAME:.metadata.name,TOPO:.metadata.annotations.service\.kubernetes\.io/topology-mode'
```

**Toggle the feature on a live cluster without rebuilding:**

```bash
# Enable
kubectl set env deployment/ovnkube-master -n ovn-kubernetes \
  -c ovnkube-master OVN_ENABLE_TOPOLOGY_AWARE_LB=true
kubectl rollout restart deployment/ovnkube-master -n ovn-kubernetes

# Disable (for baseline comparison run)
kubectl set env deployment/ovnkube-master -n ovn-kubernetes \
  -c ovnkube-master OVN_ENABLE_TOPOLOGY_AWARE_LB=false
kubectl rollout restart deployment/ovnkube-master -n ovn-kubernetes
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

### 3. Build and Deploy OVN-Kubernetes (Part 2)
- **[BASE]** Install Go on node0, build with `make ubuntu-image`, distribute tar
- **[TOPO]** Build `ovn-kube-topo.tar` on your laptop (`GOOS=linux GOARCH=amd64 make`), scp to all nodes
- Patch kubectl commands with `--validate=false` (both variants)
- Generate manifests: base uses `./daemonset.sh --image=ovn-kube:latest`, topo uses `OVN_ENABLE_TOPOLOGY_AWARE_LB=true ./daemonset.sh --image=ovn-kube-topo:latest --enable-topology-aware-lb=true`
- Deploy OVN components (Steps 7–10 identical for both)
- **[TOPO]** Step 11: label nodes with `topology.kubernetes.io/zone`, annotate services with `topology-mode: Auto`

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

Set `VARIANT=base` or `VARIANT=topo` at the top and the script adapts:

```bash
# ── CHOOSE VARIANT ──────────────────────────────────────────────
VARIANT=topo          # "base" or "topo"
WORKERS="node1 node2 node3 node4 node5"
# ────────────────────────────────────────────────────────────────

# === Part 1: Kubernetes Cluster (all nodes) ===
sudo systemctl stop systemd-resolved && sudo systemctl disable systemd-resolved
sudo rm -f /etc/resolv.conf
sudo bash -c 'printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > /etc/resolv.conf'
sudo chattr +i /etc/resolv.conf

cd ~/CSCI599 && ./all.sh && newgrp docker
./node0.sh && cat join.sh   # node0 only; run worker.sh on each worker

# === Part 2: OVN-Kubernetes CNI (node0) ===

# Dependencies
sudo apt install python3-pip -y
pip3 install --user jinjanator matplotlib
export PATH="$HOME/.local/bin:$PATH"

# [BASE only] install Go for on-node compilation
if [[ $VARIANT == "base" ]]; then
  curl -LO https://go.dev/dl/go1.21.7.linux-amd64.tar.gz
  sudo tar -C /usr/local -xzf go1.21.7.linux-amd64.tar.gz
  export PATH=$PATH:/usr/local/go/bin
fi

# Clone and patch
cd ~
git clone https://github.com/Anirudh-R-1201/ovn-kubernetes.git
cd ovn-kubernetes
[[ $VARIANT == "topo" ]] && git checkout topo-aware
sed -i 's/ apply -f/ apply --validate=false -f/g' dist/images/ovnkube.sh
sed -i 's/ create -f/ create --validate=false -f/g' dist/images/ovnkube.sh
sed -i 's/ patch / patch --validate=false /g' dist/images/ovnkube.sh

# Build / obtain image
if [[ $VARIANT == "base" ]]; then
  cd dist/images && make ubuntu-image
  docker tag ovn-kube-ubuntu:latest ovn-kube:latest
  docker save ovn-kube:latest -o ~/ovn-kube.tar
  cd ~
  TAR=ovn-kube.tar; IMAGE=ovn-kube:latest
else
  # [TOPO] ovn-kube-topo.tar must already be scp'd to ~/
  TAR=ovn-kube-topo.tar; IMAGE=ovn-kube-topo:latest
fi

# Distribute image to all nodes
for n in $WORKERS; do scp ~/$TAR ${n}:~/; done
for n in node0 $WORKERS; do ssh ${n} "sudo ctr -n k8s.io image import ~/$TAR" & done
wait

# Prepare OVN directories
sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data
for n in $WORKERS; do
  ssh ${n} "sudo mkdir -p /var/lib/ovn/etc /var/lib/ovn/data"
done

# Generate manifests
cd ~/ovn-kubernetes/dist/images
if [[ $VARIANT == "base" ]]; then
  ./daemonset.sh --image=$IMAGE --net-cidr=10.128.0.0/14 --svc-cidr=172.30.0.0/16
else
  OVN_ENABLE_TOPOLOGY_AWARE_LB=true ./daemonset.sh \
    --image=$IMAGE --net-cidr=10.128.0.0/14 --svc-cidr=172.30.0.0/16 \
    --enable-topology-aware-lb=true
  grep "TOPOLOGY_AWARE" ../yaml/ovnkube-master.yaml  # verify: value: "true"
fi

# Deploy
cd ~/ovn-kubernetes
kubectl apply -f dist/yaml/ovn-setup.yaml
CORRECT_API_SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
kubectl patch configmap ovn-config -n ovn-kubernetes --type merge \
  -p "{\"data\":{\"k8s_apiserver\":\"${CORRECT_API_SERVER}\"}}"
kubectl apply -f dist/yaml/rbac-ovnkube-db.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-master.yaml
kubectl apply -f dist/yaml/rbac-ovnkube-node.yaml
kubectl apply -f dist/yaml/ovs-node.yaml
sleep 30
kubectl apply -f dist/yaml/ovnkube-db.yaml
sleep 60
kubectl apply -f dist/yaml/ovnkube-master.yaml
kubectl apply -f dist/yaml/ovnkube-node.yaml
sleep 10
kubectl get csr -o name | xargs kubectl certificate approve

# Restart workers
for n in $WORKERS; do
  ssh ${n} "sudo chmod 644 /etc/cni/net.d/10-ovn-kubernetes.conf 2>/dev/null; \
            sudo systemctl restart containerd && sleep 10 && \
            sudo systemctl restart kubelet" &
done
wait
sleep 30
kubectl get nodes && kubectl get pods -n ovn-kubernetes -o wide

# [TOPO only] label nodes and annotate services (after Online Boutique is deployed)
if [[ $VARIANT == "topo" ]]; then
  # Adjust zone groupings based on measured ping RTT between nodes
  ZONE=(zone-a zone-a zone-b zone-b zone-c)
  i=0; for n in $WORKERS; do
    kubectl label node ${n}.<exp>.utah.cloudlab.us topology.kubernetes.io/zone=${ZONE[$i]} --overwrite
    ((i++))
  done

  for svc in frontend productcatalogservice cartservice checkoutservice \
             currencyservice recommendationservice paymentservice \
             shippingservice emailservice adservice; do
    kubectl annotate service $svc service.kubernetes.io/topology-mode=Auto --overwrite
  done
fi
```

---

## References

- [OVN-Kubernetes Documentation](https://github.com/ovn-org/ovn-kubernetes)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [kubeadm Setup](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
