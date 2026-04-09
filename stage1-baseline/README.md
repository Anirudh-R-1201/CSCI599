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

### Pre-flight cleanup (run once before any experiment)

```bash
# Remove stale pods and HPAs
kubectl delete pod --field-selector=status.phase=Failed -n default
kubectl delete hpa --all

# Scale everything to 1 so the experiment's HPA setup starts from a clean slate
kubectl scale deployment productcatalogservice recommendationservice \
  checkoutservice cartservice --replicas=1
kubectl scale deployment frontend currencyservice --replicas=3
kubectl wait --for=condition=available \
  deployment/frontend deployment/productcatalogservice \
  deployment/recommendationservice deployment/checkoutservice deployment/cartservice \
  --timeout=60s
```
```bash
# Step 2: Run experiment
## Fixed replicas 
REPLICA_MODE=fixed MIN_REPLICAS=4 MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh
```

```bash

# Scale replicas
# Re-apply topology-mode annotation so ovnkube-master creates per-node LBs
for svc in frontend productcatalogservice cartservice checkoutservice \
           currencyservice recommendationservice paymentservice \
           shippingservice emailservice adservice; do
  kubectl annotate svc ${svc} service.kubernetes.io/topology-mode=Auto --overwrite
done
sleep 15  # wait for ovnkube-master reconciliation

# Verify topo-aware per-node LBs exist (should print 5 per topology-annotated service)
DB_POD=$(kubectl get pod -n ovn-kubernetes -l name=ovnkube-db -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ovn-kubernetes "$DB_POD" -- \
  ovn-nbctl --columns=name find load_balancer 2>/dev/null \
  | grep "^name" | grep "node_switch" | grep -v "template\|merged" | wc -l
# Expected: ≥ 25 (5 per-node LBs × ≥5 topology-annotated services)

# Verify backend-set diversity for frontend (proves zone-local routing is active):
# Different nodes should map the frontend ClusterIP to DIFFERENT backend pod IPs.
# All-same IPs = topo-aware not working; different IPs per LB = working correctly.
kubectl exec -n ovn-kubernetes "$DB_POD" -- ovn-nbctl lb-list 2>/dev/null \
  | awk -v clusterip="$(kubectl get svc frontend -o jsonpath='{.spec.clusterIP}')" \
    '$4==clusterip":80" {print NF, $0}' \
  | sort | uniq -c
# Expected: multiple lines with DIFFERENT backend IP sets (node-local or zone-local per node)

REPLICA_MODE=scale MIN_REPLICAS=1 MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh
# Approve CSRs in background (required on CloudLab)
while true; do sleep 2 && kubectl get csr -o name | xargs kubectl certificate approve 2>/dev/null; done
```

## Baseline vs Topo-Aware Comparison Runs

`REPLICA_MODE=fixed` (default) pins replicas at min=max=4, eliminating HPA cold-start noise so
the only difference between BASE and TOPO runs is the LB routing policy. `BURST_SEED=42`
(default) guarantees both runs see the exact same burst plan.



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

# Re-apply topology-mode annotation so ovnkube-master creates per-node LBs
for svc in frontend productcatalogservice cartservice checkoutservice \
           currencyservice recommendationservice paymentservice \
           shippingservice emailservice adservice; do
  kubectl annotate svc ${svc} service.kubernetes.io/topology-mode=Auto --overwrite
done
sleep 15  # wait for ovnkube-master reconciliation

# Verify topo-aware per-node LBs exist (should print 5 per topology-annotated service)
DB_POD=$(kubectl get pod -n ovn-kubernetes -l name=ovnkube-db -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ovn-kubernetes "$DB_POD" -- \
  ovn-nbctl --columns=name find load_balancer 2>/dev/null \
  | grep "^name" | grep "node_switch" | grep -v "template\|merged" | wc -l
# Expected: ≥ 25 (5 per-node LBs × ≥5 topology-annotated services)

# Verify backend-set diversity for frontend (proves zone-local routing is active):
# Different nodes should map the frontend ClusterIP to DIFFERENT backend pod IPs.
# All-same IPs = topo-aware not working; different IPs per LB = working correctly.
kubectl exec -n ovn-kubernetes "$DB_POD" -- ovn-nbctl lb-list 2>/dev/null \
  | awk -v clusterip="$(kubectl get svc frontend -o jsonpath='{.spec.clusterIP}')" \
    '$4==clusterip":80" {print NF, $0}' \
  | sort | uniq -c
# Expected: multiple lines with DIFFERENT backend IP sets (node-local or zone-local per node)
# node0 (no zone label) → cluster-wide (all 6 IPs)
# node1–5 → 1–2 IPs each (node-local tier, since every worker has ≥1 frontend pod)

kubectl delete pod k6-loadgen --ignore-not-found
kubectl apply -f k6-loadgen.yaml
kubectl wait --for=condition=Ready pod/k6-loadgen --timeout=60s

# Run — same REPLICA_MODE and BURST_SEED as baseline for apples-to-apples comparison
REPLICA_MODE=fixed MIN_REPLICAS=4 BURST_SEED=42 MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh
# Note the RUN_ID printed — this is your topo-aware run
```

> **Note on `selection_fields`:** All LBs correctly show `selection_fields: []` in both BASE and TOPO
> mode. Topology enforcement is in the **per-node backend list** (different pod IPs per node), not
> in the hash function. Do not use `selection_fields` as a health check for topo-aware routing.

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

### Replica modes (`REPLICA_MODE` + `MIN_REPLICAS`)

`REPLICA_MODE` controls whether replicas are pinned or autoscaled.
`MIN_REPLICAS` sets the count (in `fixed` mode) or floor (in `scale` mode). Frontend always gets `MIN_REPLICAS + 2`.

| `REPLICA_MODE` | `MIN_REPLICAS` | Backend min/max | Frontend min/max | Use when |
|---|---|---|---|---|
| `fixed` (default) | `4` (default) | 4 / 4 | 6 / 6 | Standard BASE vs TOPO comparison |
| `fixed` | `2` | 2 / 2 | 4 / 4 | Lighter run — less resource pressure, faster pod startup |
| `scale` | `1` (default) | 1 / 4 | 3 / 6 | HPA autoscaling experiment — measures cold-start behaviour |
| `scale` | `2` | 2 / 4 | 4 / 6 | Autoscaling from a warm floor — avoids cold-start saturation |

In `fixed` mode `MAX_REPLICAS` is always forced equal to `MIN_REPLICAS`, so HPA cannot scale up or down regardless of CPU load.

```bash
# Standard fixed comparison (4 replicas each service)
REPLICA_MODE=fixed MIN_REPLICAS=4 MODE=full ./01-run-experiment.sh

# Lighter fixed run (2 replicas — useful for memory-constrained clusters)
REPLICA_MODE=fixed MIN_REPLICAS=2 MODE=full ./01-run-experiment.sh

# HPA autoscaling from cold (1 → 4)
REPLICA_MODE=scale MIN_REPLICAS=1 MODE=full ./01-run-experiment.sh

# HPA autoscaling from warm floor (2 → 4)
REPLICA_MODE=scale MIN_REPLICAS=2 MODE=full ./01-run-experiment.sh
```

### All key variables

| Variable | Default | Effect |
|---|---|---|
| `REPLICA_MODE` | `fixed` | `fixed` = pin replicas (no scaling); `scale` = HPA autoscales min→max |
| `MIN_REPLICAS` | `4` | Fixed replica count (`fixed` mode) or HPA floor (`scale` mode); frontend gets +2 |
| `MAX_REPLICAS` | `4` | HPA ceiling in `scale` mode; ignored in `fixed` mode (forced = `MIN_REPLICAS`) |
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
