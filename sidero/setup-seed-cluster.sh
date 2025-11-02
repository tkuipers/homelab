#!/bin/bash

# A script to fully prepare a seed server with k3s and Sidero Metal using clusterctl.
# This script is designed to be idempotent.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Install k3s (Lightweight Kubernetes) ---
echo "--- 1. Checking for k3s (Lightweight Kubernetes) ---"
if ! command -v k3s &> /dev/null
then
    echo "k3s not found. Please install it with 'curl -sfL https://get.k3s.io | sh -' and re-run this script."
    exit 1
else
    echo "k3s is already installed."
fi

echo "Verifying Kubernetes node status..."
if ! sudo kubectl get nodes | grep -q "Ready"; then
    echo "Error: k3s node is not ready. Please check the k3s service logs with 'sudo journalctl -u k3s'."
    exit 1
fi
echo "Kubernetes cluster is ready."
echo ""


# --- 2. Install clusterctl ---
echo "--- 2. Installing clusterctl (Cluster API controller) ---"
if ! command -v clusterctl &> /dev/null
then
    echo "clusterctl not found. Installing..."
    ARCH=$(dpkg --print-architecture)
    CLUSTERCTL_VERSION="v1.7.2" # A recent, stable version of clusterctl
    curl -L "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-linux-${ARCH}" -o clusterctl
    sudo install -o root -g root -m 0755 clusterctl /usr/local/bin/clusterctl
    rm clusterctl
    echo "clusterctl installed successfully."
else
    echo "clusterctl is already installed. Skipping installation."
fi
echo ""


# --- 3. Initialize Cluster API and Sidero Provider ---
echo "--- 3. Initializing Cluster API with the Sidero provider ---"

# Export the KUBECONFIG path so clusterctl and other tools can find the cluster.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
if [ ! -f "$KUBECONFIG" ]; then
    echo "Error: k3s kubeconfig not found at $KUBECONFIG"
    exit 1
fi
echo "Using kubeconfig from $KUBECONFIG"


# These environment variables configure the Sidero installation for a single-node seed cluster.
# We are telling it to use the host's network directly.

# Discover the primary IP of the host machine.
export NODE_IP="10.0.0.2"
echo "Using primary node IP: ${NODE_IP}"

# Run Sidero on the host network to expose its services (DHCP, TFTP, etc.)
export SIDERO_CONTROLLER_MANAGER_HOST_NETWORK=true
# Use the "Recreate" strategy, which is safer for a single-node cluster with host networking.
export SIDERO_CONTROLLER_MANAGER_DEPLOYMENT_STRATEGY=Recreate
# Tell Sidero what IP address clients should use to reach it.
export SIDERO_CONTROLLER_MANAGER_API_ENDPOINT=$NODE_IP
export SIDERO_CONTROLLER_MANAGER_SIDEROLINK_ENDPOINT=$NODE_IP
# Disable Sidero's DHCP proxy since dnsmasq is handling it.
export SIDERO_CONTROLLER_MANAGER_DISABLE_DHCP_PROXY=true

# clusterctl will automatically handle the cert-manager dependency.
clusterctl init -b talos -c talos -i sidero

echo "Waiting for all Cluster API and Sidero deployments to become available..."
# This can take a few minutes as container images are pulled.
kubectl wait --for=condition=Available -n cert-manager deployment/cert-manager-webhook --timeout=5m
kubectl wait --for=condition=Available -n capi-system deployment/capi-controller-manager --timeout=5m
kubectl wait --for=condition=Available -n sidero-system deployment/sidero-controller-manager --timeout=5m


# --- 4. Applying Local Sidero Manifests ---
echo "--- 4. Applying Local Sidero Manifests ---"
echo "Applying serverclass-controlplane.yaml..."
kubectl apply -f sidero/serverclass-controlplane.yaml
echo "Applying serverclass-worker.yaml..."
kubectl apply -f sidero/serverclass-worker.yaml
echo "Applying servers.yaml..."
kubectl apply -f sidero/servers.yaml

# --- 5. Apply the Cluster Manifest ---
# This manifest defines the desired state of the workload cluster.
# It was generated once and is now tracked in the repository.
echo "--- 5. Apply the Cluster Manifest ---"
echo "Applying the cluster manifest (sidero/talos-homelab.yaml)..."
kubectl apply -f sidero/talos-homelab.yaml

# --- 6. Wait for Cluster to be Ready ---
echo "--- 6. Waiting for workload cluster to become ready ---"
echo "This may take several minutes..."
kubectl wait --for=condition=Ready -n default cluster/talos-homelab --timeout=1h


# --- 7. Generate and Store Cluster Configs ---
echo "--- 7. Generating and storing cluster configs ---"

# Create cluster configs directory if it doesn't exist
mkdir -p cluster-configs

# Generate talosconfig for the workload cluster
echo "Generating talosconfig for workload cluster..."
kubectl get secret -n default talos-homelab-talosconfig -o jsonpath='{.data.talosconfig}' | base64 -d > cluster-configs/talosconfig

# Generate kubeconfig for the workload cluster  
echo "Generating kubeconfig for workload cluster..."
CONTROL_PLANE_IP="10.0.0.50"
echo "Using control plane IP: $CONTROL_PLANE_IP"

# Generate kubeconfig using talosctl
talosctl --talosconfig cluster-configs/talosconfig kubeconfig --nodes $CONTROL_PLANE_IP cluster-configs/ --force

echo ""
echo "=== Setup Complete ==="
echo "Workload cluster configs stored in: ./cluster-configs/"
echo "- talosconfig: ./cluster-configs/talosconfig"  
echo "- kubeconfig: ./cluster-configs/kubeconfig"
echo ""
echo "To use the workload cluster:"
echo "  export KUBECONFIG=./cluster-configs/kubeconfig"
echo "  kubectl get nodes"
