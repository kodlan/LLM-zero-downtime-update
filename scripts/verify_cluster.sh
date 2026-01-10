#!/usr/bin/env bash
#
# verify_cluster.sh - Verify cluster is ready for LLM serving workloads
#
# Checks:
#   1. kubectl connectivity
#   2. GPU allocatable on node (nvidia.com/gpu)
#   3. Argo Rollouts controller running
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED=0

print_status() {
    local status=$1
    local message=$2
    if [[ "$status" == "ok" ]]; then
        echo -e "${GREEN}[OK]${NC} $message"
    elif [[ "$status" == "fail" ]]; then
        echo -e "${RED}[FAIL]${NC} $message"
        FAILED=1
    elif [[ "$status" == "warn" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $message"
    else
        echo "[INFO] $message"
    fi
}

echo "============================================"
echo "Cluster Verification for LLM Zero-Downtime"
echo "============================================"
echo ""

# ------------------------------------------------------------------------------
# Check 1: kubectl connectivity
# ------------------------------------------------------------------------------
echo ">> Checking kubectl connectivity..."
if kubectl cluster-info &>/dev/null; then
    CONTEXT=$(kubectl config current-context)
    print_status "ok" "Connected to cluster (context: $CONTEXT)"
else
    print_status "fail" "Cannot connect to cluster. Is kubectl configured?"
    exit 1
fi

# ------------------------------------------------------------------------------
# Check 2: GPU allocatable
# ------------------------------------------------------------------------------
echo ""
echo ">> Checking GPU availability..."
GPU_COUNT=$(kubectl get nodes -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"] // "0" | tonumber] | add')

if [[ "$GPU_COUNT" -gt 0 ]]; then
    print_status "ok" "GPU available: $GPU_COUNT nvidia.com/gpu allocatable"
else
    print_status "fail" "No GPU found. Is the NVIDIA device plugin installed?"
fi

# ------------------------------------------------------------------------------
# Check 3: Argo Rollouts controller
# ------------------------------------------------------------------------------
echo ""
echo ">> Checking Argo Rollouts controller..."
ARGO_NS="argo-rollouts"

if kubectl get namespace "$ARGO_NS" &>/dev/null; then
    ARGO_PODS=$(kubectl get pods -n "$ARGO_NS" -l app.kubernetes.io/name=argo-rollouts -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")

    if [[ "$ARGO_PODS" == *"Running"* ]]; then
        ARGO_VERSION=$(kubectl get pods -n "$ARGO_NS" -l app.kubernetes.io/name=argo-rollouts -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null | cut -d: -f2)
        print_status "ok" "Argo Rollouts controller running (version: ${ARGO_VERSION:-unknown})"
    else
        print_status "fail" "Argo Rollouts controller not running"
    fi
else
    print_status "fail" "Argo Rollouts namespace not found. Run 'make bootstrap' first."
fi

# ------------------------------------------------------------------------------
# Check 4: Project namespace (optional, informational)
# ------------------------------------------------------------------------------
echo ""
echo ">> Checking project namespace..."
if kubectl get namespace llm-serving &>/dev/null; then
    print_status "ok" "Namespace 'llm-serving' exists"
else
    print_status "warn" "Namespace 'llm-serving' not found. Will be created by bootstrap."
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "============================================"
if [[ "$FAILED" -eq 0 ]]; then
    print_status "ok" "All checks passed. Cluster is ready."
    exit 0
else
    print_status "fail" "Some checks failed. See above for details."
    exit 1
fi
