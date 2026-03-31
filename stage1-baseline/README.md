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

To produce a directly comparable pair of runs (same cluster, same hardware, only the LB policy differs):

```bash
##NOTE: run the following cmd before any experiment to ensure there are no stale resources
kubectl delete pod --field-selector=status.phase=Failed -n default 
kubectl delete hpa --all
# Now scale down to 1 — will actually stick
kubectl scale deployment frontend productcatalogservice recommendationservice checkoutservice cartservice --replicas=1
# Wait for pods to terminate
kubectl wait --for=condition=available deployment/frontend deployment/productcatalogservice deployment/recommendationservice deployment/checkoutservice deployment/cartservice --timeout=60s

```
```bash
#If needed run the following on all nodes
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock rmi --prune 2>/dev/null; sudo journalctl --vacuum-size=500M; df -h /
sudo journalctl --vacuum-size=500M
sudo rm -rf /tmp/*
df -h /

```

```bash
# ── Baseline run (topo-aware OFF) ──────────────────────────────
kubectl set env deployment/ovnkube-master -n ovn-kubernetes \
  -c ovnkube-master OVN_ENABLE_TOPOLOGY_AWARE_LB=false
kubectl rollout restart deployment/ovnkube-master -n ovn-kubernetes
kubectl rollout status deployment/ovnkube-master -n ovn-kubernetes --timeout=120s

# Reset replicas for a clean ramp-up
kubectl scale deployment frontend productcatalogservice recommendationservice \
  checkoutservice cartservice --replicas=1
sleep 30

# Recreate k6 pod fresh
kubectl delete pod k6-loadgen --ignore-not-found
kubectl apply -f k6-loadgen.yaml
kubectl get pod k6-loadgen   # wait for Running

MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh
# Note the RUN_ID printed — this is your baseline


# ── Topo-aware run (topo-aware ON) ─────────────────────────────
kubectl set env deployment/ovnkube-master -n ovn-kubernetes \
  -c ovnkube-master OVN_ENABLE_TOPOLOGY_AWARE_LB=true
kubectl rollout restart deployment/ovnkube-master -n ovn-kubernetes
kubectl rollout status deployment/ovnkube-master -n ovn-kubernetes --timeout=120s


# Verify topology-aware LBs are active
DB_POD=$(kubectl get pod -n ovn-kubernetes -l name=ovnkube-db -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ovn-kubernetes $DB_POD -- \
  ovn-nbctl list load_balancer | grep "selection_fields" | sort | uniq -c
# Expected: some show [ip_dst, ip_src]  ← topology-aware
#           others show []              ← regular (kube-system services)

# Reset replicas again for fair comparison
kubectl scale deployment frontend productcatalogservice recommendationservice \
  checkoutservice cartservice --replicas=1
sleep 30

kubectl delete pod k6-loadgen --ignore-not-found
kubectl apply -f k6-loadgen.yaml
sleep 5
kubectl get pod k6-loadgen 

MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh
# Note the RUN_ID printed — this is your topo-aware run
```

**What to compare across the two runs** (replace `<BASE>` and `<TOPO>` with actual RUN_IDs):

```bash
# Graph 07/08 — cross-node traffic fraction (key metric)
# Lower bars in topo run = routing is preferring same-zone backends
open data/<BASE>/graphs/07_cross_node_ratio.png
open data/<TOPO>/graphs/07_cross_node_ratio.png

# Graph 03 — latency vs QPS (lower p95/p99 in topo run = less east-west RTT)
open data/<BASE>/graphs/03_latency_vs_qps.png
open data/<TOPO>/graphs/03_latency_vs_qps.png

# Graph 11 — queueing vs RTT (topo run should shift cluster to left = shorter RTTs)
open data/<BASE>/graphs/11_queueing_vs_rtt.png
open data/<TOPO>/graphs/11_queueing_vs_rtt.png
```

## Runner Modes

`01-run-experiment.sh` `MODE`:
- `full` – deploy + HPA + traffic + baseline collection
- `prep` – deploy + HPA only
- `traffic` – traffic + telemetry only (cluster already deployed)

Key variables:

| Variable | Default | Effect |
|---|---|---|
| `CPU_THRESHOLD` | `75` | HPA CPU target %; lower = more aggressive scaling |
| `BURSTS` | `18` | Number of load bursts |
| `BASE_BURST_SECONDS` | `45` | Min burst duration |
| `MAX_BURST_SECONDS` | `90` | Max burst duration |
| `MIN_SLEEP_SECONDS` | `45` | Min gap between bursts (HPA scale-down time) |
| `MAX_SLEEP_SECONDS` | `120` | Max gap between bursts |
| `QPS_FLOOR` | `80` | Minimum burst QPS |
| `QPS_CEIL` | `300` | Maximum burst QPS |
| `SAMPLE_INTERVAL` | `8` | Telemetry snapshot interval (seconds) |
| `W_HOME/PRODUCT/CART/CHECKOUT` | `0.30/0.35/0.20/0.15` | Endpoint weight split |

```bash
# Default run
MODE=full ./01-run-experiment.sh

# More bursts, higher load
BURSTS=24 QPS_CEIL=400 MODE=full ./01-run-experiment.sh

# If HPA doesn't scale up
CPU_THRESHOLD=50 MODE=full ./01-run-experiment.sh
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
