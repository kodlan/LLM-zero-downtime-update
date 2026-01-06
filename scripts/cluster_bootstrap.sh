#!/usr/bin/env bash
#
# cluster_bootstrap.sh - Bootstrap cluster with required components
#
# Installs:
#   1. NVIDIA device plugin (DaemonSet)
#   2. Argo Rollouts controller
#   3. Project namespace (llm-serving)
#
# Usage:
#   ./scripts/cluster_bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# Pre-flight checks
# ------------------------------------------------------------------------------
echo "============================================"
echo "Cluster Bootstrap for LLM Zero-Downtime"
echo "============================================"
echo ""

log_info "Checking kubectl connectivity..."
if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to cluster. Please configure kubectl first."
    exit 1
fi
CONTEXT=$(kubectl config current-context)
log_info "Connected to cluster: $CONTEXT"

# ------------------------------------------------------------------------------
# Step 1: Install NVIDIA device plugin
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 1: Installing NVIDIA device plugin..."

NVIDIA_PLUGIN_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml"

if kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system &>/dev/null; then
    log_warn "NVIDIA device plugin already installed. Skipping."
else
    log_info "Applying NVIDIA device plugin DaemonSet..."
    echo "  Command: kubectl apply -f $NVIDIA_PLUGIN_URL"
    kubectl apply -f "$NVIDIA_PLUGIN_URL"

    log_info "Waiting for NVIDIA device plugin to be ready..."
    kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --timeout=120s
    log_info "NVIDIA device plugin installed successfully."
fi

# ------------------------------------------------------------------------------
# Step 2: Install Argo Rollouts controller
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 2: Installing Argo Rollouts controller..."

ARGO_ROLLOUTS_VERSION="v1.7.2"
ARGO_ROLLOUTS_URL="https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml"

if kubectl get namespace argo-rollouts &>/dev/null; then
    log_warn "Argo Rollouts namespace exists. Checking controller status..."
    if kubectl get deployment argo-rollouts -n argo-rollouts &>/dev/null; then
        log_warn "Argo Rollouts controller already installed. Skipping."
    else
        log_info "Installing Argo Rollouts controller..."
        kubectl apply -n argo-rollouts -f "$ARGO_ROLLOUTS_URL"
    fi
else
    log_info "Creating argo-rollouts namespace and installing controller..."
    kubectl create namespace argo-rollouts
    echo "  Command: kubectl apply -n argo-rollouts -f $ARGO_ROLLOUTS_URL"
    kubectl apply -n argo-rollouts -f "$ARGO_ROLLOUTS_URL"
fi

log_info "Waiting for Argo Rollouts controller to be ready..."
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=120s
log_info "Argo Rollouts controller installed successfully."

# ------------------------------------------------------------------------------
# Step 3: Create project namespace
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 3: Creating project namespace..."

NAMESPACE_YAML="$PROJECT_ROOT/k8s/base/namespace.yaml"

if kubectl get namespace llm-serving &>/dev/null; then
    log_warn "Namespace 'llm-serving' already exists. Skipping."
else
    log_info "Creating namespace from $NAMESPACE_YAML..."
    echo "  Command: kubectl apply -f $NAMESPACE_YAML"
    kubectl apply -f "$NAMESPACE_YAML"
    log_info "Namespace 'llm-serving' created."
fi

# ------------------------------------------------------------------------------
# Step 4: Verify installation
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 4: Running verification..."
echo ""

"$SCRIPT_DIR/verify_cluster.sh"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "============================================"
echo "Bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Run 'make status' to view cluster state"
echo "============================================"