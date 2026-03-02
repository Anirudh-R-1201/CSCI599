# Stage 1 Baseline (Refined)

This folder now uses a minimal workflow:

- `01-run-experiment.sh` - single runner
- `02-analyze-results.sh` - single analyzer
- `03e-bursty-highload-network-test.sh` - bursty high-load generator + telemetry (internal)
- `07-setup-hpa.sh` - HPA helper (internal)
- `07-analyze-network-data.py` - analysis engine (internal)
- `06-generate-graphs.py` - graph generator (internal)

See **REQUIREMENTS.md** for how each original requirement is covered.

## Quick Start

```bash
cd ~/CSCI599/stage1-baseline

# Full run: deploy, set HPA, run bursty load, collect baseline snapshots
MODE=full ./01-run-experiment.sh && ./02-analyze-results.sh

#Also run in the bg
while true; do sleep 2 && kubectl get csr -o name | xargs kubectl certificate approve 2>/dev/null; done


# Analyze latest run
./02-analyze-results.sh
```

## Runner Modes

`01-run-experiment.sh` supports:

- `MODE=full` – deploy + HPA + traffic + baseline collection (also approves pending CSRs before starting)
- `MODE=prep` – deploy + HPA only (also approves pending CSRs)
- `MODE=traffic` – traffic + telemetry only

Useful variables:

- `CPU_THRESHOLD` (default `75`) – HPA CPU target %; use 50 for more aggressive scaling
- `BURSTS` (default `18`)
- `BASE_BURST_SECONDS` (default `45`), `MAX_BURST_SECONDS` (default `90`) – burst length so HPA can scale up
- `MIN_SLEEP_SECONDS` (default `45`), `MAX_SLEEP_SECONDS` (default `120`) – **time between bursts** so replicas can scale down; longer gaps make scale-up/scale-down and cross-node latency effects more visible
- `QPS_FLOOR` (default `80`), `QPS_CEIL` (default `500`) – load range; lower ceiling keeps latency readable and highlights networking cost when pods are spread across nodes
- `THREADS_PER_ENDPOINT` (default `12`)
- `SAMPLE_INTERVAL` (default `8`)

Example:

```bash
MODE=full ./01-run-experiment.sh
# Higher load / more bursts: BURSTS=24 QPS_CEIL=800 ./01-run-experiment.sh
# If replicas don't scale: CPU_THRESHOLD=50
```

## Fixed-node experiments (no node scaling)

The cluster has a **fixed set of nodes**; only **pods** scale (HPA). `node_count` in the analysis means *how many of those nodes have ≥1 workload pod* (pod spread), not cluster size.

**Metrics that matter:**
- **Same-node vs cross-node latency** (graphs 07, 08): latency when caller and callee share a node vs different nodes.
- **Pod spread vs latency** (graph 09b, section 6 of `analysis-summary.txt`): correlation between `node_count` and s2s p95; higher spread often means more cross-node traffic and higher latency.
- **Queueing vs network RTT** (graph 11): separates overlay/network cost from app queueing.
- **Tail latency by (source_node, target_service)** (graph 10, section 5): which node pairs see the worst latency.

See `experiment-metrics-recommendations.md` for the same list and quick facts.

## Analysis

`02-analyze-results.sh [RUN_DIR]`

- If `RUN_DIR` is omitted, latest run under `data/` is used.
- Runs:
  - `07-analyze-network-data.py`
  - `06-generate-graphs.py` (only if `matplotlib` is installed)

Primary outputs:

- `network-analysis/analysis-summary.txt` (sections: Node→Pods, **Service→Nodes** (which service's pods are on which node), e2e latency, s2s, queueing vs network, node-pair tail latency)
- `network-analysis/pod-placement-analysis.json`
- `network-analysis/e2e-latency-summary.json`
- `network-analysis/service-to-service-latency-summary.json`
- `network-analysis/node-pair-latency-summary.json` (p95/p99 by source_node → target_service)
- `network-analysis/latency-vs-replicas.csv` (HPA desired/current, s2s p95/p99, and **node_count** per timestamp)
- `network-analysis/experiment-metrics-recommendations.md`
- `graphs/*.png` (if matplotlib available): 01–06 in story order; 07–11 for network (cross-node ratio, same vs cross-node CDF, **09b p95 vs node count** for cross-node latency cost); see `graphs/README.txt`

## Data Layout

```text
data/<RUN_ID>/
├── loadgen/
│   ├── bursts.jsonl
│   └── fortio-burst-*-{home,product,cart}.json
├── network-analysis/
│   ├── pod-network-*.json
│   ├── service-endpoints-*.json
│   ├── node-network-*.json
│   ├── hpa-*.json
│   ├── service-to-service-latency.jsonl
│   ├── analysis-summary.txt
│   ├── pod-placement-analysis.json
│   ├── e2e-latency-summary.json
│   ├── service-to-service-latency-summary.json
│   ├── node-pair-latency-summary.json
│   ├── latency-vs-replicas.csv
│   └── experiment-metrics-recommendations.md
└── baseline/
    ├── nodes.{txt,json}
    ├── pods.{txt,json}
    ├── services.yaml
    ├── endpoints.yaml
    ├── deployments.yaml
    ├── events.txt
    ├── service-graph.{json,csv}
    └── latency-summary.json
```