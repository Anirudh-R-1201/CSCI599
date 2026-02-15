Stage 1: Baseline Testing
==========================

Capture baseline latency and pod placement metrics using OVN-Kubernetes on CloudLab.

Prerequisites
-------------
- Kubernetes cluster with OVN-Kubernetes deployed (see main README)
- All nodes in Ready state with DNS configured
- Python3, jq, and matplotlib installed on node0
- For autoscaling tests: metrics-server deployed

Running Tests
-------------

### Quick Start: Complete Autoscaling Test

```bash
cd ~/CSCI599/stage1-baseline

# Run complete workflow (setup, test, collect, analyze)
./run-autoscaling-test.sh
```

This automated script will:
1. Verify prerequisites and install metrics-server if needed
2. Deploy Online Boutique workload
3. Configure HorizontalPodAutoscalers (25% CPU threshold)
4. Run high-intensity load test (50 bursts, ~60-90 minutes)
5. Collect all baseline metrics
6. Generate visualization graphs

### Manual Step-by-Step

### 1. Deploy Workload

```bash
cd ~/CSCI599/stage1-baseline

kubectl apply -f online-boutique.yaml
kubectl wait --for=condition=Available deployment --all -n default --timeout=600s
kubectl get pods -o wide
```

### 2. Run Load Test with Pod Placement Monitoring

**Option A: Basic Load Test (no autoscaling)**
```bash
export RUN_ID=$(date +"%Y%m%d-%H%M%S")

# Start pod placement monitoring (5s intervals, ~42min max)
INTERVAL_SEC=5 COUNT=500 ./05-snapshot-pod-placement.sh > /tmp/placement.log 2>&1 &
PLACEMENT_PID=$!

# Run load generation (30 bursts, ~15-30 minutes)
BURSTS=30 BASE_QPS=5 MAX_QPS=80 BASE_DURATION=10 MAX_DURATION=40 ./03-generate-self-similar-load.sh

# Stop placement monitoring
kill $PLACEMENT_PID
```

**Option B: High-Intensity Load Test (with autoscaling)**
```bash
# Install metrics-server (required for HPA)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# Wait for metrics-server to be ready
kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s

# Setup HPA with lower threshold for better backend scaling (15% CPU threshold)
CPU_THRESHOLD=25 ./07-setup-hpa.sh

# Run high-intensity load test
export RUN_ID=$(date +"%Y%m%d-%H%M%S")

INTERVAL_SEC=5 COUNT=1000 ./05-snapshot-pod-placement.sh > /tmp/placement.log 2>&1 &
PLACEMENT_PID=$!

# Choose one of these load patterns:

# Pattern 1: Single endpoint, high load
BURSTS=50 BASE_QPS=20 MAX_QPS=300 BASE_DURATION=30 MAX_DURATION=120 THREADS=32 ./03-generate-self-similar-load.sh

# Pattern 2: Multi-endpoint, rotating (better backend coverage)
BURSTS=40 BASE_QPS=30 MAX_QPS=200 BASE_DURATION=60 MAX_DURATION=120 THREADS=24 ./03b-multiservice-load.sh

# Pattern 3: Concurrent multi-endpoint (BEST for backend scaling)
DURATION=600 QPS_HOME=100 QPS_PRODUCT=80 QPS_CART=60 THREADS_PER_ENDPOINT=24 ./03c-concurrent-multiservice-load.sh

kill $PLACEMENT_PID

# Monitor HPA during test (in another terminal)
kubectl get hpa -w
```

### 3. Collect Baseline Metrics

```bash
./04-collect-baseline.sh
```

### 4. Generate Graphs and Analysis

```bash
# Install matplotlib if needed
pip3 install matplotlib

# Generate load test visualization graphs (uses latest run by default)
./06-generate-graphs.sh

# Or specify a specific run
./06-generate-graphs.sh data/20260214-191727

# Analyze detailed network data (if using 03d script)
./07-analyze-network-data.py

# Or specify run
./07-analyze-network-data.py data/20260214-191727
```

Load Test Scripts
-----------------

**Three load generation strategies:**

| Script | Best For | Backend Scaling | Complexity |
|--------|----------|-----------------|------------|
| `03-generate-self-similar-load.sh` | Baseline tests, frontend-focused | Minimal | Simple |
| `03b-multiservice-load.sh` | Varied traffic patterns, sequential | Moderate | Medium |
| `03c-concurrent-multiservice-load.sh` | **Maximum backend scaling** | **Excellent** | Simple |

**Recommendation:** Use `03c-concurrent-multiservice-load.sh` for autoscaling tests.

Load Test Parameters
--------------------

**Single Endpoint Load (03-generate-self-similar-load.sh):**

| Variable | Default | Description |
|----------|---------|-------------|
| `BURSTS` | 30 | Number of traffic bursts |
| `BASE_QPS` | 5 | Minimum queries per second |
| `MAX_QPS` | 80 | Maximum queries per second |
| `BASE_DURATION` | 10 | Minimum burst duration (seconds) |
| `MAX_DURATION` | 40 | Maximum burst duration (seconds) |
| `THREADS` | 4 | Concurrent connections (higher = more load) |

**Multi-Service Load (03b-multiservice-load.sh):**

| Variable | Default | Description |
|----------|---------|-------------|
| `BURSTS` | 30 | Number of bursts (rotates endpoints) |
| `BASE_QPS` | 10 | Minimum queries per second |
| `MAX_QPS` | 150 | Maximum queries per second |
| `THREADS` | 16 | Concurrent connections per endpoint |

**Concurrent Load (03c-concurrent-multiservice-load.sh):**

| Variable | Default | Description |
|----------|---------|-------------|
| `DURATION` | 300 | Total test duration (seconds) |
| `QPS_HOME` | 100 | QPS for home endpoint |
| `QPS_PRODUCT` | 80 | QPS for product endpoint |
| `QPS_CART` | 60 | QPS for cart endpoint |
| `THREADS_PER_ENDPOINT` | 24 | Threads per endpoint (72 total) |

**HPA Configuration:**

| Variable | Default | Description |
|----------|---------|-------------|
| `CPU_THRESHOLD` | 25 | HPA CPU % threshold for scaling |
| `MIN_REPLICAS` | 1 | Minimum replicas per service |
| `MAX_REPLICAS` | 8 | Maximum replicas per service |

**Example Configurations:**

```bash
# Light load (no scaling expected)
BURSTS=20 BASE_QPS=5 MAX_QPS=50 THREADS=4 ./03-generate-self-similar-load.sh

# Medium load (some scaling)
BURSTS=30 BASE_QPS=10 MAX_QPS=150 THREADS=16 ./03-generate-self-similar-load.sh

# Heavy load (significant scaling)
BURSTS=50 BASE_QPS=20 MAX_QPS=300 THREADS=32 ./03-generate-self-similar-load.sh
```

**Multi-Service Load Scripts (Better Backend Scaling):**

To force backend services to scale, use scripts that exercise different services more directly:

```bash
# Option A: Sequential bursts across different endpoints
# Rotates between home, product, cart endpoints to exercise different backends
BURSTS=40 BASE_QPS=30 MAX_QPS=200 THREADS=24 ./03b-multiservice-load.sh

# Option B: Concurrent load on multiple endpoints (MAXIMUM BACKEND STRESS)
# Runs 3 load generators in parallel targeting different endpoints
# Total QPS: 240, Total threads: 72
DURATION=600 QPS_HOME=100 QPS_PRODUCT=80 QPS_CART=60 THREADS_PER_ENDPOINT=24 ./03c-concurrent-multiservice-load.sh

# Option C: Detailed network analysis (COMPREHENSIVE)
# Concurrent load + detailed pod-to-pod latency + network stats
# Samples every 10s: pod locations, service endpoints, pod-to-pod latencies
DURATION=600 SAMPLE_INTERVAL=10 ./03d-detailed-network-analysis.sh
```

**Endpoint Mapping (what each endpoint exercises):**
- **Home** (`/`): productcatalog, recommendation, ad, cart
- **Product** (`/product/<id>`): productcatalog, recommendation, currency (heavy)
- **Cart** (`/cart`): cart, currency (heavy)

**Network Analysis Features (03d):**
- Pod-to-pod latency measurements (curl time between pods)
- Pod placement tracking (which pods on which nodes)
- Service endpoint distribution over time
- Node network information and capacity
- OVN-Kubernetes CNI metrics (if available)
- Service mesh topology

**Quick Commands:**

**Maximum Backend Scaling:**
```bash
kubectl delete hpa --all
CPU_THRESHOLD=15 ./07-setup-hpa.sh

export RUN_ID=$(date +"%Y%m%d-%H%M%S")
INTERVAL_SEC=5 COUNT=200 ./05-snapshot-pod-placement.sh > /tmp/placement.log 2>&1 &
PLACEMENT_PID=$!

DURATION=600 QPS_HOME=100 QPS_PRODUCT=80 QPS_CART=60 THREADS_PER_ENDPOINT=24 ./03c-concurrent-multiservice-load.sh

kill $PLACEMENT_PID
./04-collect-baseline.sh
./06-generate-graphs.sh
```

**Comprehensive Network Analysis:**
```bash
kubectl delete hpa --all
CPU_THRESHOLD=15 ./07-setup-hpa.sh

# Run detailed network analysis (includes load test + monitoring)
DURATION=600 SAMPLE_INTERVAL=10 QPS_HOME=100 QPS_PRODUCT=80 QPS_CART=60 THREADS_PER_ENDPOINT=24 ./03d-detailed-network-analysis.sh

# Analyze results
./06-generate-graphs.sh
./07-analyze-network-data.py

# View network analysis reports
LATEST=$(ls -t data/ | head -1)
cat data/$LATEST/network-analysis/analysis-summary.txt
cat data/$LATEST/network-analysis/pod-placement-analysis.txt
cat data/$LATEST/network-analysis/pod-latency-analysis.txt
```

Results
-------
All data saved to `stage1-baseline/data/<YYYYMMDD-HHMMSS>/`:

```
data/<timestamp>/
├── loadgen/
│   ├── bursts.jsonl              # Load schedule
│   └── fortio-burst-*.json       # Latency data (p50, p95, p99, p99.9)
├── pod-placement/
│   ├── index.jsonl               # Snapshot timestamps
│   └── pods-*.json               # Pod distribution over time
├── network-analysis/            # (if using 03d script)
│   ├── pod-network-*.json        # Pod locations and IPs per sample
│   ├── service-endpoints-*.json  # Service endpoint mappings
│   ├── pod-latency-*.txt         # Pod-to-pod latency measurements
│   ├── node-network-*.json       # Node network info and capacity
│   ├── service-metrics-*.json    # Service definitions and ClusterIPs
│   ├── monitoring.log            # Monitoring process log
│   ├── analysis-summary.txt      # Quick analysis summary
│   ├── pod-placement-analysis.txt       # Detailed pod placement report
│   ├── pod-latency-analysis.txt         # Latency analysis report
│   ├── service-topology-analysis.txt    # Service topology report
│   └── pod-distribution-timeline.png    # Pod distribution graph
├── baseline/
│   ├── latency-summary.json      # Aggregated latencies
│   ├── service-graph.json        # Service topology
│   ├── pods.txt                  # Pod placement
│   └── nodes.json                # Cluster configuration
└── graphs/
    ├── latency_percentiles.png   # p50/p95/p99/p99.9 over time
    ├── qps_comparison.png        # Requested vs actual QPS
    ├── latency_vs_qps.png        # Latency correlation with QPS
    ├── latency_distribution.png  # Box plot of latency distribution
    ├── pod_distribution.png      # Pod placement over time
    └── summary_stats.txt         # Summary statistics
```

Quick Analysis
--------------

### View Graphs

```bash
cd ~/CSCI599/stage1-baseline
LATEST=$(ls -t data/ | head -1)

# Open graphs directory
open data/$LATEST/graphs/

# View summary statistics
cat data/$LATEST/graphs/summary_stats.txt
```

### Check Autoscaling Results

```bash
# View HPA status
kubectl get hpa

# Check final replica counts
kubectl get deployments -o wide | grep -E 'frontend|productcatalog|recommendation|checkout|cart'

# View scaling events
kubectl get events --sort-by='.lastTimestamp' | grep -i "scaled"
```

### Manual Data Analysis

```bash
# View latency summary
cat data/$LATEST/baseline/latency-summary.json | jq '.bursts[] | {burst: .file, p50: .p50_s, p95: .p95_s, p99: .p99_s}'

# View pod distribution over time (should show variance with autoscaling)
for i in {1..20}; do
  echo -n "Snapshot $i: "
  cat data/$LATEST/pod-placement/pods-$i.json | jq -r '.items[] | select(.metadata.namespace=="default") | .spec.nodeName' | sort | uniq -c
done

# Average p95 latency
cat data/$LATEST/baseline/latency-summary.json | jq '[.bursts[].p95_s] | add/length'

# Count unique pod counts per service (shows scaling activity)
cat data/$LATEST/pod-placement/index.jsonl | while read line; do
  file=$(echo $line | jq -r '.file')
  cat data/$LATEST/pod-placement/$file | jq -r '.items[] | select(.metadata.namespace=="default") | select(.metadata.labels.app=="frontend") | .metadata.name' | wc -l
done | sort -u
```
