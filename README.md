# LLM Zero-Downtime Update

A Kubernetes reference implementation for **zero-downtime model updates** in an LLM serving stack. Uses [vLLM](https://github.com/vllm-project/vllm) as the inference engine and [Argo Rollouts](https://argoproj.github.io/rollouts/) for blue/green deployments, ensuring in-flight streaming requests drain gracefully and new revisions are warmed before receiving production traffic.

Designed to run on a single consumer GPU (e.g., RTX 2070) with small models (~0.5-1B params).

## How it works

The stack runs vLLM behind two Kubernetes Services managed by Argo Rollouts:

- **Stable Service** (`vllm-stable`) — carries production traffic
- **Preview Service** (`vllm-preview`) — receives the new revision for validation before promotion

When a model update is triggered, Argo Rollouts creates a new ReplicaSet behind the preview Service. After warmup and validation, the stable Service selector is switched to the new ReplicaSet. The old pods are kept alive with a `preStop` sleep hook so in-flight streaming requests can drain before termination.

Key mechanisms:
- **startupProbe** — allows up to ~10 minutes for model download and loading without killing the pod
- **readinessProbe** — gates traffic until vLLM is actually serving
- **preStop hook** — delays SIGTERM by 60s so active streams finish
- **terminationGracePeriodSeconds** (90s) — total budget for drain + shutdown

## Cluster Setup

See [docs/ClusterSetup.md](docs/ClusterSetup.md) for prerequisites (NVIDIA driver, container toolkit, Minikube with GPU support).

Once Minikube is running, bootstrap the cluster:

```bash
make bootstrap        # Install NVIDIA device plugin, Argo Rollouts, create namespace
make verify-cluster   # Verify GPU, Argo Rollouts, and namespace are ready
make status           # Check overall cluster status
```

## Deploy and Run

```bash
make up               # Deploy the vLLM serving stack
make port-forward     # Forward stable service to localhost:8000
make smoke            # Run smoke tests (health, completion, streaming)
make load             # Run streaming load test (4 workers, 30s)
make verify           # Full no-downtime verification suite
make logs             # Tail serving pod logs
make down             # Remove the stack
```

Load test parameters are configurable:
```bash
make load LOAD_CONCURRENCY=8 LOAD_DURATION=60
```

## Scripts

| Script | Purpose |
|---|---|
| `scripts/cluster_bootstrap.sh` | Installs NVIDIA device plugin, Argo Rollouts controller, creates `llm-serving` namespace |
| `scripts/verify_cluster.sh` | Pre-flight checks: kubectl connectivity, GPU visibility, Argo controller running |
| `scripts/deploy.sh` | Deploys (`up`) or removes (`down`) the vLLM stack in dependency order, waits for rollout healthy |
| `scripts/smoke_test.sh` | Three quick checks: health endpoint, non-streaming completion, streaming completion |
| `scripts/verify_no_downtime.sh` | Runs smoke tests + streaming load, then asserts acceptance criteria (error rate, 5xx rate, stream completion) |

## Testing

### Smoke tests (`make smoke`)

Quick validation that vLLM is serving correctly:
1. `GET /health` returns 200
2. Non-streaming `POST /v1/completions` returns valid text
3. Streaming `POST /v1/completions` receives SSE chunks and `[DONE]`

### Streaming load test (`make load`)

Sends concurrent streaming completion requests using `load/stream_load.py`. Measures:
- **TTFT** (time to first token) p50/p95
- **Tokens/sec** aggregate throughput
- **Error rate** and HTTP status code distribution
- **Stream completion rate** — fraction of requests that received a complete response

Results are printed to stdout and saved to `/tmp/stream_load_results.json`.

### No-downtime verification (`make verify`)

Runs the full verification suite:
1. Pre-flight health check
2. Smoke tests
3. Streaming load test
4. Asserts acceptance criteria:
   - Error rate <= 5%
   - 5xx rate <= 2%
   - Stream completion >= 90%

Thresholds are configurable via environment variables (`MAX_ERROR_RATE`, `MAX_5XX_RATE`, `MIN_STREAM_COMPLETION`).

## Project Layout

```
k8s/base/               Kubernetes manifests (namespace, configmap, services, rollout)
scripts/                 Cluster and deployment scripts
load/                    Load generator and test scenarios
  stream_load.py         Streaming load generator (Python)
  scenarios/             Prompt files for load tests
docs/                    Architecture and setup documentation
```
