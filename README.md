

```
# Kubernetes + OVN-Kubernetes Setup on CloudLab

This document describes how to provision a multi-node Kubernetes cluster
on CloudLab and deploy a custom OVN-Kubernetes CNI (from the `nw-affinity`
branch). 

**Automated Steps:** Kubernetes cluster setup and OVN-Kubernetes CNI deployment (scripts provided)
**Manual Steps:** None - all steps are automated

---

## Repository Contents
```

CSCI599/

├── [all.sh](http://all.sh)      # AUTOMATED: Common setup (containerd, Docker, Kubernetes v1.29, networking)

├── [node0.sh](http://node0.sh)    # AUTOMATED: Control-plane initialization with kubeadm

├── [worker.sh](http://worker.sh)   # AUTOMATED: Worker node join script

├── [README.md](http://README.md)   # This document

```

## What's Automated vs Manual

**✅ AUTOMATED (Use provided scripts):**
- Base system setup and dependencies (containerd, Docker, Kubernetes)
- Kernel and network configuration
- Kubernetes v1.29 cluster initialization  
- Worker node joining
- Custom OVN-Kubernetes CNI build and deployment (from git@github.com:Anirudh-R-1201/ovn-kubernetes.git)
- Go installation
- Image building and distribution to all nodes
- CNI manifest generation and deployment

---

## Prerequisites

- A CloudLab experiment with **3 Ubuntu 22.04 nodes**
  - `node0`: control plane
  - `node1`, `node2`: worker nodes
- SSH access to all nodes
- Internet connectivity on all nodes
- Git access to:
  - `Anirudh-R-1201/ovn-kubernetes`

---

## 1. ✅ AUTOMATED - Common Setup (ALL Nodes)

On **node0, node1, and node2**, run:

```bash
chmod +x all.sh
./all.sh
```

This script:
- Installs and configures **containerd** (CRI for Kubernetes ≥1.24)  
- Installs Docker (used for building OVN images)
- Installs Kubernetes v1.29 (kubelet, kubeadm, kubectl)
- Configures kubelet to use containerd runtime
- Applies required kernel and sysctl settings (persistent across reboots)
- Disables swap (persistent across reboots)
- Enables and starts kubelet service





---





## 2. ✅ AUTOMATED - Initialize Control Plane (node0)





On **node0**:

```
chmod +x node0.sh
./node0.sh
```

This script:



- Runs kubeadm init
- Configures kubectl using admin.conf
- Generates a worker join command in [join.sh](http://join.sh)





> **Important:**

> Always use the exact IP shown in [join.sh](http://join.sh) when joining workers.

> This IP is embedded in the API server certificate.



---





## 3. ✅ AUTOMATED - Join Worker Nodes (node1 & node2)





Copy the join command from node0/[join.sh](http://join.sh).



On **each worker node**:

```
chmod +x worker.sh
./worker.sh "<kubeadm join ...>"
```

Example:

```
./worker.sh "kubeadm join 128.110.x.x:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>"
```

Verify **from node0 only**:

```
kubectl get nodes
```

Expected output (before CNI installation):

```
node0   NotReady   control-plane
node1   NotReady
node2   NotReady
```

This is expected until a CNI is installed.



---





## 4. ✅ AUTOMATED - Install OVN-Kubernetes CNI (node0)

This single script automates all the following steps:
- Cloning the custom OVN-Kubernetes repository from git@github.com:Anirudh-R-1201/ovn-kubernetes.git
- Installing Go (if not present)
- Building the OVN-Kubernetes Ubuntu image
- Distributing the image to all worker nodes
- Generating the CNI manifest with correct CIDRs
- Deploying OVN-Kubernetes to the cluster

On **node0**:

```bash
chmod +x install-ovn-cni.sh
./install-ovn-cni.sh
```

**What this script does:**

1. Clones/updates the OVN-Kubernetes repository (nw-affinity branch)
2. Installs Go 1.21.7 if not already present
3. Builds the ovn-kube-ubuntu image (~10-15 minutes)
4. Tags the image as ovn-kube:latest
5. Distributes the image to all worker nodes via scp
6. Generates the CNI manifest with pod CIDR (10.128.0.0/14) and service CIDR (172.30.0.0/16)
7. Deploys OVN-Kubernetes to the cluster
8. Waits for pods to be ready and verifies node status

**Expected output:**

After completion, all nodes should show `Ready` status:

```
NAME     STATUS   ROLES           AGE   VERSION
node0    Ready    control-plane   ...   v1.29.15
node1    Ready    <none>          ...   v1.29.15
node2    Ready    <none>          ...   v1.29.15
```

And OVN-Kubernetes pods should be running:

```
kubectl get pods -n ovn-kubernetes
```

**Troubleshooting:**

If image distribution fails, you can manually copy the image to workers:

```bash
# On node0
docker save ovn-kube:latest | gzip > ovn-kube.tar.gz
scp ovn-kube.tar.gz node1:~/
scp ovn-kube.tar.gz node2:~/

# On each worker
gunzip -c ~/ovn-kube.tar.gz | docker load
```

**Customization:**

You can customize the installation by setting environment variables:

```bash
# Use a different branch
OVN_BRANCH=main ./install-ovn-cni.sh

# Or edit the script to change Pod/Service CIDRs
```



---





## **Notes**





**Script Improvements:**
- Persistent sysctl and kernel module settings survive reboots
- Swap disable is persistent across reboots  
- kubelet service properly started after installation
- All networking settings configured for production use

**Usage:**
- kubectl is intended to be used **only on node0**
- Worker nodes do not have admin kubeconfig by default
- Do not interrupt kubeadm join operations
- containerd is required for Kubernetes v1.29
- Always use the same IP for kubeadm init and kubeadm join





---



