# GitHub Actions for Home Infra

This directory contains the GitHub Actions workflows for maintaining the health and deployment of this repository.

## Suggested Workflows

### 1. CI (Continuous Integration)

A good first step is to create a workflow that runs on every push and pull request to validate your configurations.

**File:** `ci.yaml`

**Triggers:** `on: [push, pull_request]`

**Jobs:**
-   **Lint YAML:** Use a tool like `yamllint` to ensure all your YAML files have correct syntax.
-   **Validate Kubernetes Manifests:** Use a tool like `kubeval` or `kubectl --dry-run=client` to check that your Kubernetes manifests in `cluster/` are valid.
-   **Validate Talos Configuration:** You can use `talosctl` in a workflow to validate the machine configuration files.
    -   `talosctl validate --config talos/nodes/controlplane.yaml --mode cloud`
    -   `talosctl validate --config talos/nodes/worker-gpu.yaml --mode cloud`

### 2. CD (Continuous Delivery) with FluxCD

Once you have FluxCD installed in your cluster and pointed to this repository, you don't strictly *need* a CD workflow, as Flux handles the deployment automatically.

However, you can create workflows to enhance the process:
-   **Image Update Automation:** Have a workflow that watches for new versions of your application images (e.g., a new version of your blog software), and automatically creates a pull request to update the image tag in your Kubernetes manifests. FluxCD has its own components for this (Image Reflector and Image Automation Controller) that are worth investigating.
-   **Notifications:** Create a workflow that sends you a notification (e.g., via Discord or Slack) when FluxCD has successfully synchronized a new commit.

## Getting Started

1.  Create a new file in this directory named `ci.yaml`.
2.  Copy a starter YAML linting workflow into it. You can find many examples in the GitHub Actions Marketplace.
3.  Build out the other validation steps. You will need to use actions like `actions/checkout@v4` and set up the necessary CLI tools in your workflow steps.

## Secrets

You shouldn't need any secrets for the CI workflow. If you were to build a CD workflow that pushes to an external service (like provisioning cloud infrastructure with OpenTofu), you would add secrets to your repository by going to `Settings > Secrets and variables > Actions`. 