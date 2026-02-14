#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-cloudlab-cluster}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

BURSTS="${BURSTS:-30}"
BASE_QPS="${BASE_QPS:-5}"
MAX_QPS="${MAX_QPS:-80}"
BASE_DURATION="${BASE_DURATION:-10}"
MAX_DURATION="${MAX_DURATION:-40}"
ALPHA_QPS="${ALPHA_QPS:-1.5}"
ALPHA_DURATION="${ALPHA_DURATION:-1.4}"
MAX_SLEEP="${MAX_SLEEP:-20}"

RUN_ID="${RUN_ID:-$(date +"%Y%m%d-%H%M%S")}"
DATA_DIR_BASE="${ROOT_DIR}/data/${RUN_ID}"
DATA_DIR="${DATA_DIR_BASE}/loadgen"
META_FILE="${DATA_DIR}/bursts.jsonl"

mkdir -p "${DATA_DIR}"
export LOADGEN_DIR="${DATA_DIR}"

echo "Deploying Fortio load generator pod..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ROOT_DIR}/fortio-loadgen.yaml"
kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready pod/fortio-loadgen --timeout=120s

echo "Generating burst schedule..."
python3 - <<'PY' > "${META_FILE}"
import json
import os
import random
import time

bursts = int(os.environ.get("BURSTS", "30"))
base_qps = int(os.environ.get("BASE_QPS", "5"))
max_qps = int(os.environ.get("MAX_QPS", "80"))
base_dur = int(os.environ.get("BASE_DURATION", "10"))
max_dur = int(os.environ.get("MAX_DURATION", "40"))
alpha_qps = float(os.environ.get("ALPHA_QPS", "1.5"))
alpha_dur = float(os.environ.get("ALPHA_DURATION", "1.4"))
max_sleep = int(os.environ.get("MAX_SLEEP", "20"))

random.seed(int(time.time()))

for i in range(bursts):
    qps = min(max_qps, max(1, int(base_qps * random.paretovariate(alpha_qps))))
    dur = min(max_dur, max(5, int(base_dur * random.paretovariate(alpha_dur))))
    sleep_s = random.randint(1, max_sleep)
    print(json.dumps({
        "burst_index": i,
        "qps": qps,
        "duration_s": dur,
        "sleep_s": sleep_s
    }))
PY

echo "Running bursts (self-similar traffic)..."
while read -r line; do
  idx=$(echo "${line}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["burst_index"])')
  qps=$(echo "${line}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["qps"])')
  dur=$(echo "${line}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["duration_s"])')
  sleep_s=$(echo "${line}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sleep_s"])')

  echo "Burst ${idx}: qps=${qps} duration=${dur}s sleep=${sleep_s}s"
  LOG_FILE="${DATA_DIR}/fortio-burst-${idx}.log"
  JSON_FILE="${DATA_DIR}/fortio-burst-${idx}.json"

  kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
    fortio load -qps "${qps}" -t "${dur}s" -p "50,95,99,99.9" \
    -abort-on -1 -allow-initial-errors -json - -labels "stage1-burst-${idx}" \
    http://frontend:80/ > "${JSON_FILE}" 2> "${LOG_FILE}"

  sleep "${sleep_s}"
done < "${META_FILE}"

echo "Load generation complete. Logs and metadata stored in ${DATA_DIR}"
