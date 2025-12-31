#!/bin/bash
#
# Bootstrap ArgoCD on the homelab cluster
# This script installs ArgoCD and deploys the root App-of-Apps
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source common utilities
source "$SCRIPT_DIR/../../lib/common.sh"

# Configuration
CLUSTER_NAME="homelab"
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="v2.13.2"
KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/cluster-configs/kubeconfig}"
UNINSTALL_FLUX="${UNINSTALL_FLUX:-false}"
VAULT_NAME="${OP_VAULT_NAME:-Homelab}"

# Install External Secrets Operator
install_external_secrets() {
    log_info "Checking External Secrets Operator..."
    
    if kubectl --kubeconfig="$KUBECONFIG" get crd externalsecrets.external-secrets.io &>/dev/null; then
        log_success "External Secrets Operator already installed"
        return 0
    fi
    
    log_info "Installing External Secrets Operator..."
    
    # Install CRDs first
    kubectl --kubeconfig="$KUBECONFIG" apply --server-side -f \
        "https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml"
    
    # Install ESO
    kubectl --kubeconfig="$KUBECONFIG" apply --server-side -f \
        "https://github.com/external-secrets/external-secrets/releases/download/v0.10.0/external-secrets.yaml"
    
    log_info "Waiting for External Secrets Operator to be ready..."
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=120s \
        deployment/external-secrets -n external-secrets || true
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=120s \
        deployment/external-secrets-webhook -n external-secrets || true
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=120s \
        deployment/external-secrets-cert-controller -n external-secrets || true
    
    log_success "External Secrets Operator installed"
}

# Install 1Password Connect
install_1password_connect() {
    log_info "Checking 1Password Connect..."
    
    if kubectl --kubeconfig="$KUBECONFIG" get deployment op-connect -n default &>/dev/null; then
        log_success "1Password Connect already running"
    else
        log_info "Installing 1Password Connect..."
        
        # Check for credentials file
        if [[ ! -f "$REPO_ROOT/1password-credentials.json" ]]; then
            log_error "1password-credentials.json not found in repo root"
            log_info "Download it from: https://my.1password.com/integrations/infrastructure-secrets"
            exit 1
        fi
        
        # Create credentials secret
        kubectl --kubeconfig="$KUBECONFIG" create secret generic op-credentials \
            --from-file=1password-credentials.json="$REPO_ROOT/1password-credentials.json" \
            -n default --dry-run=client -o yaml | kubectl --kubeconfig="$KUBECONFIG" apply -f -
        
        # Deploy 1Password Connect
        kubectl --kubeconfig="$KUBECONFIG" apply --server-side -f \
            "https://raw.githubusercontent.com/1Password/connect/refs/heads/main/examples/kubernetes/op-connect-deployment.yaml"
        
        # Create service
        kubectl --kubeconfig="$KUBECONFIG" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: op-connect
  namespace: default
spec:
  selector:
    app: op-connect
  ports:
    - name: http
      port: 8080
      targetPort: 8080
EOF
        
        log_info "Waiting for 1Password Connect to be ready..."
        kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=120s \
            deployment/op-connect -n default
        
        log_success "1Password Connect installed"
    fi
    
    # Check/create ClusterSecretStore
    log_info "Checking ClusterSecretStore..."
    if kubectl --kubeconfig="$KUBECONFIG" get clustersecretstore onepassword-store &>/dev/null; then
        log_success "ClusterSecretStore already exists"
    else
        log_info "Creating ClusterSecretStore..."
        
        # Create connect token if needed
        if ! kubectl --kubeconfig="$KUBECONFIG" get secret onepassword-connect-token -n external-secrets &>/dev/null; then
            log_info "Creating 1Password Connect token..."
            
            if ! command_exists op; then
                log_error "1Password CLI required to create connect token"
                exit 1
            fi
            
            if ! op account get &>/dev/null; then
                log_error "Not signed in to 1Password CLI. Run: eval \$(op signin)"
                exit 1
            fi
            
            OP_CONNECT_TOKEN=$(op connect token create "ArgoCD Bootstrap - $(date '+%Y-%m-%d %H:%M:%S')" \
                --server "homelab" --vault="$VAULT_NAME")
            
            kubectl --kubeconfig="$KUBECONFIG" create namespace external-secrets --dry-run=client -o yaml | \
                kubectl --kubeconfig="$KUBECONFIG" apply -f -
            
            kubectl --kubeconfig="$KUBECONFIG" create secret generic onepassword-connect-token \
                --from-literal=token="$OP_CONNECT_TOKEN" \
                -n external-secrets --dry-run=client -o yaml | kubectl --kubeconfig="$KUBECONFIG" apply -f -
        fi
        
        # Create ClusterSecretStore
        kubectl --kubeconfig="$KUBECONFIG" apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: onepassword-store
spec:
  provider:
    onepassword:
      connectHost: http://op-connect.default.svc.cluster.local:8080
      vaults:
        Homelab: 1
      auth:
        secretRef:
          connectTokenSecretRef:
            name: onepassword-connect-token
            namespace: external-secrets
            key: token
EOF
        
        log_success "ClusterSecretStore created"
    fi
}

# Uninstall Flux if requested
uninstall_flux() {
    if [[ "$UNINSTALL_FLUX" != "true" ]]; then
        log_info "Skipping Flux uninstallation (set UNINSTALL_FLUX=true to uninstall)"
        return 0
    fi

    log_warning "Uninstalling FluxCD..."
    
    if command_exists flux; then
        flux uninstall --kubeconfig="$KUBECONFIG" --silent || true
    else
        log_warning "Flux CLI not found, manually removing Flux resources..."
        kubectl --kubeconfig="$KUBECONFIG" delete kustomization --all -n flux-system --ignore-not-found=true
        kubectl --kubeconfig="$KUBECONFIG" delete helmrelease --all -n flux-system --ignore-not-found=true
        kubectl --kubeconfig="$KUBECONFIG" delete helmrepository --all -n flux-system --ignore-not-found=true
        kubectl --kubeconfig="$KUBECONFIG" delete gitrepository --all -n flux-system --ignore-not-found=true
        kubectl --kubeconfig="$KUBECONFIG" delete -f https://github.com/fluxcd/flux2/releases/download/v2.6.3/install.yaml --ignore-not-found=true || true
    fi
    
    log_success "FluxCD uninstalled (workloads preserved)"
}

# Create ArgoCD namespace with PSA labels
create_namespace() {
    log_info "Creating ArgoCD namespace..."
    
    kubectl --kubeconfig="$KUBECONFIG" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ARGOCD_NAMESPACE
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
EOF
    
    log_success "Namespace $ARGOCD_NAMESPACE created"
}

# Install ArgoCD
install_argocd() {
    log_info "Installing ArgoCD ${ARGOCD_VERSION}..."
    
    kubectl --kubeconfig="$KUBECONFIG" apply -n "$ARGOCD_NAMESPACE" \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
    
    log_info "Waiting for ArgoCD components to be ready..."
    
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
        deployment/argocd-server -n "$ARGOCD_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
        deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
        deployment/argocd-redis -n "$ARGOCD_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
        deployment/argocd-applicationset-controller -n "$ARGOCD_NAMESPACE"
    
    log_success "ArgoCD installed successfully"
}

# Configure ArgoCD for insecure mode (behind ingress)
configure_argocd() {
    log_info "Configuring ArgoCD server..."
    
    # Apply cmd params configmap for insecure mode
    kubectl --kubeconfig="$KUBECONFIG" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: $ARGOCD_NAMESPACE
  labels:
    app.kubernetes.io/name: argocd-cmd-params-cm
    app.kubernetes.io/part-of: argocd
data:
  server.insecure: "true"
EOF
    
    # Restart argocd-server to pick up config
    kubectl --kubeconfig="$KUBECONFIG" rollout restart deployment/argocd-server -n "$ARGOCD_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=120s \
        deployment/argocd-server -n "$ARGOCD_NAMESPACE"
    
    log_success "ArgoCD configured for insecure mode"
}

# Deploy ArgoCD ingress
deploy_ingress() {
    log_info "Deploying ArgoCD ingress..."
    
    kubectl --kubeconfig="$KUBECONFIG" apply \
        -f "$REPO_ROOT/clusters/homelab/base/argocd/argocd-ingress.yaml"
    
    log_success "ArgoCD ingress deployed (argo.tkuipers.ca)"
}

# Deploy git SSH ExternalSecret
deploy_git_secret() {
    log_info "Deploying git SSH ExternalSecret..."
    
    kubectl --kubeconfig="$KUBECONFIG" apply \
        -f "$REPO_ROOT/clusters/homelab/base/argocd/argocd-externalsecret-git-ssh.yaml"
    
    # Wait for the secret to sync
    log_info "Waiting for ExternalSecret to sync..."
    local timeout=30
    while ! kubectl --kubeconfig="$KUBECONFIG" get secret argocd-git-ssh -n "$ARGOCD_NAMESPACE" &>/dev/null; do
        if [ $timeout -le 0 ]; then
            log_warning "Git SSH secret not yet synced - check ExternalSecret status:"
            kubectl --kubeconfig="$KUBECONFIG" get externalsecret argocd-git-ssh -n "$ARGOCD_NAMESPACE" 2>/dev/null || true
            return 1
        fi
        sleep 2
        timeout=$((timeout - 2))
    done
    
    log_success "Git SSH secret created via ExternalSecret"
}

# Apply ArgoCD repo configuration
configure_repo() {
    log_info "Configuring ArgoCD repository..."
    
    kubectl --kubeconfig="$KUBECONFIG" apply \
        -f "$REPO_ROOT/clusters/homelab/base/argocd/argocd-configmap-argocd-cm.yaml"
    
    log_success "ArgoCD repository configured"
}

# Install ArgoCD CLI
install_argocd_cli() {
    if command_exists argocd; then
        log_info "ArgoCD CLI already installed: $(argocd version --client --short 2>/dev/null || echo 'unknown')"
        return 0
    fi

    log_info "Installing ArgoCD CLI..."
    
    case "$(uname -s)" in
        Linux*)
            case "$(uname -m)" in
                x86_64)
                    curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64
                    ;;
                aarch64|arm64)
                    curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-arm64
                    ;;
                *)
                    log_error "Unsupported architecture: $(uname -m)"
                    exit 1
                    ;;
            esac
            ;;
        Darwin*)
            case "$(uname -m)" in
                x86_64)
                    curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-darwin-amd64
                    ;;
                arm64)
                    curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-darwin-arm64
                    ;;
                *)
                    log_error "Unsupported architecture: $(uname -m)"
                    exit 1
                    ;;
            esac
            ;;
        *)
            log_error "Unsupported operating system: $(uname -s)"
            exit 1
            ;;
    esac

    sudo install -m 755 /tmp/argocd /usr/local/bin/argocd
    rm /tmp/argocd

    log_success "ArgoCD CLI installed: $(argocd version --client --short)"
}

# Deploy AppProjects
deploy_projects() {
    log_info "Deploying AppProjects..."
    
    # Use kustomize to apply the projects directory
    kubectl --kubeconfig="$KUBECONFIG" apply -k "$REPO_ROOT/clusters/homelab/base/projects/"
    
    log_success "AppProjects deployed"
}

# Deploy root Application (App-of-Apps)
deploy_root_application() {
    log_info "Deploying root Application..."
    
    kubectl --kubeconfig="$KUBECONFIG" apply \
        -f "$REPO_ROOT/clusters/homelab/base/root/argocd-application-root.yaml"
    
    log_success "Root Application deployed"
    
    # Wait for root app to be created
    log_info "Waiting for root Application to sync..."
    sleep 5
    
    # Show initial status
    kubectl --kubeconfig="$KUBECONFIG" get applications -n "$ARGOCD_NAMESPACE" 2>/dev/null || true
}

# Get initial admin password
get_admin_password() {
    log_info "Retrieving ArgoCD admin password..."
    
    local timeout=60
    while ! kubectl --kubeconfig="$KUBECONFIG" get secret argocd-initial-admin-secret -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; do
        if [ $timeout -le 0 ]; then
            log_error "Timeout waiting for admin password secret"
            exit 1
        fi
        sleep 2
        timeout=$((timeout - 2))
    done
    
    ARGOCD_PASSWORD=$(kubectl --kubeconfig="$KUBECONFIG" get secret argocd-initial-admin-secret \
        -n "$ARGOCD_NAMESPACE" -o jsonpath="{.data.password}" | base64 -d)
    
    log_success "Admin password retrieved"
}

# Save credentials to 1Password
save_credentials_to_1password() {
    log_info "Saving ArgoCD credentials to 1Password..."
    
    local ITEM_NAME="ArgoCD Admin"
    local ARGOCD_URL="https://argo.tkuipers.ca"
    
    # Check if op CLI is available
    if ! command_exists op; then
        log_warning "1Password CLI not installed, skipping credential save"
        return 0
    fi
    
    # Check if signed in
    if ! op account get &> /dev/null; then
        log_warning "Not signed in to 1Password CLI, skipping credential save"
        log_info "Run 'eval \$(op signin)' and re-run this script to save credentials"
        return 0
    fi
    
    # Check if item exists
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_info "Updating existing 1Password item..."
        op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
            "username=admin" \
            "password=$ARGOCD_PASSWORD" \
            "website=$ARGOCD_URL" \
            >/dev/null
    else
        log_info "Creating new 1Password item..."
        op item create --vault="$VAULT_NAME" \
            --category="Login" \
            --title="$ITEM_NAME" \
            --url="$ARGOCD_URL" \
            "username=admin" \
            "password=$ARGOCD_PASSWORD" \
            >/dev/null
    fi
    
    log_success "ArgoCD credentials saved to 1Password ($ITEM_NAME)"
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    local all_good=true
    
    if kubectl --kubeconfig="$KUBECONFIG" get deployment argocd-server -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        log_success "✓ ArgoCD server is running"
    else
        log_error "✗ ArgoCD server is not running"
        all_good=false
    fi
    
    if kubectl --kubeconfig="$KUBECONFIG" get deployment argocd-repo-server -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        log_success "✓ ArgoCD repo server is running"
    else
        log_error "✗ ArgoCD repo server is not running"
        all_good=false
    fi
    
    if kubectl --kubeconfig="$KUBECONFIG" get statefulset argocd-application-controller -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        log_success "✓ ArgoCD application controller is running"
    else
        log_error "✗ ArgoCD application controller is not running"
        all_good=false
    fi
    
    if kubectl --kubeconfig="$KUBECONFIG" get application root -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        log_success "✓ Root Application exists"
    else
        log_error "✗ Root Application not found"
        all_good=false
    fi
    
    if [ "$all_good" = "true" ]; then
        log_success "Installation verification complete!"
    else
        log_warning "Some components may need attention"
    fi
}

# Main execution
main() {
    echo "=================================="
    echo "   ArgoCD Bootstrap Script"
    echo "=================================="
    echo
    
    log_info "Starting ArgoCD bootstrap for cluster: $CLUSTER_NAME"
    log_info "Using kubeconfig: $KUBECONFIG"
    echo
    
    # Pre-flight checks
    check_kubectl
    
    # Optionally uninstall Flux first
    uninstall_flux
    
    # Install prerequisites (External Secrets + 1Password Connect)
    install_external_secrets
    install_1password_connect
    
    # Install ArgoCD
    create_namespace
    install_argocd
    install_argocd_cli
    configure_argocd
    deploy_ingress
    deploy_git_secret
    configure_repo
    
    # Deploy GitOps configuration
    deploy_projects
    deploy_root_application
    
    # Get admin credentials
    get_admin_password
    
    # Save to 1Password
    save_credentials_to_1password
    
    # Verify everything is working
    verify_installation
    
    echo
    echo "=================================="
    log_success "Bootstrap complete!"
    echo "=================================="
    echo
    
    log_info "ArgoCD Admin Credentials:"
    echo "  Username: admin"
    echo "  Password: ${ARGOCD_PASSWORD}"
    echo
    
    log_info "Access ArgoCD UI:"
    echo "  Port-forward: kubectl --kubeconfig=$KUBECONFIG port-forward svc/argocd-server -n $ARGOCD_NAMESPACE 8080:80"
    echo "  Then visit: http://localhost:8080"
    echo
    echo "  Or after ingress is configured: https://argo.tkuipers.ca"
    echo
    
    log_info "Login with ArgoCD CLI:"
    echo "  argocd login localhost:8080 --username admin --password '$ARGOCD_PASSWORD' --insecure"
    echo
    
    log_info "Monitor sync status:"
    echo "  kubectl --kubeconfig=$KUBECONFIG get applications -n $ARGOCD_NAMESPACE"
    echo "  argocd app list"
    echo
    
    log_info "Prerequisites before apps will sync:"
    echo "  1. Run: ./tooling/scripts/setup-credentials/setup-datadog-credentials.sh"
    echo "  2. Ensure External Secrets Operator is running"
    echo "  3. Ensure ClusterSecretStore 'onepassword-store' exists"
}

main "$@"
