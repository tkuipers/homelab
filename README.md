# Home Infra

This repository contains the infrastructure configuration for a Talos-based Kubernetes cluster designed for zero-touch bare-metal provisioning.

## Core Concepts

This setup uses **Sidero Metal** for provisioning and **FluxCD** for ongoing cluster management (GitOps).

1.  **Seed Cluster**: A small, temporary Kubernetes cluster (e.g., on a Raspberry Pi) runs the Sidero Metal controller.
2.  **PXE Boot**: Your bare-metal servers are configured to boot from the network (PXE boot).
3.  **Sidero Metal**: The booting servers are discovered by Sidero. Sidero matches the server to a manifest in this repository, generates a Talos configuration for it, and serves it to the machine.
4.  **Talos & FluxCD Bootstrap**: As part of the Talos configuration, Sidero injects the manifests for FluxCD. When the Talos cluster comes up, it automatically installs FluxCD.
5.  **GitOps Takeover**: FluxCD starts, sees its configuration pointing to this Git repository, and takes over management of the entire cluster, deploying Rancher and any other applications defined here.

## Repository Structure

-   `cluster/`: Contains Kubernetes manifests to be managed by FluxCD.
    -   `core/`: Core cluster components (FluxCD, Rancher).
-   `talos/`: Contains base Talos machine configurations.
-   `sidero/`: Contains Sidero Metal manifests that define the servers and their classes.

## Getting Started: The Fully Automated Path

1.  **Set up the Seed Cluster**:
    -   On a separate machine (like a Raspberry Pi), run the automated setup script. This will install `k3s`, the Sidero Metal controller, and apply your local server definitions.
    -   Make sure you are in the root of this repository, then run:
        ```bash
        bash sidero/setup-seed-cluster.sh
        ```
    -   Once the script is complete, configure your network's DHCP server to point PXE-booting clients to the Sidero service.

2.  **Prepare this Repository**:
    -   Update `sidero/servers.yaml` to define your physical machines, preferably matching them by MAC address for security.
    -   Generate the full FluxCD manifest by running `flux bootstrap ...` as described in `cluster/core/flux-system/flux.yaml`. Commit this file to the repository.

3.  **Generate and Deploy Sidero Manifests**:
    -   Push your changes to the `main` branch of this repository on GitHub.
    -   Go to the "Actions" tab in your GitHub repository.
    -   Find the "Prepare Sidero Manifests" workflow and wait for it to complete.
    -   Once the workflow is complete, download the `prepared-sidero-manifests` artifact. This ZIP file contains the final, ready-to-use Sidero manifests with FluxCD injected.
    -   Apply the downloaded manifests to your seed cluster: `kubectl apply -f /path/to/downloaded/manifests/`.
    -   You also need to apply your base Talos configurations from the `talos/nodes` directory to your seed cluster (e.g., as ConfigMaps) so Sidero can reference them.

4.  **Boot Your Servers**:
    -   Power on your bare-metal machines. They will PXE boot, be discovered by Sidero, and automatically provisioned into a fully functional, GitOps-managed Talos cluster.

## NVIDIA GPU Support

The `worker-gpu.yaml` is intended for the node with the NVIDIA 1060 GPU. You will need to add the necessary configurations to enable GPU support in Talos and Kubernetes. This typically involves:
- Installing the NVIDIA kernel drivers on the Talos node. This can be done via a custom kernel module image or using Talos's built-in support if available for your card.
- Deploying the NVIDIA device plugin for Kubernetes.
- Deploying NVIDIA Feature Discovery to label the node with GPU resources. 