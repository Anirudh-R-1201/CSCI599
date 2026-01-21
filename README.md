

# Custom OVN-Kubernetes (`nw-affinity`) Setup on CloudLab

This document explains how to **provision a Kubernetes cluster on CloudLab**, **build and deploy a custom OVN-Kubernetes CNI** (from the `nw-affinity` branch), and **test your changes** — using the shell scripts in the `CSCI599` repository.

---

## Repository Contents

This repository contains:

CSCI599/
├── all.sh            # Install common dependencies & prepare nodes
├── node0.sh          # Control plane / kubeadm init
├── worker.sh         # Worker node join script
├── README.md         # This document

---

## Prerequisites

- CloudLab experiment with **3 Ubuntu 22.04 nodes**
  - `node0` — control plane
  - `node1`, `node2` — worker nodes
- SSH access to nodes (`anirudh1@...`)
- GitHub access to your fork (`Anirudh-R-1201/ovn-kubernetes`)
- Internet access on all nodes

---

## 1. Prepare Nodes (All Nodes)

SSH into each node and run:

```bash
chmod +x all.sh
./all.sh

This installs:
	•	Docker
	•	Kubernetes packages (kubelet, kubeadm, kubectl)
	•	Required kernel settings
	•	Disables swap
	•	Prepares the node for cluster setup

⸻

2. Initialize Control Plane (node0)

On node0, initialize the Kubernetes control plane:

chmod +x node0.sh
./node0.sh

This script runs kubeadm init, configures kubectl, and prints a join command.

Save the printed join command — you’ll use it next.

⸻

3. Join Worker Nodes (node1 & node2)

Copy the kubeadm join ... command from node0 to both node1 and node2, then run:

chmod +x worker.sh
./worker.sh <MASTER_IP>

Replace <MASTER_IP> with the IP you used during kubeadm init.

Verify from node0:

kubectl get nodes

Nodes may show NotReady at this point — this is expected until the CNI is deployed.

⸻

4. Clone Custom OVN-Kubernetes Fork

On node0:

git clone https://github.com/Anirudh-R-1201/ovn-kubernetes.git
cd ovn-kubernetes
git checkout nw-affinity


⸻

5. Install Go (if not already installed)

OVN-Kubernetes builds Go binaries as part of the image build. On node0:

GO_VERSION=1.21.7
curl -LO https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz
sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-arm64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
source ~/.profile

Verify:

go version


⸻

6. Build OVN-Kubernetes Images

From your branch:

cd ovn-kubernetes/dist/images
make ubuntu-image

Retag the image for deployment:

docker tag ovn-kube-ubuntu:latest ovn-kube:latest
docker images | grep ovn


⸻

7. Distribute Images to Workers

On node0:

docker save ovn-kube:latest | gzip > ovn-kube.tar.gz
scp ovn-kube.tar.gz node1:
scp ovn-kube.tar.gz node2:

On node1 and node2:

gunzip -c ovn-kube.tar.gz | docker load

Verify images on workers:

docker images | grep ovn


⸻

8. Generate OVN CNI Manifest

On node0:

cd ~/ovn-kubernetes
./dist/images/daemonset.sh \
  --image=ovn-kube:latest \
  --net-cidr=10.128.0.0/14 \
  --svc-cidr=172.30.0.0/16 \
  > ovn-kubernetes.yaml

This produces the manifest used to deploy the custom CNI.

⸻

9. Deploy the CNI

Apply the manifest:

kubectl apply -f ovn-kubernetes.yaml

Watch the OVN pods:

kubectl get pods -n ovn-kubernetes -w

After the pods are running, check nodes:

kubectl get nodes

All nodes should transition to Ready.

⸻

10. Sanity Testing

Deploy a simple test workload:

kubectl run pod1 --image=busybox -- sleep 3600
kubectl run pod2 --image=busybox -- sleep 3600
kubectl exec pod1 -- ping -c 3 pod2

This verifies basic pod-to-pod networking.

⸻

11. Validate Custom Logic

Once the CNI is running:
	•	Inspect logs to confirm custom behavior:

kubectl logs -n ovn-kubernetes -l app=ovnkube-node


	•	Deploy workloads with pod affinity/anti-affinity and observe.

⸻

Notes & Troubleshooting
	•	Do not interrupt kubeadm join; allow it to complete.
	•	If nodes remain NotReady after CNI deployment, check OVN pods:

kubectl get pods -n ovn-kubernetes
kubectl describe pod <name> -n ovn-kubernetes


	•	Ensure Go is installed and available in $PATH before building images.

⸻

References
	•	CloudLab user manual for experiment setup
	•	OVN-Kubernetes official documentation

---

If you want, I can also generate a **printable PDF** version of this README, or convert it into a **slide deck** for a project presentation.