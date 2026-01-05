# Cluster Setup Guide (Ubuntu + Minikube + GPU)

This guide covers setting up a local Kubernetes cluster with GPU support for the zero-downtime LLM serving project.

## Prerequisites

### 1. NVIDIA Driver
Verify your NVIDIA driver is installed:
```bash
nvidia-smi
```
You should see your GPU listed. If not, install the driver:
```bash
sudo apt update
sudo apt install nvidia-driver-580  # or latest stable version
sudo reboot
```

### 2. NVIDIA Container Toolkit
Install the container toolkit so containers can access the GPU:
```bash
# Add the repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Install
sudo apt update
sudo apt install -y nvidia-container-toolkit

# Configure Docker to use NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify Docker can access the GPU:
```bash
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

## Install Minikube

```bash
# Download minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64

# Install
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm minikube-linux-amd64

# Verify
minikube version
```

## Start Minikube with GPU Support

```bash
minikube start --driver=docker --gpus=all
```

This starts a single-node cluster with GPU passthrough enabled.

### Verify GPU is Visible to the Cluster

After starting minikube, check that the node sees the GPU:
```bash
kubectl get nodes -o json | jq '.items[].status.capacity'
```

At this point you may not see `nvidia.com/gpu` yet — that requires the NVIDIA device plugin (installed via `make bootstrap`).

## Next Steps

Once minikube is running, bootstrap the cluster components:
```bash
make bootstrap
```

This will install:
- NVIDIA device plugin (exposes GPUs to Kubernetes)
- Argo Rollouts controller
- Project namespace (`llm-serving`)
