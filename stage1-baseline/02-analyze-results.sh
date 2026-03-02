#!/usr/bin/env bash
set -euo pipefail

# Primary analysis entrypoint for stage1 baseline experiments.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${1:-}"

if [ -z "${RUN_DIR}" ]; then
  # Use latest run in data dir.
  latest="$(ls -t "${ROOT_DIR}/data" 2>/dev/null | head -1 || true)"
  if [ -z "${latest}" ]; then
    echo "Error: no run directories found under ${ROOT_DIR}/data"
    exit 1
  fi
  RUN_DIR="${ROOT_DIR}/data/${latest}"
fi

if [ ! -d "${RUN_DIR}" ]; then
  echo "Error: run directory not found: ${RUN_DIR}"
  exit 1
fi

echo "Analyzing run: ${RUN_DIR}"
python3 "${ROOT_DIR}/07-analyze-network-data.py" "${RUN_DIR}"

# Generate all graphs (01–11); install matplotlib if missing so CloudLab gets 07–11 by default
if ! python3 -c "import matplotlib" >/dev/null 2>&1; then
  echo "Installing matplotlib for graph generation (01–11)..."
  pip3 install --user matplotlib numpy 2>/dev/null || true
fi
if python3 -c "import matplotlib" >/dev/null 2>&1; then
  python3 "${ROOT_DIR}/06-generate-graphs.py" "${RUN_DIR}"
else
  echo "Skipping graphs: matplotlib not installed. Install with: pip3 install --user matplotlib numpy"
fi

echo ""
echo "Analysis artifacts:"
echo "  ${RUN_DIR}/network-analysis/analysis-summary.txt"
echo "  ${RUN_DIR}/network-analysis/pod-placement-analysis.json"
echo "  ${RUN_DIR}/network-analysis/e2e-latency-summary.json"
echo "  ${RUN_DIR}/network-analysis/service-to-service-latency-summary.json"
echo "  ${RUN_DIR}/network-analysis/experiment-metrics-recommendations.md"
echo "  ${RUN_DIR}/graphs/*.png (01–11; see graphs/README.txt)"
