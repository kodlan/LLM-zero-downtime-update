# LLM Zero-Downtime Update

A Kubernetes reference implementation for **zero-downtime model updates** in an LLM serving stack. Uses [vLLM](https://github.com/vllm-project/vllm) as the inference engine and [Argo Rollouts](https://argoproj.github.io/rollouts/) for blue/green deployments, ensuring in-flight streaming requests drain gracefully and new revisions are warmed before receiving production traffic.

Designed to run on a single consumer GPU (e.g., RTX 2070) with small models (~0.5-1B params).

## Cluster Setup

See [docs/ClusterSetup.md](docs/ClusterSetup.md) for prerequisites (NVIDIA driver, container toolkit, Minikube with GPU support).

Once Minikube is running, bootstrap the cluster:

```bash
# Install NVIDIA device plugin, Argo Rollouts controller, and create namespace
make bootstrap

# Verify GPU, Argo Rollouts, and namespace are ready
make verify-cluster

# Check overall cluster status
make status
```

## Usage

```bash
make up              # Deploy the LLM serving stack
make load            # Run streaming load test
make update          # Trigger rollout to new version
make warmup          # Warm up preview revision
make promote         # Promote preview to stable
make rollback        # Abort and rollback
make verify          # Run no-downtime verification
make logs            # Tail serving pod logs
make down            # Remove the stack
```
