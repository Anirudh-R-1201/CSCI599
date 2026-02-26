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
MODE=full ./01-run-experiment.sh

# Analyze latest run
./02-analyze-results.sh
```

## Runner Modes

`01-run-experiment.sh` supports:

- `MODE=full` - deploy + HPA + traffic + baseline collection
- `MODE=prep` - deploy + HPA only
- `MODE=traffic` - traffic + telemetry only

Useful variables:

- `CPU_THRESHOLD` (default `75`)
- `CPU_THRESHOLD` (default `50`) – lower = more replicas for same load (helps reach 7–8 pods)
- `BURSTS` (default `18`)
- `BASE_BURST_SECONDS` (default `90`), `MAX_BURST_SECONDS` (default `180`) – long bursts so HPA sees sustained high CPU
- `MAX_SLEEP_SECONDS` (default `5`)
- `QPS_FLOOR` (default `600`)
- `QPS_CEIL` (default `6000`)
- `THREADS_PER_ENDPOINT` (default `48`)
- `SAMPLE_INTERVAL` (default `8`)

Example:

```bash
MODE=full BURSTS=24 QPS_CEIL=8000 ./01-run-experiment.sh
# If replicas still don't reach 7–8: CPU_THRESHOLD=40
```

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
- `network-analysis/latency-vs-replicas.csv` (HPA desired/current vs s2s p95/p99 per timestamp)
- `network-analysis/experiment-metrics-recommendations.md`
- `graphs/*.png` (if matplotlib available): 01–06 in story order (load → response → latency vs QPS → scaling → **service placement** → summary); see `graphs/README.txt`

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