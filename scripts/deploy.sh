#!/usr/bin/env bash
#
# deploy.sh - Deploy or remove the LLM serving stack
#
# Usage:
#   ./scripts/deploy.sh up     # Deploy stack
#   ./scripts/deploy.sh down   # Remove stack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_BASE="$PROJECT_ROOT/k8s/base"
NAMESPACE="llm-serving"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

ACTION="${1:-}"

case "$ACTION" in
  up)
    echo "============================================"
    echo "Deploying LLM Serving Stack"
    echo "============================================"
    echo ""

    # Pre-flight: verify cluster is ready
    log_info "Running cluster verification..."
    "$SCRIPT_DIR/verify_cluster.sh"
    echo ""

    # Apply manifests in dependency order
    log_info "Applying namespace..."
    echo "  Command: kubectl apply -f $K8S_BASE/namespace.yaml"
    kubectl apply -f "$K8S_BASE/namespace.yaml"

    log_info "Applying ConfigMap..."
    echo "  Command: kubectl apply -f $K8S_BASE/configmap.yaml"
    kubectl apply -f "$K8S_BASE/configmap.yaml"

    log_info "Applying Services (stable + preview)..."
    echo "  Command: kubectl apply -f $K8S_BASE/services.yaml"
    kubectl apply -f "$K8S_BASE/services.yaml"

    log_info "Applying vLLM Rollout..."
    echo "  Command: kubectl apply -f $K8S_BASE/vllm-rollout.yaml"
    kubectl apply -f "$K8S_BASE/vllm-rollout.yaml"

    # Wait for rollout to become healthy (up to ~10 min for first-time model download)
    log_info "Waiting for Rollout to become healthy..."
    echo "  (First run may take several minutes for model download + loading)"
    MAX_ATTEMPTS=120
    for i in $(seq 1 $MAX_ATTEMPTS); do
      PHASE=$(kubectl get rollout vllm-serving -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      POD_STATUS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vllm-serving \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
      READY=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=vllm-serving \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
      if [[ "$PHASE" == "Healthy" ]]; then
        log_info "Rollout is Healthy."
        break
      fi
      if [[ "$i" -eq "$MAX_ATTEMPTS" ]]; then
        log_error "Rollout did not become healthy within timeout."
        log_error "Check pod status: kubectl get pods -n $NAMESPACE"
        log_error "Check pod logs:   kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=vllm-serving"
        exit 1
      fi
      echo "  Rollout: $PHASE | Pod: $POD_STATUS | Ready: $READY (attempt $i/$MAX_ATTEMPTS)"
      sleep 5
    done

    echo ""
    log_info "Deployment complete. Current state:"
    echo ""
    kubectl get rollout -n "$NAMESPACE"
    echo ""
    kubectl get pods -n "$NAMESPACE"
    echo ""
    kubectl get svc -n "$NAMESPACE"

    echo ""
    echo "============================================"
    echo "Stack deployed. Test with:"
    echo "  make port-forward"
    echo "  curl http://localhost:8000/health"
    echo "============================================"
    ;;

  down)
    echo "============================================"
    echo "Removing LLM Serving Stack"
    echo "============================================"
    echo ""

    log_info "Deleting Rollout..."
    kubectl delete rollout vllm-serving -n "$NAMESPACE" --ignore-not-found
    log_info "Deleting Services..."
    kubectl delete -f "$K8S_BASE/services.yaml" --ignore-not-found
    log_info "Deleting ConfigMap..."
    kubectl delete -f "$K8S_BASE/configmap.yaml" --ignore-not-found

    log_warn "Namespace '$NAMESPACE' preserved (managed by cluster bootstrap)."

    echo ""
    log_info "Stack removed."
    ;;

  *)
    echo "Usage: $0 {up|down}"
    exit 1
    ;;
esac
