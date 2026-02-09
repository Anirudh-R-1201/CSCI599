Stage 1: Baseline (Upstream OVN-Kubernetes)
===========================================

Goal
----
Establish a local, reproducible baseline for pod placement, inter-service
communication, and latency using upstream OVN-Kubernetes on kind. This stage
does not include any network-aware scheduling or custom modifications.

Assumptions and limitations (local Docker / kind)
-------------------------------------------------
- Single host and shared kernel: node isolation is container-based, not physical.
- Overlay networking and container networking share the same host NIC.
- Results are useful for relative comparisons, not absolute production latency.
- No service mesh or tracing by default; service-to-service request rates are
  approximated via workload topology and loadgen outputs.
- Load generation is bursty (Pareto-like) and targets the frontend service,
  which exercises east-west calls in the microservices graph.

Prerequisites
-------------
- Docker (or compatible OCI runtime)
- kind
- kubectl
- git, make, go, jq, python3, openssl, awk, sed

Step-by-step
------------
1) Create the kind cluster and install upstream OVN-Kubernetes:
   - Run `./01-kind-ovn-upstream.sh`
   - This clones upstream ovn-kubernetes (if not present), builds images, and
     provisions a 1 control-plane + 3 worker kind cluster.
   - Optional: pin a version with `OVN_GITREF=v1.0.0` (tag/branch/commit).

2) Deploy Online Boutique:
   - Run `./02-deploy-workload.sh`

3) Generate self-similar traffic:
   - Run `./03-generate-self-similar-load.sh`
   - This deploys a Fortio load generator pod and runs bursty traffic to
     `frontend:80` with randomized bursts.

4) Collect baseline data:
   - Run `./04-collect-baseline.sh`
   - To include latency summaries from loadgen results:
     `LOADGEN_DIR=stage1-baseline/data/<loadgen-dir>/loadgen ./04-collect-baseline.sh`
   - Optional: run continuous placement snapshots with
     `./05-snapshot-pod-placement.sh`.

Artifacts
---------
All data is written under `stage1-baseline/data/` with a timestamped
subdirectory labeled `stage1-baseline`.

Contents include:
- Pod placement snapshots (`pods_*.json`, `pods_*.txt`)
- Nodes/services/endpoints/deployments YAML/JSON
- Workload topology graph derived from service env vars
- Load generator logs and latency summaries (p50/p95/p99 when parsed)

Notes
-----
- This stage uses upstream OVN-Kubernetes via `contrib/kind.sh` with no
  feature flags that change scheduling or traffic behavior.
- If you later introduce nw-affinity, re-run the same scripts to compare.
