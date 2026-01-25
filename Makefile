# LLM Zero-Downtime Update - Makefile
#
# Targets for cluster management and rollout operations.

SHELL := /bin/bash
.DEFAULT_GOAL := help

NAMESPACE := llm-serving
SCRIPTS_DIR := scripts

# Load test settings (override with: make load LOAD_CONCURRENCY=8)
LOAD_URL ?= http://localhost:8000
LOAD_CONCURRENCY ?= 4
LOAD_DURATION ?= 30
LOAD_MAX_TOKENS ?= 100

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
	@$(SCRIPTS_DIR)/deploy.sh up

.PHONY: down
down: ## Remove the LLM serving stack
	@$(SCRIPTS_DIR)/deploy.sh down

.PHONY: logs
logs: ## Tail logs for serving pods
	kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=vllm-serving -f --tail=100

.PHONY: port-forward
port-forward: ## Port-forward stable service to localhost:8000
	@echo "Forwarding vllm-stable:8000 -> localhost:8000"
	@echo "Press Ctrl+C to stop"
	kubectl port-forward -n $(NAMESPACE) svc/vllm-stable 8000:8000

.PHONY: port-forward-preview
port-forward-preview: ## Port-forward preview service to localhost:8001
	@echo "Forwarding vllm-preview:8000 -> localhost:8001"
	@echo "Press Ctrl+C to stop"
	kubectl port-forward -n $(NAMESPACE) svc/vllm-preview 8001:8000

# ==============================================================================
# Load Testing
# ==============================================================================

.PHONY: smoke
smoke: ## Run smoke tests (health, non-streaming, streaming)
	@$(SCRIPTS_DIR)/smoke_test.sh $(LOAD_URL)

.PHONY: load
load: ## Run streaming load test
	@python3 load/stream_load.py \
		--url $(LOAD_URL) \
		--concurrency $(LOAD_CONCURRENCY) \
		--duration $(LOAD_DURATION) \
		--max-tokens $(LOAD_MAX_TOKENS) \
		--prompts-file load/scenarios/short_prompts.txt \
		--output /tmp/stream_load_results.json

.PHONY: verify
verify: ## Run no-downtime verification
	@$(SCRIPTS_DIR)/verify_no_downtime.sh $(LOAD_URL)

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