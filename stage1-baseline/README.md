Stage 1: Baseline (OVN-Kubernetes on CloudLab)
===============================================

Goal
----
Establish a reproducible baseline for pod placement, inter-service communication, 
and latency using OVN-Kubernetes CNI on a CloudLab bare-metal cluster. This stage 
uses the baseline CNI configuration without network-aware scheduling or custom 
modifications.

Environment
-----------
- Multi-node bare-metal CloudLab cluster (Ubuntu 22.04)
- Physical node isolation (vs containerized nodes in Kind)
- Real network hardware and fabric
- OVN-Kubernetes CNI deployed from custom build
- Results reflect actual production-like latency characteristics

Prerequisites
-------------
- Working CloudLab Kubernetes cluster (see main README Part 1)
- OVN-Kubernetes CNI deployed and healthy (see main README Part 2)
- All nodes in Ready state
- DNS working on all nodes
- kubectl configured on control plane (node0)
- Python3, jq installed on node0

CloudLab-Specific Setup
-----------------------
Before running baseline tests, ensure:

1. **DNS is configured on ALL nodes:**
   ```bash
   # On each node (node0, node1, node2, ...)
   sudo bash -c 'cat > /etc/resolv.conf << EOF
   nameserver 8.8.8.8
   nameserver 8.8.4.4
   nameserver 1.1.1.1
   EOF'
   ```

2. **OVN-Kubernetes is healthy:**
   ```bash
   kubectl get pods -n ovn-kubernetes -o wide
   # All ovnkube-node pods should be 3/3 Running
   # All nodes should be Ready
   ```

3. **Container registry access works:**
   ```bash
   # Test from a worker node
   ssh node1 "curl -I https://gcr.io"
   ```

Step-by-Step: Running Baseline Tests
-------------------------------------

### 1. Deploy Online Boutique Workload

```bash
cd ~/CSCI599/stage1-baseline

# Set kubeconfig path
export KUBECONFIG_PATH=~/.kube/config
export CLUSTER_NAME="cloudlab-cluster"

# Deploy the microservices application
kubectl apply -f online-boutique.yaml

# Wait for all pods to be Running (may take 2-5 minutes)
kubectl wait --for=condition=Available deployment --all -n default --timeout=600s

# Verify deployment
kubectl get pods -o wide
```

**Expected:** 12 microservices pods running across worker nodes (node1, node2, ...)

### 2. Generate Self-Similar Load

```bash
# Run load generation (15-30 minutes)
./03-generate-self-similar-load.sh

# This will:
# - Deploy Fortio load generator pod
# - Generate 30 Pareto-distributed traffic bursts
# - Target frontend service (exercises east-west microservices traffic)
# - Store results in stage1-baseline/data/<timestamp>/loadgen/
```

**Parameters (can be customized):**
- `BURSTS=30` - Number of traffic bursts
- `BASE_QPS=5` - Minimum queries per second
- `MAX_QPS=80` - Maximum queries per second
- `BASE_DURATION=10` - Minimum burst duration (seconds)
- `MAX_DURATION=40` - Maximum burst duration (seconds)

### 3. Collect Baseline Metrics

```bash
# Collect cluster state and metrics
./04-collect-baseline.sh

# This captures:
# - Pod placement snapshots
# - Node configurations
# - Service topology graph
# - Latency percentiles (p50, p95, p99, p99.9)
# - Network endpoint mappings
```

### 4. (Optional) Continuous Placement Monitoring

```bash
# Run in background to capture placement changes over time
./05-snapshot-pod-placement.sh &
```

Artifacts
---------
All data is written to `stage1-baseline/data/<YYYYMMDD-HHMMSS>/`:

```
data/<timestamp>/
├── loadgen/
│   ├── bursts.jsonl              # Load generation schedule
│   ├── fortio-burst-*.json       # Detailed latency data per burst
│   ├── fortio-burst-*.log        # Load generator logs
│   └── ...
└── baseline/
    ├── nodes.json                # Node configurations
    ├── pods.json                 # Pod placement details
    ├── pods.txt                  # Human-readable pod list
    ├── services.yaml             # Service definitions
    ├── endpoints.yaml            # Service endpoints
    ├── deployments.yaml          # Deployment configs
    ├── service-graph.json        # Microservices topology
    ├── service-graph.csv         # Topology in CSV format
    └── latency-summary.txt       # Aggregated latency metrics
```

Troubleshooting
---------------

### Pods Stuck in ContainerCreating

**Cause:** DNS not configured on worker nodes

**Fix:**
```bash
# On each worker node
ssh node1 "sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF'"

# Restart containerd and kubelet
ssh node1 "sudo systemctl restart containerd && sleep 5 && sudo systemctl restart kubelet"
```

### Pods Stuck in ImagePullBackOff

**Cause:** Registry cannot be reached due to DNS or network issues

**Fix:**
```bash
# Test connectivity from worker
ssh node1 "nslookup gcr.io"
ssh node1 "curl -I https://gcr.io"

# If DNS fails, fix as above
```

### CNI Socket Connection Refused

**Cause:** ovnkube-node pods not healthy

**Fix:**
```bash
# Check OVN pod status
kubectl get pods -n ovn-kubernetes -o wide

# If not 3/3 Running, restart them
kubectl delete pod -n ovn-kubernetes -l app=ovnkube-node

# Wait for them to come back up
kubectl get pods -n ovn-kubernetes -w
```

### Load Generator Fails

**Cause:** Frontend service not accessible

**Fix:**
```bash
# Check if frontend pod is running
kubectl get pods -l app=frontend

# Check service
kubectl get svc frontend

# Test connectivity from load generator pod
kubectl exec -it fortio-loadgen -- curl frontend:80
```

Comparing Results
-----------------
To compare baseline with network-aware scheduling:

1. Save baseline results: `mv data/<timestamp> data/baseline-vanilla/`
2. Deploy network-aware OVN-Kubernetes
3. Re-run steps 1-3
4. Compare latency metrics in `baseline/latency-summary.txt`

Expected Metrics
----------------
On a typical 3-node CloudLab cluster with Online Boutique:

- **p50 latency:** 10-50ms
- **p95 latency:** 50-200ms
- **p99 latency:** 100-500ms
- **Pod count:** ~12 microservices + 1 load generator
- **Inter-node traffic:** Significant east-west calls between services

Notes
-----
- Results reflect bare-metal performance (more realistic than Kind)
- Network latency includes physical switch fabric
- Pod placement is controlled by default Kubernetes scheduler
- No network-aware optimizations in this baseline
- Use these metrics to measure improvements from network-aware scheduling
