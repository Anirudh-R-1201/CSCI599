#!/usr/bin/env bash
set -euo pipefail

# Detailed network analysis during concurrent load test
# Captures: pod-to-pod latencies, pod locations, network stats, service mesh metrics

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-cloudlab-cluster}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

DURATION="${DURATION:-300}"
QPS_HOME="${QPS_HOME:-100}"
QPS_PRODUCT="${QPS_PRODUCT:-80}"
QPS_CART="${QPS_CART:-60}"
THREADS_PER_ENDPOINT="${THREADS_PER_ENDPOINT:-24}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"  # Network stats sampling interval

RUN_ID="${RUN_ID:-$(date +"%Y%m%d-%H%M%S")}"
DATA_DIR_BASE="${ROOT_DIR}/data/${RUN_ID}"
DATA_DIR="${DATA_DIR_BASE}/loadgen"
NETWORK_DIR="${DATA_DIR_BASE}/network-analysis"

mkdir -p "${DATA_DIR}" "${NETWORK_DIR}"
export LOADGEN_DIR="${DATA_DIR}"

echo "=========================================="
echo "Detailed Network Analysis Load Test"
echo "=========================================="
echo "Duration: ${DURATION}s (~$((DURATION / 60)) minutes)"
echo "Sampling interval: ${SAMPLE_INTERVAL}s"
echo "Results: ${NETWORK_DIR}"
echo ""

# Deploy fortio
echo "Deploying Fortio load generator..."
kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${ROOT_DIR}/fortio-loadgen.yaml"
kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready pod/fortio-loadgen --timeout=120s

PRODUCT_ID=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  curl -s http://frontend:80/ | grep -oP 'href="/product/\K[^"]+' | head -1 || echo "OLJCESPC7Z")

# Create metadata
META_FILE="${DATA_DIR}/bursts.jsonl"
cat > "${META_FILE}" <<EOF
{"burst_index": 0, "endpoint": "home", "qps": ${QPS_HOME}, "duration_s": ${DURATION}, "sleep_s": 0}
{"burst_index": 1, "endpoint": "product", "qps": ${QPS_PRODUCT}, "duration_s": ${DURATION}, "sleep_s": 0}
{"burst_index": 2, "endpoint": "cart", "qps": ${QPS_CART}, "duration_s": ${DURATION}, "sleep_s": 0}
EOF

echo "=========================================="
echo "Starting Network Analysis Collection"
echo "=========================================="
echo ""

# Function to capture pod locations and network info
capture_pod_network_info() {
  local timestamp=$1
  local output_file="${NETWORK_DIR}/pod-network-${timestamp}.json"
  
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -n default -o json | \
    jq '{
      timestamp: "'${timestamp}'",
      pods: [.items[] | {
        name: .metadata.name,
        namespace: .metadata.namespace,
        app: .metadata.labels.app,
        node: .spec.nodeName,
        hostIP: .status.hostIP,
        podIP: .status.podIP,
        phase: .status.phase,
        qosClass: .status.qosClass,
        startTime: .status.startTime,
        containers: [.status.containerStatuses[]? | {
          name: .name,
          ready: .ready,
          restartCount: .restartCount,
          started: .started
        }]
      }]
    }' > "${output_file}"
}

# Function to capture service endpoints
capture_service_endpoints() {
  local timestamp=$1
  local output_file="${NETWORK_DIR}/service-endpoints-${timestamp}.json"
  
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get endpoints -n default -o json | \
    jq '{
      timestamp: "'${timestamp}'",
      endpoints: [.items[] | {
        service: .metadata.name,
        subsets: [.subsets[]? | {
          addresses: [.addresses[]? | {
            ip: .ip,
            nodeName: .nodeName,
            targetRef: .targetRef
          }],
          ports: [.ports[]? | {
            name: .name,
            port: .port,
            protocol: .protocol
          }]
        }]
      }]
    }' > "${output_file}"
}

# Function to measure pod-to-pod latency
measure_pod_to_pod_latency() {
  local timestamp=$1
  local output_file="${NETWORK_DIR}/pod-latency-${timestamp}.txt"
  
  echo "=== Pod-to-Pod Latency Measurements ===" > "${output_file}"
  echo "Timestamp: ${timestamp}" >> "${output_file}"
  echo "" >> "${output_file}"
  
  # Get all service pods
  local pods=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -n default -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v fortio)
  
  for source_pod in $pods; do
    # Get source pod IP and node
    local source_info=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get pod "$source_pod" -n default -o json | \
      jq -r '{ip: .status.podIP, node: .spec.nodeName, app: .metadata.labels.app} | @json')
    
    echo "Source: $source_pod" >> "${output_file}"
    echo "  Info: $source_info" >> "${output_file}"
    
    # Ping a few target services
    for target_svc in frontend productcatalogservice cartservice; do
      if [[ "$source_pod" =~ ^${target_svc}- ]]; then
        continue  # Skip self
      fi
      
      # Measure latency using curl time
      local latency=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" exec "$source_pod" -n default -- \
        sh -c "time curl -s -o /dev/null -w '%{time_total}' http://${target_svc}:80/ 2>&1 | grep real | awk '{print \$2}'" 2>/dev/null || echo "N/A")
      
      echo "  -> ${target_svc}: ${latency}" >> "${output_file}"
    done
    echo "" >> "${output_file}"
  done
}

# Function to capture network statistics
capture_network_stats() {
  local timestamp=$1
  local output_file="${NETWORK_DIR}/network-stats-${timestamp}.json"
  
  # Get network stats from all pods
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -n default -o json | \
    jq '{
      timestamp: "'${timestamp}'",
      pods: [.items[] | {
        name: .metadata.name,
        node: .spec.nodeName,
        podIP: .status.podIP
      }]
    }' > "${output_file}"
  
  # Try to get OVN-specific metrics if available
  local ovn_stats="${NETWORK_DIR}/ovn-stats-${timestamp}.txt"
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -n ovn-kubernetes -o wide > "${ovn_stats}" 2>/dev/null || true
}

# Function to capture node network info
capture_node_network_info() {
  local timestamp=$1
  local output_file="${NETWORK_DIR}/node-network-${timestamp}.json"
  
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o json | \
    jq '{
      timestamp: "'${timestamp}'",
      nodes: [.items[] | {
        name: .metadata.name,
        internalIP: (.status.addresses[] | select(.type=="InternalIP") | .address),
        hostname: (.status.addresses[] | select(.type=="Hostname") | .address),
        capacity: .status.capacity,
        allocatable: .status.allocatable,
        podCIDR: .spec.podCIDR,
        conditions: [.status.conditions[] | {type: .type, status: .status}]
      }]
    }' > "${output_file}"
}

# Function to capture service mesh metrics (if available)
capture_service_metrics() {
  local timestamp=$1
  local output_file="${NETWORK_DIR}/service-metrics-${timestamp}.json"
  
  # Get service information
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get services -n default -o json | \
    jq '{
      timestamp: "'${timestamp}'",
      services: [.items[] | {
        name: .metadata.name,
        type: .spec.type,
        clusterIP: .spec.clusterIP,
        ports: .spec.ports,
        selector: .spec.selector
      }]
    }' > "${output_file}"
}

# Background monitoring function
start_network_monitoring() {
  local end_time=$((SECONDS + DURATION))
  local sample_count=0
  
  echo "Starting continuous network monitoring..."
  
  while [ $SECONDS -lt $end_time ]; do
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    sample_count=$((sample_count + 1))
    
    echo "  Sample ${sample_count}: ${timestamp}"
    
    # Capture all metrics
    capture_pod_network_info "${timestamp}" &
    capture_service_endpoints "${timestamp}" &
    capture_network_stats "${timestamp}" &
    capture_node_network_info "${timestamp}" &
    capture_service_metrics "${timestamp}" &
    
    # Measure pod-to-pod latency (less frequently as it's expensive)
    if [ $((sample_count % 3)) -eq 0 ]; then
      echo "    → Measuring pod-to-pod latencies..."
      measure_pod_to_pod_latency "${timestamp}" &
    fi
    
    wait  # Wait for all background captures
    
    sleep "${SAMPLE_INTERVAL}"
  done
  
  echo "Network monitoring complete. ${sample_count} samples collected."
}

echo "=========================================="
echo "Phase 1: Starting Network Monitoring"
echo "=========================================="
echo ""

# Start network monitoring in background
start_network_monitoring > "${NETWORK_DIR}/monitoring.log" 2>&1 &
MONITOR_PID=$!

sleep 5

echo "=========================================="
echo "Phase 2: Starting Concurrent Load Tests"
echo "=========================================="
echo ""

LOAD_PIDS=()

# Start concurrent load tests
echo "► HOME endpoint (qps=${QPS_HOME}, threads=${THREADS_PER_ENDPOINT})"
kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  fortio load -c "${THREADS_PER_ENDPOINT}" -qps "${QPS_HOME}" -t "${DURATION}s" \
  -p "50,75,90,95,99,99.9" -abort-on -1 -allow-initial-errors \
  -json - -labels "stage1-burst-0-home" \
  http://frontend:80/ > "${DATA_DIR}/fortio-burst-0.json" 2> "${DATA_DIR}/fortio-burst-0.log" &
LOAD_PIDS+=($!)

sleep 2

echo "► PRODUCT endpoint (qps=${QPS_PRODUCT}, threads=${THREADS_PER_ENDPOINT})"
kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  fortio load -c "${THREADS_PER_ENDPOINT}" -qps "${QPS_PRODUCT}" -t "${DURATION}s" \
  -p "50,75,90,95,99,99.9" -abort-on -1 -allow-initial-errors \
  -json - -labels "stage1-burst-1-product" \
  "http://frontend:80/product/${PRODUCT_ID}" > "${DATA_DIR}/fortio-burst-1.json" 2> "${DATA_DIR}/fortio-burst-1.log" &
LOAD_PIDS+=($!)

sleep 2

echo "► CART endpoint (qps=${QPS_CART}, threads=${THREADS_PER_ENDPOINT})"
kubectl --kubeconfig "${KUBECONFIG_PATH}" exec fortio-loadgen -- \
  fortio load -c "${THREADS_PER_ENDPOINT}" -qps "${QPS_CART}" -t "${DURATION}s" \
  -p "50,75,90,95,99,99.9" -abort-on -1 -allow-initial-errors \
  -json - -labels "stage1-burst-2-cart" \
  http://frontend:80/cart > "${DATA_DIR}/fortio-burst-2.json" 2> "${DATA_DIR}/fortio-burst-2.log" &
LOAD_PIDS+=($!)

echo ""
echo "All load generators started. Waiting for completion..."
echo ""

# Wait for load tests to complete
for pid in "${LOAD_PIDS[@]}"; do
  wait $pid
done

echo ""
echo "Load tests complete. Waiting for monitoring to finish..."
wait $MONITOR_PID

echo ""
echo "=========================================="
echo "Analysis Complete!"
echo "=========================================="
echo ""

# Generate analysis summary
SUMMARY_FILE="${NETWORK_DIR}/analysis-summary.txt"

cat > "${SUMMARY_FILE}" <<EOF
Network Analysis Summary
========================
Run ID: ${RUN_ID}
Duration: ${DURATION}s
Sampling Interval: ${SAMPLE_INTERVAL}s

Data Collected:
---------------
EOF

echo "Total samples: $(ls ${NETWORK_DIR}/pod-network-*.json 2>/dev/null | wc -l)" >> "${SUMMARY_FILE}"
echo "Pod latency measurements: $(ls ${NETWORK_DIR}/pod-latency-*.txt 2>/dev/null | wc -l)" >> "${SUMMARY_FILE}"
echo "Service endpoint snapshots: $(ls ${NETWORK_DIR}/service-endpoints-*.json 2>/dev/null | wc -l)" >> "${SUMMARY_FILE}"
echo "Network stats snapshots: $(ls ${NETWORK_DIR}/network-stats-*.json 2>/dev/null | wc -l)" >> "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"

# Pod distribution summary
echo "Pod Distribution:" >> "${SUMMARY_FILE}"
echo "----------------" >> "${SUMMARY_FILE}"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get pods -n default -o wide | \
  awk 'NR>1 {print $7}' | sort | uniq -c >> "${SUMMARY_FILE}"

echo "" >> "${SUMMARY_FILE}"
echo "Load Test Results:" >> "${SUMMARY_FILE}"
echo "-----------------" >> "${SUMMARY_FILE}"

for idx in 0 1 2; do
  endpoint_name=("HOME" "PRODUCT" "CART")
  if [ -f "${DATA_DIR}/fortio-burst-${idx}.json" ]; then
    echo "" >> "${SUMMARY_FILE}"
    echo "${endpoint_name[$idx]} endpoint:" >> "${SUMMARY_FILE}"
    cat "${DATA_DIR}/fortio-burst-${idx}.json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f\"  Requests: {data.get('DurationHistogram', {}).get('Count', 'N/A')}\")
print(f\"  Actual QPS: {data.get('ActualQPS', 'N/A'):.2f}\")
p = {p['Percentile']: p['Value'] for p in data.get('DurationHistogram', {}).get('Percentiles', [])}
print(f\"  p50: {p.get(50, 0)*1000:.2f}ms\")
print(f\"  p95: {p.get(95, 0)*1000:.2f}ms\")
print(f\"  p99: {p.get(99, 0)*1000:.2f}ms\")
" >> "${SUMMARY_FILE}" 2>/dev/null
  fi
done

cat "${SUMMARY_FILE}"

echo ""
echo "=========================================="
echo "Results Location:"
echo "=========================================="
echo "Load test data: ${DATA_DIR}"
echo "Network analysis: ${NETWORK_DIR}"
echo "Summary: ${SUMMARY_FILE}"
echo ""
echo "Generate graphs:"
echo "  ./06-generate-graphs.sh data/${RUN_ID}"
echo ""
echo "Analyze network data:"
echo "  ./07-analyze-network-data.py data/${RUN_ID}"
echo ""
