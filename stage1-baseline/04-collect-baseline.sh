#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-ovn-baseline}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${ROOT_DIR}/kubeconfig-${CLUSTER_NAME}}"
TS="$(date +"%Y%m%d-%H%M%S")"
OUT_DIR="${ROOT_DIR}/data/stage1-baseline-${TS}"

mkdir -p "${OUT_DIR}"
export OUT_DIR
export KUBECONFIG_PATH

echo "Collecting baseline data to ${OUT_DIR}"

kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o wide > "${OUT_DIR}/nodes.txt"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o json > "${OUT_DIR}/nodes.json"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -A -o wide > "${OUT_DIR}/pods.txt"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -A -o json > "${OUT_DIR}/pods.json"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get svc -A -o yaml > "${OUT_DIR}/services.yaml"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get endpoints -A -o yaml > "${OUT_DIR}/endpoints.yaml"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get deploy -A -o yaml > "${OUT_DIR}/deployments.yaml"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get ds -A -o yaml > "${OUT_DIR}/daemonsets.yaml"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get events -A --sort-by=.lastTimestamp > "${OUT_DIR}/events.txt"

echo "Deriving service communication graph from deployment env vars..."
python3 - <<'PY' > "${OUT_DIR}/service-graph.json"
import json
import os
import re
import subprocess

kubeconfig = os.environ.get("KUBECONFIG_PATH")
cmd = ["kubectl", "--kubeconfig", kubeconfig, "get", "deploy", "-A", "-o", "json"]
raw = subprocess.check_output(cmd).decode("utf-8")
data = json.loads(raw)

edges = []
services = set()

addr_re = re.compile(r"^(.+?)_ADDR$")

for item in data.get("items", []):
    name = item["metadata"]["name"]
    namespace = item["metadata"]["namespace"]
    services.add(f"{namespace}/{name}")

    containers = item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
    for c in containers:
        for env in c.get("env", []):
            key = env.get("name", "")
            m = addr_re.match(key)
            if not m:
                continue
            target = env.get("value", "")
            target_svc = target.split(":")[0] if target else ""
            if target_svc:
                edges.append({
                    "from": f"{namespace}/{name}",
                    "to": f"default/{target_svc}"
                })

out = {
    "nodes": sorted(services),
    "edges": edges
}
print(json.dumps(out, indent=2))
PY

python3 - <<'PY' > "${OUT_DIR}/service-graph.csv"
import json
import os
import sys

path = os.path.join(os.environ["OUT_DIR"], "service-graph.json")
with open(path, "r") as f:
    data = json.load(f)

print("from,to")
for e in data.get("edges", []):
    print(f"{e['from']},{e['to']}")
PY

if [ -n "${LOADGEN_DIR:-}" ] && [ -d "${LOADGEN_DIR}" ]; then
  echo "Parsing Fortio JSON results from ${LOADGEN_DIR}..."
  python3 - <<'PY' > "${OUT_DIR}/latency-summary.json"
import glob
import json
import os

loadgen_dir = os.environ.get("LOADGEN_DIR", "")
results = []

for path in sorted(glob.glob(os.path.join(loadgen_dir, "fortio-burst-*.json"))):
    with open(path, "r") as f:
        data = json.load(f)

    percentiles = {p["Percentile"]: p["Value"] for p in data.get("DurationHistogram", {}).get("Percentiles", [])}
    results.append({
        "file": os.path.basename(path),
        "actual_qps": data.get("ActualQPS"),
        "duration_ns": data.get("ActualDuration"),
        "p50_s": percentiles.get(50),
        "p95_s": percentiles.get(95),
        "p99_s": percentiles.get(99),
        "p999_s": percentiles.get(99.9)
    })

print(json.dumps({
    "source_dir": loadgen_dir,
    "bursts": results
}, indent=2))
PY
fi

echo "Baseline data collection complete."
