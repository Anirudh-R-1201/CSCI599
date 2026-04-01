# Stage 1 Baseline

## Files

| File | Role |
|---|---|
| `00-deploy-boutique.sh` | Deploy Online Boutique + probers (no traffic) |
| `01-run-experiment.sh` | Top-level experiment runner |
| `02-analyze-results.sh` | Top-level analyzer |
| `03e-bursty-highload-network-test.sh` | Load generation + telemetry collection |
| `k6-load-test.js` | k6 scenario script (stateful checkout, all endpoints) |
| `k6-loadgen.yaml` | k6 pod (HTTP load generation) |
| `fortio-loadgen.yaml` | fortio pod (gRPC health probes only) |
| `s2s-prober.yaml` | curl probe pod (HTTP s2s latency: dns/connect/ttfb) |
| `07-setup-hpa.sh` | HPA configuration |
| `07-analyze-network-data.py` | Analysis engine |
| `06-generate-graphs.py` | Graph generator |

## Quick Start

```bash
cd ~/CSCI599/stage1-baseline

# Step 1: Deploy Online Boutique (one-time, idempotent)
./00-deploy-boutique.sh

# Step 2: Run experiment
MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh

# Approve CSRs in background (required on CloudLab)
while true; do sleep 2 && kubectl get csr -o name | xargs kubectl certificate approve 2>/dev/null; done
```

## Baseline vs Topo-Aware Comparison Runs

`REPLICA_MODE=fixed` (default) pins replicas at min=max=4, eliminating HPA cold-start noise so
the only difference between BASE and TOPO runs is the LB routing policy. `BURST_SEED=42`
(default) guarantees both runs see the exact same burst plan.

### Pre-flight cleanup (run once before any experiment)

```bash
# Remove stale pods and HPAs
kubectl delete pod --field-selector=status.phase=Failed -n default
kubectl delete hpa --all

# Scale everything to 1 so the experiment's HPA setup starts from a clean slate
kubectl scale deployment frontend productcatalogservice recommendationservice \
  checkoutservice cartservice --replicas=1
kubectl wait --for=condition=available \
  deployment/frontend deployment/productcatalogservice \
  deployment/recommendationservice deployment/checkoutservice deployment/cartservice \
  --timeout=60s
```

```bash
# Free disk space on all worker nodes (run if a node is >85% full)
for node in node1 node2 node3 node4 node5; do
  ssh "$node" 'sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock rmi --prune 2>/dev/null
               sudo journalctl --vacuum-size=500M
               sudo rm -rf /tmp/*
               df -h /'
done

# Monitor pod distribution during a run
watch -n 5 'kubectl get pods -o wide --field-selector=status.phase=Running \
  | grep -v "Completed\|Terminating" | awk "{print \$7}" | sort | uniq -c | sort -rn'
```

### Baseline run (topo-aware OFF)

```bash
kubectl set env deployment/ovnkube-master -n ovn-kubernetes \
  -c ovnkube-master OVN_ENABLE_TOPOLOGY_AWARE_LB=false
kubectl rollout restart deployment/ovnkube-master -n ovn-kubernetes
kubectl rollout status deployment/ovnkube-master -n ovn-kubernetes --timeout=120s

# Recreate k6 pod fresh
kubectl delete pod k6-loadgen --ignore-not-found
kubectl apply -f k6-loadgen.yaml
kubectl wait --for=condition=Ready pod/k6-loadgen --timeout=60s

# Run — fixed replicas, seed=42 burst plan
REPLICA_MODE=fixed MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh
# Note the RUN_ID printed — this is your baseline
```

### Topo-aware run (topo-aware ON)

```bash
kubectl set env deployment/ovnkube-master -n ovn-kubernetes \
  -c ovnkube-master OVN_ENABLE_TOPOLOGY_AWARE_LB=true
kubectl rollout restart deployment/ovnkube-master -n ovn-kubernetes
kubectl rollout status deployment/ovnkube-master -n ovn-kubernetes --timeout=120s

# Verify topology-aware LBs are active
DB_POD=$(kubectl get pod -n ovn-kubernetes -l name=ovnkube-db -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ovn-kubernetes "$DB_POD" -- \
  ovn-nbctl list load_balancer | grep "selection_fields" | sort | uniq -c
# Expected: some entries show [ip_dst, ip_src]  ← topology-aware
#           others show []                       ← regular (kube-system services)

kubectl delete pod k6-loadgen --ignore-not-found
kubectl apply -f k6-loadgen.yaml
kubectl wait --for=condition=Ready pod/k6-loadgen --timeout=60s

# Run — same REPLICA_MODE and BURST_SEED as baseline for apples-to-apples comparison
REPLICA_MODE=fixed MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh
# Note the RUN_ID printed — this is your topo-aware run
```

### What to compare (replace `<BASE>` and `<TOPO>` with actual RUN_IDs)

```bash
# Graph 07/08 — cross-node traffic fraction (key metric)
# Lower bars in TOPO = routing preferring same-zone backends
open data/<BASE>/graphs/07_cross_node_ratio.png
open data/<TOPO>/graphs/07_cross_node_ratio.png

# Graph 11 — queueing vs RTT (TOPO should shift left = shorter RTTs, less queueing)
open data/<BASE>/graphs/11_queueing_vs_rtt.png
open data/<TOPO>/graphs/11_queueing_vs_rtt.png

# Graph 03 — latency vs QPS (lower p95/p99 in TOPO = less east-west overhead)
open data/<BASE>/graphs/03_latency_vs_qps.png
open data/<TOPO>/graphs/03_latency_vs_qps.png
```

## Runner Modes

`01-run-experiment.sh` `MODE`:
- `full` – deploy + HPA + traffic + baseline collection
- `prep` – deploy + HPA only
- `traffic` – traffic + telemetry only (cluster already deployed)

### Replica modes (`REPLICA_MODE`)

| Mode | Backend min/max | Frontend min/max | Use when |
|---|---|---|---|
| `fixed` (default) | 4 / 4 | 6 / 6 | BASE vs TOPO comparison — eliminates HPA cold-start noise |
| `scale` | 1 / 4 | 3 / 6 | HPA autoscaling experiments — measures scaling behaviour under load |

```bash
# Fixed replicas — recommended for BASE vs TOPO comparison
REPLICA_MODE=fixed MODE=full ./01-run-experiment.sh

# HPA autoscaling — replicas ramp from 1 up to 4
REPLICA_MODE=scale MODE=full ./01-run-experiment.sh
```

### All key variables

| Variable | Default | Effect |
|---|---|---|
| `REPLICA_MODE` | `fixed` | `fixed` = pin replicas (no scaling); `scale` = HPA autoscales |
| `BURST_SEED` | `42` | Random seed for burst plan — same seed = identical plan across runs |
| `CPU_THRESHOLD` | `75` | HPA CPU target %; lower = more aggressive scaling (only relevant for `scale` mode) |
| `BURSTS` | `18` | Number of load bursts |
| `BASE_BURST_SECONDS` | `90` | Min burst duration (seconds) |
| `MAX_BURST_SECONDS` | `180` | Max burst duration (seconds) |
| `MAX_SLEEP_SECONDS` | `5` | Max gap between bursts |
| `QPS_FLOOR` | `100` | Minimum burst QPS |
| `QPS_CEIL` | `750` | Maximum burst QPS (spike bursts approach this value) |
| `SPIKE_PROBABILITY` | `0.35` | Fraction of bursts that are high-QPS spikes |
| `SAMPLE_INTERVAL` | `8` | Telemetry snapshot interval (seconds) |
| `W_HOME/PRODUCT/CART/CHECKOUT` | `0.30/0.35/0.20/0.15` | Endpoint weight split |

```bash
# Reproduce a previous run exactly
BURST_SEED=42 REPLICA_MODE=fixed MODE=full ./01-run-experiment.sh

# Try a different (but still reproducible) load profile
BURST_SEED=99 REPLICA_MODE=fixed MODE=full ./01-run-experiment.sh

# Autoscaling experiment with heavier load
REPLICA_MODE=scale QPS_CEIL=1000 MODE=full ./01-run-experiment.sh
```

## Load Generation (k6)

Each burst runs `k6-load-test.js` on the `k6-loadgen` pod with `constant-arrival-rate`
scenarios for four endpoints:

| Endpoint | Services exercised |
|---|---|
| `GET /` | frontend → productcatalog, currency, recommendation, adservice |
| `GET /product/:id` | frontend → productcatalog, currency, recommendation |
| `GET /cart` | frontend → cartservice, currency |
| `POST /cart/checkout` | frontend → checkoutservice → **paymentservice, shippingservice, emailservice, currencyservice, cartservice, productcatalogservice** |

Checkout is a stateful 2-step VU flow (add-to-cart then checkout). Each k6 VU
maintains its own cookie jar so carts are independent — the full downstream
call chain fires on every checkout iteration.

gRPC health probes (s2s latency) continue to use `fortio-loadgen` since k6
does not support the gRPC health check protocol.

## East-West Traffic Analysis

Graphs 07 and 08 show **actual application cross-node traffic** derived from
the service call graph + Kubernetes endpoint placement snapshots, assuming
uniform K8s load balancing. This is not prober traffic — it reflects what
fraction of each RPC type (e.g. `checkoutservice → paymentservice`) must
traverse the east-west fabric given the current pod placement.

Key metrics:
- **Graph 07** – average cross-node fraction per call edge (bar chart)
- **Graph 08** – cross-node fraction timeline as HPA reshuffles pods
- **Graph 11** – server-side queueing vs network RTT (log scale Y-axis)
- **Graph 12** – connection-time CDF (bimodal: same-node vs cross-node DNS path)

## Analysis

```bash
./02-analyze-results.sh              # latest run
./02-analyze-results.sh data/<RUN_ID>  # specific run
```

Runs `07-analyze-network-data.py` then `06-generate-graphs.py`.

Primary outputs under `data/<RUN_ID>/`:

```
network-analysis/
  analysis-summary.txt              service→node placement, e2e & s2s latency, queueing
  e2e-latency-summary.json
  service-to-service-latency.jsonl  raw per-probe records (HTTP + gRPC)
  service-to-service-latency-summary.json
  latency-vs-replicas.csv           HPA replica counts + s2s p95/p99 over time
  experiment-metrics-recommendations.md
graphs/
  01–06   load, latency percentiles, HPA scaling, pod placement
  07–08   east-west cross-node fraction (call graph + endpoint placement)
  09–09b  p95 vs replica count / pod spread
  11–11b  queueing vs RTT, network RTT distribution
  12      connection-time CDF
  13      HPA scaling timeline vs p95 latency
  14      per-endpoint latency box plots
  README.txt
```

## Data Layout

```
data/<RUN_ID>/
├── loadgen/
│   ├── bursts.jsonl                 burst plan (QPS, duration, type per burst)
│   ├── k6-burst-*.json              k6 per-endpoint latency summary per burst
│   └── k6-burst-*.log               k6 stdout/stderr per burst
├── network-analysis/
│   ├── service-endpoints-*.json     kubectl get endpoints snapshots
│   ├── pod-network-*.json           kubectl get pods snapshots
│   ├── hpa-*.json                   HPA replica count snapshots
│   ├── top-pods-*.txt / top-nodes-*.txt
│   └── service-to-service-latency.jsonl
└── baseline/
    ├── pods.{txt,json}
    ├── nodes.{txt,json}
    ├── service-graph.{json,csv}     call graph edges (used for graphs 07/08)
    ├── endpoints.yaml
    ├── deployments.yaml
    └── events.txt
```
