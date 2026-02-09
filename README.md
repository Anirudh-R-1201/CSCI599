

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

├── all.sh              # AUTOMATED: Common setup (containerd, Docker, Kubernetes v1.29, networking)

├── node0.sh            # AUTOMATED: Control-plane initialization with kubeadm

├── worker.sh                     # AUTOMATED: Worker node join script

├── install-ovn-cni.sh            # Build OVN-Kubernetes image (run on node0)

├── distribute-and-deploy-cni.sh  # Distribute image & deploy CNI (if SSH configured)

├── deploy-ovn-cni.sh             # Deploy CNI only (after manual image distribution)

├── distribute-image-from-local.sh # Helper script for image distribution (run on laptop)

├── README.md                     # This document

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
- Adds current user to docker group (for permission-less Docker access)
- Installs Kubernetes v1.29 (kubelet, kubeadm, kubectl)
- Configures kubelet to use containerd runtime
- Applies required kernel and sysctl settings (persistent across reboots)
- Disables swap (persistent across reboots)
- Enables and starts kubelet service

**⚠️ IMPORTANT:** After running this script, you need to activate Docker group membership:

```bash
# Option 1: Activate docker group in current session
newgrp docker

# Option 2: Log out and log back in (more reliable)
```

If you skip this step, the CNI installation script will handle it automatically.





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
- Generates a worker join command in join.sh





> **Important:**

> Always use the exact IP shown in join.sh when joining workers.

> This IP is embedded in the API server certificate.



---





## 3. ✅ AUTOMATED - Join Worker Nodes (node1 & node2)





Copy the join command from node0/join.sh.



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





## 4. Build OVN-Kubernetes CNI (node0)

The CNI installation is split into build and deployment phases to handle CloudLab's SSH restrictions.

### Step 4a: Build the OVN Image

On **node0**:

```bash
chmod +x install-ovn-cni.sh
./install-ovn-cni.sh
```

**What this does:**
1. Checks Docker permissions and activates docker group if needed
2. Clones the OVN-Kubernetes repository (nw-affinity branch)
3. Installs Go 1.21.7 if needed
4. Installs `jinjanator` (Python templating tool for manifest generation)
5. Builds ovn-kube-ubuntu image (~10-15 minutes)
6. Saves the image as `~/ovn-kube.tar` (uncompressed for containerd)
7. Imports the image into local containerd on node0

After the build completes, you'll see instructions for distributing the image to workers.

**Note:** Kubernetes 1.29 uses **containerd** as the container runtime, not Docker. Images must be imported using `ctr` commands.

---

## 5. Distribute OVN Image to Workers

CloudLab nodes cannot SSH to each other by default. Choose one of these methods:

### Method A: Via Your Local Machine (RECOMMENDED)

This is the easiest method for CloudLab.

**On your laptop:**

```bash
chmod +x distribute-image-from-local.sh

# Edit the script to set your CloudLab hostnames
# NODE0_HOST=anirudh1@ms0835.utah.cloudlab.us
# NODE1_HOST=anirudh1@ms0844.utah.cloudlab.us

./distribute-image-from-local.sh
```

This script:
- Downloads the image from node0
- Uploads it to all worker nodes
- Imports the image into containerd on each worker (using `ctr`)

### Method B: Set Up Inter-Node SSH (Optional)

If you want nodes to communicate directly:

**From your laptop, for each worker:**

```bash
# Get node0's public key
ssh node0 cat ~/.ssh/id_ed25519.pub

# Add it to each worker's authorized_keys
ssh node1 "echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys"
ssh node2 "echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys"
```

**Then on node0:**

```bash
chmod +x distribute-and-deploy-cni.sh
./distribute-and-deploy-cni.sh
```

This script distributes the image AND deploys the CNI automatically.

---

## 6. Deploy the CNI (node0)

After distributing the image using Method A above:

**On node0:**

```bash
chmod +x deploy-ovn-cni.sh
./deploy-ovn-cni.sh
```

This script:
- Automatically installs `jinjanator` if not present (required for manifest generation)
- Ensures the PATH includes `~/.local/bin` for jinjanate command
- Verifies that workers have the image in containerd
- Generates the OVN-Kubernetes manifests using `daemonset.sh` with proper working directory
- Applies core OVN manifests (ovn-setup, ovnkube-db, ovnkube-master, ovnkube-node)
- Gracefully handles CRD validation errors (K8s version compatibility)
- Waits for pods to be ready
- Verifies node status

**What happens:**
The script will generate YAML manifests from Jinja2 templates and apply them to your cluster. If manifest generation fails, it will try an alternative approach using correct directory context.

**Verification:**

Check OVN-Kubernetes pods (should all be Running):

```bash
kubectl get pods -n ovn-kubernetes -o wide
```

Check nodes (should all be Ready):

```bash
kubectl get nodes -o wide
```

Expected output:
```
NAME     STATUS   ROLES           AGE   VERSION
node0    Ready    control-plane   ...   v1.29.15
node1    Ready    <none>          ...   v1.29.15
```

**Note:** It may take 1-2 minutes for nodes to transition from NotReady to Ready.

---

## Troubleshooting

### Nodes Still NotReady

```bash
# Check OVN pod status
kubectl get pods -n ovn-kubernetes

# View OVN logs
kubectl logs -n ovn-kubernetes -l app=ovnkube-node --tail=50

# On workers, verify image is loaded in containerd
sudo ctr -n k8s.io image ls | grep ovn-kube
```

### ImagePullBackOff Errors

Workers don't have the image **in containerd**. Kubernetes uses containerd (not Docker) as the runtime.

**Fix:**

```bash
# From your laptop
scp node0:~/ovn-kube.tar .
scp ovn-kube.tar node1:~/

# On worker node
sudo ctr -n k8s.io image import ~/ovn-kube.tar
```

**Verify:**
```bash
sudo ctr -n k8s.io image ls | grep ovn-kube
```

### CNI Not Deploying

```bash
# Check manifests directory
ls -lh ~/ovn-kubernetes/dist/yaml/

# Re-deploy
kubectl delete -f ~/ovn-kubernetes/dist/yaml/ovnkube-node.yaml  # if exists
./deploy-ovn-cni.sh
```

### CRD Validation Errors

Some CRDs may fail to apply due to Kubernetes version compatibility (e.g., `userdefinednetworks.k8s.ovn.org` with CEL validation). This is **expected** and won't affect basic CNI functionality. The core OVN manifests will still deploy successfully.

### Manifest Generation Fails (Template Not Found)

If you see errors like `jinja2.exceptions.TemplateNotFound: ../templates/ovnkube-node.yaml.j2`:

**Cause:** The jinjanate command can't find the Jinja2 template files.

**Fix:**
The `deploy-ovn-cni.sh` script now handles this automatically by:
1. Installing jinjanator if missing
2. Setting the correct PATH to include `~/.local/bin`
3. Running daemonset.sh from the correct directory

**Manual fix if needed:**
```bash
# Ensure jinjanator is installed
pip3 install --user jinjanator

# Add to PATH
export PATH="${HOME}/.local/bin:${PATH}"

# Verify installation
jinjanate --version

# Re-run deployment
./deploy-ovn-cni.sh
```

### No Manifests in dist/yaml/

If the `dist/yaml/` directory is empty after running deploy script:

**Check:**
```bash
# Verify daemonset.sh exists
ls -la ~/ovn-kubernetes/dist/images/daemonset.sh

# Check for template files
ls -la ~/ovn-kubernetes/dist/templates/

# Try running manually from correct directory
cd ~/ovn-kubernetes
./dist/images/daemonset.sh --image=ovn-kube:latest \
  --net-cidr=10.128.0.0/14 \
  --svc-cidr=172.30.0.0/16 \
  --kind=kind
```

---

## Customization

**Use different branch:**
```bash
OVN_BRANCH=master ./install-ovn-cni.sh
```

**Change Pod/Service CIDRs:**

Edit the scripts and modify:
```bash
POD_CIDR="10.128.0.0/14"
SVC_CIDR="172.30.0.0/16"
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



