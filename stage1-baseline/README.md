# Stage 1 Baseline

## Files

| File | Role |
|---|---|
| `01-run-experiment.sh` | Top-level runner |
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

# Full run: deploy, configure HPA, run load, collect telemetry
MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh

# Approve CSRs in background (required on CloudLab)
while true; do sleep 2 && kubectl get csr -o name | xargs kubectl certificate approve 2>/dev/null; done
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
