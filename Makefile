# LLM Zero-Downtime Update - Makefile
#
# Targets for cluster management and rollout operations.

SHELL := /bin/bash
.DEFAULT_GOAL := help

NAMESPACE := llm-serving
SCRIPTS_DIR := scripts

# ==============================================================================
# Cluster Bootstrap
# ==============================================================================

.PHONY: bootstrap
bootstrap: ## Bootstrap cluster: install NVIDIA plugin, Argo Rollouts, create namespace
	@$(SCRIPTS_DIR)/cluster_bootstrap.sh

.PHONY: verify-cluster
verify-cluster: ## Verify cluster is ready (GPU, Argo Rollouts, namespace)
	@$(SCRIPTS_DIR)/verify_cluster.sh

.PHONY: status
status: ## Show cluster status: nodes, GPU, pods, rollouts
	@echo "============================================"
	@echo "Cluster Status"
	@echo "============================================"
	@echo ""
	@echo ">> Nodes:"
	@kubectl get nodes -o wide
	@echo ""
	@echo ">> GPU Allocatable:"
	@kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name): \(.status.allocatable["nvidia.com/gpu"] // "none") GPU(s)"'
	@echo ""
	@echo ">> Argo Rollouts Controller:"
	@kubectl get pods -n argo-rollouts -l app.kubernetes.io/name=argo-rollouts 2>/dev/null || echo "  Not installed"
	@echo ""
	@echo ">> Namespace $(NAMESPACE):"
	@kubectl get pods -n $(NAMESPACE) 2>/dev/null || echo "  No pods yet"
	@echo ""
	@echo ">> Rollouts in $(NAMESPACE):"
	@kubectl get rollouts -n $(NAMESPACE) 2>/dev/null || echo "  No rollouts yet"

# ==============================================================================
# Deploy
# ==============================================================================

.PHONY: up
up: ## Deploy the LLM serving stack
	@echo "TODO"

.PHONY: down
down: ## Remove the LLM serving stack
	@echo "TODO"

.PHONY: logs
logs: ## Tail logs for serving pods
	@echo "TODO"

# ==============================================================================
# Load Testing
# ==============================================================================

.PHONY: load
load: ## Run streaming load test
	@echo "TODO"

.PHONY: verify
verify: ## Run no-downtime verification
	@echo "TODO"

# ==============================================================================
# Rollout Operations
# ==============================================================================

.PHONY: update
update: ## Trigger rollout to new version
	@echo "TODO"

.PHONY: warmup
warmup: ## Warm up preview revision
	@echo "TODO"

.PHONY: promote
promote: ## Promote preview to stable
	@echo "TODO"

.PHONY: rollback
rollback: ## Abort and rollback to previous revision
	@echo "TODO"

# ==============================================================================
# Help
# ==============================================================================

.PHONY: help
help: ## Show this help message
	@echo "LLM Zero-Downtime Update"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  %-15s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)