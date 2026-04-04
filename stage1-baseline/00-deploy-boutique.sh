#!/usr/bin/env bash
# Deploy Online Boutique and supporting infrastructure onto an existing Kubernetes cluster.
# Does NOT run any load generation or telemetry — use 01-run-experiment.sh for that.
#
# Usage:
#   ./00-deploy-boutique.sh               # deploy everything
#   SKIP_HPA=1 ./00-deploy-boutique.sh    # skip HPA setup
#   TEARDOWN=1 ./00-deploy-boutique.sh    # remove all deployed resources
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
CPU_THRESHOLD="${CPU_THRESHOLD:-75}"
SKIP_HPA="${SKIP_HPA:-0}"
TEARDOWN="${TEARDOWN:-0}"

KC="kubectl --kubeconfig ${KUBECONFIG_PATH}"

# ── colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[error]${NC} $*"; exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────
ensure_cluster() {
  $KC get nodes >/dev/null 2>&1 || error "Cannot reach cluster via ${KUBECONFIG_PATH}"
  info "Cluster reachable. Nodes:"
  $KC get nodes -o wide
}

approve_csrs() {
  local pending
  pending=$($KC get csr -o name 2>/dev/null || true)
  if [ -n "${pending}" ]; then
    info "Approving pending CSRs..."
    echo "${pending}" | xargs $KC certificate approve 2>/dev/null || true
  fi
}

ensure_metrics_server() {
  if $KC get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    info "metrics-server already installed."
    return
  fi
  info "Installing metrics-server..."
  $KC apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # CloudLab nodes use self-signed kubelet certs
  $KC patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  $KC wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=180s \
    || warn "metrics-server not yet Available — continuing anyway"
}

deploy_boutique() {
  local manifest="${ROOT_DIR}/online-boutique.yaml"
  [ -f "${manifest}" ] || error "Manifest not found: ${manifest}"

  if $KC get deployment frontend >/dev/null 2>&1; then
    info "Online Boutique already deployed — re-applying to pick up any changes..."
  else
    info "Deploying Online Boutique..."
  fi

  $KC apply -f "${manifest}"

  info "Waiting for all deployments to become Available (up to 10 min)..."
  $KC wait --for=condition=Available deploy --all -n default --timeout=600s \
    || warn "Some deployments not yet Available — check 'kubectl get pods'"

  info "Deleting built-in loadgenerator (not used in our experiments)..."
  $KC delete deployment loadgenerator --ignore-not-found

  info "Online Boutique pods:"
  $KC get pods -n default -o wide
}

setup_hpa() {
  info "Configuring HPA (CPU threshold: ${CPU_THRESHOLD}%)..."
  CPU_THRESHOLD="${CPU_THRESHOLD}" "${ROOT_DIR}/07-setup-hpa.sh"
}

deploy_probers() {
  info "Deploying s2s-prober..."
  $KC apply -f "${ROOT_DIR}/s2s-prober.yaml"
  $KC wait --for=condition=Available deployment/s2s-prober --timeout=120s 2>/dev/null \
    || warn "s2s-prober not yet Available"

  info "Deploying k6 load generator pod (idle until experiment runs)..."
  $KC apply -f "${ROOT_DIR}/k6-loadgen.yaml"

  info "Deploying fortio pod (gRPC probes)..."
  $KC apply -f "${ROOT_DIR}/fortio-loadgen.yaml"
}

teardown() {
  info "Tearing down Online Boutique and supporting pods..."
  $KC delete -f "${ROOT_DIR}/online-boutique.yaml" --ignore-not-found
  $KC delete -f "${ROOT_DIR}/s2s-prober.yaml"      --ignore-not-found
  $KC delete -f "${ROOT_DIR}/k6-loadgen.yaml"      --ignore-not-found
  $KC delete -f "${ROOT_DIR}/fortio-loadgen.yaml"  --ignore-not-found
  $KC delete hpa --all -n default                  --ignore-not-found
  info "Teardown complete."
  exit 0
}

# ── node topology zone labels ─────────────────────────────────────────────────
# topology.kubernetes.io/zone labels are REQUIRED for preferLocalEndpoints to
# ever become true in OVN-Kubernetes. Without them the feature is silently a no-op.
#
# Split: node1+node2+node3 → zone-a   node4+node5 → zone-b
# (3+2 gives each zone ≥1 replica even at MIN_REPLICAS=2, satisfying the
#  proportionality guard: proportionalMin = clusterTotal/2 * 0.5)
ensure_node_zone_labels() {
  # Always re-apply zone labels so this is idempotent on re-runs.
  # node0 (control plane + load generators) intentionally has NO zone label so
  # OVN topology-aware routing falls back to cluster-wide endpoints for it —
  # preventing all k6/fortio traffic from being pinned to one zone's pods.
  # 3-zone layout (derived from traceroute hop counts between nodes):
  #   zone-a: node1, node2   (closest pair)
  #   zone-b: node3, node4   (second hop group)
  #   zone-c: node5          (most distant node)
  # node0 intentionally left unlabeled so load generators get cluster-wide routing.
  info "Assigning topology zones to worker nodes (zone-a: node1–2, zone-b: node3–4, zone-c: node5)..."

  # ── Assign zones to worker nodes ─────────────────────────────────────────────
  local node zone
  while IFS= read -r node; do
    local short="${node%%.*}"
    case "${short}" in
      node1|node2) zone="zone-a" ;;
      node3|node4) zone="zone-b" ;;
      node5)       zone="zone-c" ;;
      *)           zone="zone-a" ;;
    esac
    $KC label node "${node}" topology.kubernetes.io/zone="${zone}" --overwrite
    info "  ${node} → ${zone}"
  done < <($KC get nodes --no-headers -o custom-columns='NAME:.metadata.name' | grep -v "^node0\." | sort)

  # ── Explicitly remove zone label from node0 ────────────────────────────────
  # node0 must be zone-free: if it has a stale zone-a label from a prior run,
  # topology-aware routing would restrict all load-generator traffic to zone-a
  # pods only, halving effective frontend capacity and saturating that zone.
  local node0
  node0=$($KC get nodes --no-headers -o custom-columns='NAME:.metadata.name' | grep "^node0\." | head -1)
  if [ -n "${node0}" ]; then
    local cur_zone
    cur_zone=$($KC get node "${node0}" \
      -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "")
    if [ -n "${cur_zone}" ]; then
      $KC label node "${node0}" topology.kubernetes.io/zone- 2>/dev/null || true
      info "  ${node0} → (zone label removed — will use cluster-wide routing)"
    else
      info "  ${node0} → (no zone label — cluster-wide routing confirmed)"
    fi
  fi

  info "Zone assignment:"
  $KC get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'
}

# ── topo-aware opt-in annotation ─────────────────────────────────────────────
annotate_topo_services() {
  # Only annotate if OVN_ENABLE_TOPOLOGY_AWARE_LB is set to "true" in the
  # ovnkube-master deployment, otherwise strip the annotation so services revert
  # to cluster-wide routing (avoids leftover annotations from a prior topo run).
  local topo_enabled
  topo_enabled=$($KC get deployment ovnkube-master -n ovn-kubernetes \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="ovnkube-master")].env[?(@.name=="OVN_ENABLE_TOPOLOGY_AWARE_LB")].value}' \
    2>/dev/null || echo "false")

  local svcs=(frontend productcatalogservice cartservice checkoutservice
              currencyservice recommendationservice paymentservice
              shippingservice emailservice adservice)

  if [[ "${topo_enabled}" == "true" ]]; then
    info "Topology-aware LB enabled — annotating services with topology-mode: Auto..."
    for svc in "${svcs[@]}"; do
      $KC annotate service "${svc}" \
        service.kubernetes.io/topology-mode=Auto \
        --overwrite 2>/dev/null || true
    done
  else
    info "Topology-aware LB not enabled — removing topology-mode annotation from services (if present)..."
    for svc in "${svcs[@]}"; do
      $KC annotate service "${svc}" \
        service.kubernetes.io/topology-mode- \
        2>/dev/null || true
    done
  fi

  info "Service topology annotations:"
  $KC get services -o custom-columns='NAME:.metadata.name,TOPO:.metadata.annotations.service\.kubernetes\.io/topology-mode'
}

# ── main ─────────────────────────────────────────────────────────────────────
echo "========================================"
echo " Online Boutique Deployer"
echo "========================================"
echo " KUBECONFIG : ${KUBECONFIG_PATH}"
echo " CPU_THRESHOLD: ${CPU_THRESHOLD}%"
echo " SKIP_HPA   : ${SKIP_HPA}"
echo " TEARDOWN   : ${TEARDOWN}"
echo "========================================"

[[ "${TEARDOWN}" == "1" ]] && teardown

ensure_cluster
approve_csrs
ensure_node_zone_labels
ensure_metrics_server
deploy_boutique

[[ "${SKIP_HPA}" != "1" ]] && setup_hpa

deploy_probers
annotate_topo_services

echo ""
info "Deployment complete."
echo ""
echo "  Frontend:  http://$($KC get svc frontend -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo '<pending>')"
echo ""
echo "Next steps:"
echo "  Run experiment : MODE=traffic ./01-run-experiment.sh"
echo "  Full run       : MODE=full    ./01-run-experiment.sh"
echo "  Teardown       : TEARDOWN=1   ./00-deploy-boutique.sh"
