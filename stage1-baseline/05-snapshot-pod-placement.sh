#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-ovn-baseline}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${ROOT_DIR}/kubeconfig-${CLUSTER_NAME}}"

INTERVAL_SEC="${INTERVAL_SEC:-30}"
COUNT="${COUNT:-20}"

RUN_ID="${RUN_ID:-$(date +"%Y%m%d-%H%M%S")}"
DATA_DIR_BASE="${ROOT_DIR}/data/${RUN_ID}"
OUT_DIR="${DATA_DIR_BASE}/pod-placement"
INDEX_FILE="${OUT_DIR}/index.jsonl"

mkdir -p "${OUT_DIR}"

echo "Capturing ${COUNT} pod placement snapshots every ${INTERVAL_SEC}s..."

for i in $(seq 1 "${COUNT}"); do
  snap_ts="$(date -Iseconds)"
  snap_file="${OUT_DIR}/pods-${i}.json"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -A -o json > "${snap_file}"
  printf '{"timestamp":"%s","file":"%s"}\n' "${snap_ts}" "$(basename "${snap_file}")" >> "${INDEX_FILE}"
  sleep "${INTERVAL_SEC}"
done

echo "Snapshots saved in ${OUT_DIR}"
