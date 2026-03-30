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

# ── topo-aware opt-in annotation ─────────────────────────────────────────────
annotate_topo_services() {
  # Only annotate if OVN_ENABLE_TOPOLOGY_AWARE_LB is set to "true" in the
  # ovnkube-master deployment, otherwise this is a no-op.
  local topo_enabled
  topo_enabled=$($KC get deployment ovnkube-master -n ovn-kubernetes \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="ovnkube-master")].env[?(@.name=="OVN_ENABLE_TOPOLOGY_AWARE_LB")].value}' \
    2>/dev/null || echo "false")

  if [[ "${topo_enabled}" == "true" ]]; then
    info "Topology-aware LB is enabled — annotating services with topology-mode: Auto..."
    for svc in frontend productcatalogservice cartservice checkoutservice \
               currencyservice recommendationservice paymentservice \
               shippingservice emailservice adservice; do
      $KC annotate service "${svc}" \
        service.kubernetes.io/topology-mode=Auto \
        --overwrite 2>/dev/null || true
    done
    info "Service annotations applied:"
    $KC get services -o custom-columns='NAME:.metadata.name,TOPO:.metadata.annotations.service\.kubernetes\.io/topology-mode'
  else
    info "Topology-aware LB not enabled (OVN_ENABLE_TOPOLOGY_AWARE_LB != true) — skipping service annotations."
  fi
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
