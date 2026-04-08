#!/usr/bin/env bash
set -euo pipefail

# Primary entrypoint for stage1 baseline experiments.
# Keep this script as the single recommended workflow for users.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

# Modes:
#   full    -> deploy (if needed), setup HPA, run bursty traffic, collect baseline
#   traffic -> run only bursty traffic + network telemetry
#   prep    -> deploy + setup HPA only
MODE="${MODE:-full}"

# Shared defaults (75% CPU target; use CPU_THRESHOLD=50 for more aggressive scaling to 7–8 pods)
CPU_THRESHOLD="${CPU_THRESHOLD:-75}"
RUN_ID="${RUN_ID:-$(date +"%Y%m%d-%H%M%S")}"
export RUN_ID

# Bursty high-load defaults (override as needed) – long bursts so HPA sees sustained high CPU
BURSTS="${BURSTS:-18}"
BASE_BURST_SECONDS="${BASE_BURST_SECONDS:-90}"
MAX_BURST_SECONDS="${MAX_BURST_SECONDS:-180}"
MAX_SLEEP_SECONDS="${MAX_SLEEP_SECONDS:-5}"
QPS_FLOOR="${QPS_FLOOR:-25}"   # floor for heavy_tail bursts  (~100% efficiency)
QPS_CEIL="${QPS_CEIL:-100}"   # spike ceiling (~25% above saturation knee of ~75–80 req/s)
THREADS_PER_ENDPOINT="${THREADS_PER_ENDPOINT:-10}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-8}"
# Fixed seed so BASE and TOPO runs get identical burst plans.
# Change only when you want a different (but still reproducible) load profile.
BURST_SEED="${BURST_SEED:-42}"
# Replica mode: fixed (min=max=MIN_REPLICAS) or scale (min=MIN_REPLICAS, max=MAX_REPLICAS).
REPLICA_MODE="${REPLICA_MODE:-fixed}"
# MIN_REPLICAS: fixed replica count in 'fixed' mode, or floor in 'scale' mode.
#   2 → lighter footprint, lower baseline latency, faster pod startup
#   4 → stronger steady state, better topo-aware locality (more zone-local candidates)
MIN_REPLICAS="${MIN_REPLICAS:-4}"
MAX_REPLICAS="${MAX_REPLICAS:-4}"

echo "========================================"
echo "Stage1 Experiment Runner"
echo "========================================"
echo "MODE=${MODE}  REPLICA_MODE=${REPLICA_MODE}  MIN_REPLICAS=${MIN_REPLICAS}  BURST_SEED=${BURST_SEED}"
echo "RUN_ID=${RUN_ID}"
echo ""

ensure_cluster() {
  if ! kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes >/dev/null 2>&1; then
    echo "Error: cannot connect to Kubernetes cluster via ${KUBECONFIG_PATH}"
    exit 1
  fi

  # Block if any nodes are NotReady
  # Use subshell around grep so pipefail doesn't trigger when all nodes are Ready
  NOT_READY=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes --no-headers \
    | (grep -v " Ready" || true) | wc -l | tr -d '[:space:]')
  NOT_READY="${NOT_READY:-0}"
  if [ "${NOT_READY}" -gt 0 ]; then
    echo "Error: ${NOT_READY} node(s) are not Ready. Fix before running experiment:"
    kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes
    exit 1
  fi

  # Block if ovnkube-node pods are not all healthy
  UNHEALTHY_OVN=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" -n ovn-kubernetes get pods -l app=ovnkube-node --no-headers 2>/dev/null \
    | (grep -v "Running" || true) | wc -l | tr -d '[:space:]')
  UNHEALTHY_OVN="${UNHEALTHY_OVN:-0}"
  if [ "${UNHEALTHY_OVN}" -gt 0 ]; then
    echo "Error: ${UNHEALTHY_OVN} ovnkube-node pod(s) not Running. Approve pending CSRs first:"
    echo "  kubectl get csr | grep Pending | awk '{print \$1}' | xargs kubectl certificate approve"
    exit 1
  fi

  # Warn if any node disk is >85% full (causes pod evictions / ContainerStatusUnknown)
  for node in $(kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes --no-headers | awk '{print $1}'); do
    shortname=$(echo "${node}" | cut -d. -f1)
    usage=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 "${shortname}" \
      "df / --output=pcent | tail -1 | tr -d ' %'" 2>/dev/null || echo "0")
    if [ "${usage:-0}" -gt 85 ]; then
      echo "Warning: ${node} disk is ${usage}% full. Clean with:"
      echo "  ssh ${shortname} 'sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock rmi --prune; sudo journalctl --vacuum-size=500M'"
    fi
  done

  # Clean up stale Failed/Error pods to keep placement data clean
  kubectl --kubeconfig "${KUBECONFIG_PATH}" delete pod \
    --field-selector=status.phase=Failed -n default 2>/dev/null || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -n default --no-headers \
    | awk '/Error|Unknown/{print $1}' \
    | xargs -r kubectl --kubeconfig "${KUBECONFIG_PATH}" delete pod -n default 2>/dev/null || true
}

# Approve pending certificate signing requests (e.g. for OVN-Kubernetes / new nodes)
approve_pending_csrs() {
  local pending
  pending=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get csr -o name 2>/dev/null || true)
  if [ -n "${pending}" ]; then
    echo "Approving pending certificate signing requests..."
    echo "${pending}" | xargs kubectl --kubeconfig "${KUBECONFIG_PATH}" certificate approve 2>/dev/null || true
    echo "CSR approval done."
  fi
}

ensure_metrics_server() {
  if ! kubectl --kubeconfig "${KUBECONFIG_PATH}" get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    echo "Installing metrics-server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=180s
  fi
}

deploy_workload_if_needed() {
  if ! kubectl --kubeconfig "${KUBECONFIG_PATH}" get deployment frontend >/dev/null 2>&1; then
    local manifest="${ROOT_DIR}/online-boutique.yaml"
    echo "Deploying workload from ${manifest} ..."
    kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${manifest}"
    kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Available deploy --all -n default --timeout=600s
  else
    echo "Workload already deployed."
  fi
}

setup_hpa() {
  CPU_THRESHOLD="${CPU_THRESHOLD}" \
  REPLICA_MODE="${REPLICA_MODE}" \
  MIN_REPLICAS="${MIN_REPLICAS}" \
  MAX_REPLICAS="${MAX_REPLICAS}" \
    "${ROOT_DIR}/07-setup-hpa.sh"
}

# Deploy s2s-prober so service-to-service probes run from a client-like pod (not the load generator).
ensure_s2s_prober() {
  kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ROOT_DIR}/s2s-prober.yaml" >/dev/null
  kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Available deployment/s2s-prober --timeout=120s 2>/dev/null || true
}

run_traffic() {
  BURSTS="${BURSTS}" \
  BASE_BURST_SECONDS="${BASE_BURST_SECONDS}" \
  MAX_BURST_SECONDS="${MAX_BURST_SECONDS}" \
  MAX_SLEEP_SECONDS="${MAX_SLEEP_SECONDS}" \
  QPS_FLOOR="${QPS_FLOOR}" \
  QPS_CEIL="${QPS_CEIL}" \
  THREADS_PER_ENDPOINT="${THREADS_PER_ENDPOINT}" \
  SAMPLE_INTERVAL="${SAMPLE_INTERVAL}" \
  BURST_SEED="${BURST_SEED}" \
    "${ROOT_DIR}/03e-bursty-highload-network-test.sh"
}

collect_baseline() {
  local data_dir="${ROOT_DIR}/data/${RUN_ID}"
  local out_dir="${data_dir}/baseline"
  local load_dir="${data_dir}/loadgen"
  mkdir -p "${out_dir}"

  echo "Collecting baseline snapshots..."
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o wide > "${out_dir}/nodes.txt"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o json > "${out_dir}/nodes.json"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -A -o wide > "${out_dir}/pods.txt"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -A -o json > "${out_dir}/pods.json"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get svc -A -o yaml > "${out_dir}/services.yaml"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get endpoints -A -o yaml > "${out_dir}/endpoints.yaml"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get deploy -A -o yaml > "${out_dir}/deployments.yaml"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get events -A --sort-by=.lastTimestamp > "${out_dir}/events.txt"

  if [ -d "${load_dir}" ]; then
    LOADGEN_DIR="${load_dir}" OUT_DIR="${out_dir}" KUBECONFIG_PATH="${KUBECONFIG_PATH}" python3 - <<'PY'
import glob
import json
import os
import re
import subprocess

out_dir = os.environ["OUT_DIR"]
loadgen_dir = os.environ["LOADGEN_DIR"]
kubeconfig = os.environ["KUBECONFIG_PATH"]

# service graph
raw = subprocess.check_output(
    ["kubectl", "--kubeconfig", kubeconfig, "get", "deploy", "-A", "-o", "json"]
).decode("utf-8")
deploy = json.loads(raw)
edges = []
nodes = set()
addr_re = re.compile(r"^(.+?)_ADDR$")
for item in deploy.get("items", []):
    ns = item["metadata"]["namespace"]
    name = item["metadata"]["name"]
    nodes.add(f"{ns}/{name}")
    for c in item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
        for env in c.get("env", []):
            key = env.get("name", "")
            m = addr_re.match(key)
            if not m:
                continue
            target = (env.get("value", "") or "").split(":")[0]
            if target:
                edges.append({"from": f"{ns}/{name}", "to": f"default/{target}"})

with open(os.path.join(out_dir, "service-graph.json"), "w") as f:
    json.dump({"nodes": sorted(nodes), "edges": edges}, f, indent=2)

with open(os.path.join(out_dir, "service-graph.csv"), "w") as f:
    f.write("from,to\n")
    for e in edges:
        f.write(f"{e['from']},{e['to']}\n")

# latency summary
bursts = []
for path in sorted(glob.glob(os.path.join(loadgen_dir, "fortio-burst-*.json"))):
    with open(path, "r") as f:
        data = json.load(f)
    percentiles = {p["Percentile"]: p["Value"] for p in data.get("DurationHistogram", {}).get("Percentiles", [])}
    bursts.append(
        {
            "file": os.path.basename(path),
            "actual_qps": data.get("ActualQPS"),
            "duration_ns": data.get("ActualDuration"),
            "p50_s": percentiles.get(50),
            "p95_s": percentiles.get(95),
            "p99_s": percentiles.get(99),
            "p999_s": percentiles.get(99.9),
        }
    )

with open(os.path.join(out_dir, "latency-summary.json"), "w") as f:
    json.dump({"source_dir": loadgen_dir, "bursts": bursts}, f, indent=2)
PY
  fi
}

ensure_cluster

case "${MODE}" in
  prep)
    approve_pending_csrs
    ensure_metrics_server
    deploy_workload_if_needed
    setup_hpa
    ;;
  traffic)
    ensure_s2s_prober
    run_traffic
    ;;
  full)
    approve_pending_csrs
    ensure_metrics_server
    deploy_workload_if_needed
    setup_hpa
    ensure_s2s_prober
    run_traffic
    collect_baseline
    ;;
  *)
    echo "Error: unknown MODE=${MODE}. Use one of: full, prep, traffic"
    exit 1
    ;;
esac

echo ""
echo "Done. Run analysis with:"
echo "  ./02-analyze-results.sh data/${RUN_ID}"
