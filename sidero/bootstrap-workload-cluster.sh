#!/bin/bash

# A script to bootstrap a freshly provisioned Talos workload cluster.
# This script should be run after the seed cluster has provisioned the server
# and the server has booted into Talos.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Validate Input ---
echo "--- 1. Validating Input ---"
if [ -z "$1" ]; then
    echo "Error: No control plane IP address provided."
    echo "Usage: ./bootstrap-workload-cluster.sh <CONTROL_PLANE_IP>"
    exit 1
fi
CONTROL_PLANE_IP=$1
echo "Targeting control plane node at: ${CONTROL_PLANE_IP}"
echo ""


# --- 2. Wait for Node and Bootstrap ---
echo "--- 2. Waiting for Node and Bootstrapping Cluster ---"
# export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "Waiting for the talosconfig secret to be created by Sidero..."
# This secret is created in the seed cluster once the node is being provisioned.
while ! kubectl get secret talos-homelab-talosconfig -n default &> /dev/null; do
    echo "Waiting for secret/talos-homelab-talosconfig..."
    sleep 5
done
kubectl get secret talos-homelab-talosconfig -n default -o jsonpath='{.data.talosconfig}' | base64 -d > talosconfig
echo "talosconfig retrieved."

echo "Waiting for control plane node ($CONTROL_PLANE_IP) to be ready for bootstrap..."
echo "This can take several minutes as the node is provisioned and Talos services start."
# We loop `talosctl health` until the node reports it is ready to be bootstrapped.
while true; do
    # We expect this to fail with various errors until the node is up and running the API.
    if talosctl health --talosconfig=./talosconfig -n "$CONTROL_PLANE_IP" 2>/dev/null | grep -q "etcd: waiting for bootstrap"; then
        echo "Node $CONTROL_PLANE_IP is ready for bootstrap."
        break
    else
        echo "Still waiting for node $CONTROL_PLANE_IP to report its status..."
    fi
    sleep 15
done

echo "Bootstrapping cluster on node $CONTROL_PLANE_IP..."
talosctl bootstrap --talosconfig=./talosconfig -n "$CONTROL_PLANE_IP"

echo "Bootstrap command issued. Waiting a few minutes for the control plane to stabilize..."
sleep 120

echo "Retrieving kubeconfig for the new workload cluster..."
# The kubeconfig will be saved to the current directory.
talosctl kubeconfig --talosconfig=./talosconfig -n "$CONTROL_PLANE_IP" .
echo "Workload cluster kubeconfig saved to './kubeconfig'."
echo ""