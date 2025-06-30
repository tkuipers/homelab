#!/bin/bash

# A script to fully prepare a seed server with k3s and Sidero Metal using clusterctl.
# This script is designed to be idempotent.

# Exit immediately if a command exits with a non-zero status.
set -e

# # # --- 1. Install k3s (Lightweight Kubernetes) ---
# # echo "--- 1. Checking for k3s (Lightweight Kubernetes) ---"
# # if ! command -v k3s &> /dev/null
# # then
# #     echo "k3s not found. Please install it with 'curl -sfL https://get.k3s.io | sh -' and re-run this script."
# #     exit 1
# # else
# #     echo "k3s is already installed."
# # fi

# # echo "Verifying Kubernetes node status..."
# # if ! sudo kubectl get nodes | grep -q "Ready"; then
# #     echo "Error: k3s node is not ready. Please check the k3s service logs with 'sudo journalctl -u k3s'."
# #     exit 1
# # fi
# # echo "Kubernetes cluster is ready."
# # echo ""


# # --- 2. Install clusterctl ---
# echo "--- 2. Installing clusterctl (Cluster API controller) ---"
# if ! command -v clusterctl &> /dev/null
# then
#     echo "clusterctl not found. Installing..."
#     ARCH=$(dpkg --print-architecture)
#     CLUSTERCTL_VERSION="v1.7.2" # A recent, stable version of clusterctl
#     curl -L "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-linux-${ARCH}" -o clusterctl
#     sudo install -o root -g root -m 0755 clusterctl /usr/local/bin/clusterctl
#     rm clusterctl
#     echo "clusterctl installed successfully."
# else
#     echo "clusterctl is already installed. Skipping installation."
# fi
# echo ""


# # # --- 3. Initialize Cluster API and Sidero Provider ---
# # echo "--- 3. Initializing Cluster API with the Sidero provider ---"

# # Export the KUBECONFIG path so clusterctl and other tools can find the cluster.
# # export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# # if [ ! -f "$KUBECONFIG" ]; then
# #     echo "Error: k3s kubeconfig not found at $KUBECONFIG"
# #     exit 1
# # fi
# # echo "Using kubeconfig from $KUBECONFIG"


# # These environment variables configure the Sidero installation for a single-node seed cluster.
# # We are telling it to use the host's network directly.

# # Discover the primary IP of the host machine.
# export NODE_IP="172.16.0.2"
# echo "Using primary node IP: ${NODE_IP}"

# # Run Sidero on the host network to expose its services (DHCP, TFTP, etc.)
# export SIDERO_CONTROLLER_MANAGER_HOST_NETWORK=true
# # Use the "Recreate" strategy, which is safer for a single-node cluster with host networking.
# export SIDERO_CONTROLLER_MANAGER_DEPLOYMENT_STRATEGY=Recreate
# # Tell Sidero what IP address clients should use to reach it.
# export SIDERO_CONTROLLER_MANAGER_API_ENDPOINT=$NODE_IP
# export SIDERO_CONTROLLER_MANAGER_SIDEROLINK_ENDPOINT=$NODE_IP
# # Disable Sidero's DHCP proxy since dnsmasq is handling it.
# export SIDERO_CONTROLLER_MANAGER_DISABLE_DHCP_PROXY=true

# # clusterctl will automatically handle the cert-manager dependency.
# clusterctl init -b talos -c talos -i sidero

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
CONTROL_PLANE_IP="172.16.0.50"
echo "Using control plane IP: $CONTROL_PLANE_IP"

# Generate kubeconfig using talosctl
talosctl --talosconfig cluster-configs/talosconfig kubeconfig --nodes $CONTROL_PLANE_IP cluster-configs/ --force

# --- 8. Setup 1Password Integration ---
echo "--- 8. Setting up 1Password integration ---"

# This section sets up 1Password Connect integration for GitOps secret management.
# 
# REQUIRED SECRETS IN 1PASSWORD "Homelab" VAULT:
# ================================================
# 
# 1. SSH Key for Git Repository Access (for FluxCD):
#    - Title: "Homelab Git SSH Key"
#    - Type: SSH Key
#    - Private Key: Your SSH private key content
#    - Public Key: Your SSH public key content
#    - Used by: FluxCD for pulling from private Git repositories
#
# 2. Additional secrets you may want to store:
#    - Database credentials
#    - API tokens
#    - TLS certificates
#    - Application secrets
#
# The External Secrets Operator will sync these secrets from 1Password
# into Kubernetes secrets that your applications can use.
#
# TO ADD SSH KEY TO VAULT (run these commands after signing in):
# ============================================================
# 1. Generate SSH key if you don't have one:
#    ssh-keygen -t ed25519 -C "homelab-flux" -f ~/.ssh/homelab-flux
# 
# 2. Add SSH key to 1Password Homelab vault:
#    op item create --category="SSH Key" --title="Homelab Git SSH Key" \
#      --vault="Homelab" \
#      private_key[password]=~/.ssh/homelab-flux \
#      public_key[text]=~/.ssh/homelab-flux.pub
#
# 3. Add the public key to your Git repository's deploy keys or your user's SSH keys

# Check if 1Password CLI is installed
if ! command -v op &> /dev/null; then
    echo "1Password CLI not found. Installing..."
    # Download and install 1Password CLI using the correct URL format
    curl -sSfL https://cache.agilebits.com/dist/1P/op2/pkg/v2.25.0/op_linux_amd64_v2.25.0.zip -o op.zip
    unzip -q op.zip
    sudo mv op /usr/local/bin/
    rm -f op.zip
    echo "1Password CLI installed successfully."
fi

if command -v op &> /dev/null; then
    echo "1Password CLI found. Setting up integration..."
    
    # Check if already signed in by checking if account list has content
    if [ -z "$(op account list)" ]; then
        echo "No 1Password account configured. Let's add one..."
        echo "Please enter your 1Password sign-in address (e.g., my.1password.com):"
        read -r SIGNIN_ADDRESS
        echo "Adding 1Password account..."
        op account add --address "$SIGNIN_ADDRESS"
        echo "Now signing in..."
        eval $(op signin)
    fi
    
    # Verify access to the Homelab vault (assumes it exists)
    if ! op vault get "Homelab" &> /dev/null; then
        echo "Error: Cannot access 'Homelab' vault in 1Password."
        echo "Please ensure the 'Homelab' vault exists in your account."
        echo "Skipping 1Password integration..."
    else
        echo "Successfully verified access to 'Homelab' vault."
        
        # Create a Connect token for the homelab cluster (assumes Connect server exists)
        echo "Creating 1Password Connect token for homelab cluster..."
        OP_CONNECT_TOKEN=$(op connect token create "Homelab Cluster - $(date '+%Y-%m-%d %H:%M:%S')" --server "homelab" --vault "Homelab")
        
        # Store the token in the workload cluster
        echo "Storing 1Password Connect token in workload cluster..."
        kubectl --kubeconfig cluster-configs/kubeconfig create namespace external-secrets-system --dry-run=client -o yaml | kubectl --kubeconfig cluster-configs/kubeconfig apply -f -
        
        kubectl --kubeconfig cluster-configs/kubeconfig create secret generic onepassword-connect-token \
            --from-literal=token="$OP_CONNECT_TOKEN" \
            -n external-secrets-system \
            --dry-run=client -o yaml | kubectl --kubeconfig cluster-configs/kubeconfig apply -f -
        
        echo "1Password integration setup complete!"
        echo "Connect token has been stored in the workload cluster."
    fi
fi

echo ""
echo "=== Setup Complete ==="
echo "Workload cluster configs stored in: ./cluster-configs/"
echo "- talosconfig: ./cluster-configs/talosconfig"  
echo "- kubeconfig: ./cluster-configs/kubeconfig"
echo ""
echo "To use the workload cluster:"
echo "  export KUBECONFIG=./cluster-configs/kubeconfig"
echo "  kubectl get nodes"
