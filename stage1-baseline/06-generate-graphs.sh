#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if matplotlib is installed
if ! python3 -c "import matplotlib" 2>/dev/null; then
  echo "Error: matplotlib is required. Install with:"
  echo "  pip3 install matplotlib"
  exit 1
fi

# Run the Python script
exec python3 "${ROOT_DIR}/06-generate-graphs.py" "$@"
