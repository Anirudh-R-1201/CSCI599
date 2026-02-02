

```
# Kubernetes + OVN-Kubernetes Setup on CloudLab

This document describes how to provision a multi-node Kubernetes cluster
on CloudLab and deploy a custom OVN-Kubernetes CNI (from the `nw-affinity`
branch). 

**Automated Steps:** Kubernetes cluster setup (scripts provided)
**Manual Steps:** OVN-Kubernetes CNI build and deployment (manual commands)

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

**📋 MANUAL (Follow instructions below):**
- Custom OVN-Kubernetes CNI build and deployment
- Go installation
- Image building and distribution

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





## 4. 📋 MANUAL - Clone Custom OVN-Kubernetes (node0)





On **node0**:

```
git clone https://github.com/Anirudh-R-1201/ovn-kubernetes.git
cd ovn-kubernetes
git checkout nw-affinity
```



---





## 5. 📋 MANUAL - Install Go (node0)





OVN-Kubernetes requires Go to build binaries.

```
GO_VERSION=1.21.7
curl -LO https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
source ~/.profile
```

Verify:

```
go version
```



---





## 6. 📋 MANUAL - Build OVN-Kubernetes Images (node0)



```
git clone git@github.com:Anirudh-R-1201/ovn-kubernetes.git
cd ovn-kubernetes/dist/images
make ubuntu-image
```



Retag the image:

```
docker tag ovn-kube-ubuntu:latest ovn-kube:latest
```



---





## 7. 📋 MANUAL - Distribute Images to Workers





On **node0**:

```
docker save ovn-kube:latest | gzip > ovn-kube.tar.gz
scp ovn-kube.tar.gz node1:
scp ovn-kube.tar.gz node2:
```

On **node1** and **node2**:

```
gunzip -c ovn-kube.tar.gz | docker load
```



---





## 8. 📋 MANUAL - Deploy OVN-Kubernetes CNI (node0)





Generate the CNI manifest:

```
cd ~/ovn-kubernetes
./dist/images/daemonset.sh \
  --image=ovn-kube:latest \
  --net-cidr=10.128.0.0/14 \
  --svc-cidr=172.30.0.0/16 \
  > ovn-kubernetes.yaml
```

Apply it:

```
kubectl apply -f ovn-kubernetes.yaml
```

Verify:

```
kubectl get pods -n ovn-kubernetes
kubectl get nodes
```

All nodes should transition to Ready.



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



