#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="homelab"
GITHUB_REPO="git@github.com:tkuipers/homelab.git"
FLUX_NAMESPACE="flux-system"
EXTERNAL_SECRETS_VERSION="v0.18.1"
ONEPASSWORD_VAULT="Homelab"
KUBECONFIG="${KUBECONFIG:-cluster-configs/kubeconfig}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_DIR="$SCRIPT_DIR/yaml"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if kubectl is working
check_kubectl() {
    if ! kubectl --kubeconfig="$KUBECONFIG" cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig at $KUBECONFIG"
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
}

# Install 1Password CLI if needed
install_op_cli() {
    if command_exists op; then
        log_info "1Password CLI already installed: $(op --version)"
        return 0
    fi

    log_info "Installing 1Password CLI..."
    
    # Download and install 1Password CLI
    case "$(uname -s)" in
        Linux*)
            case "$(uname -m)" in
                x86_64)
                    curl -sSfo op.zip https://cache.agilebits.com/dist/1P/op2/pkg/v2.30.0/op_linux_amd64_v2.30.0.zip
                    ;;
                aarch64|arm64)
                    curl -sSfo op.zip https://cache.agilebits.com/dist/1P/op2/pkg/v2.30.0/op_linux_arm64_v2.30.0.zip
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
                    curl -sSfo op.zip https://cache.agilebits.com/dist/1P/op2/pkg/v2.30.0/op_darwin_amd64_v2.30.0.zip
                    ;;
                arm64)
                    curl -sSfo op.zip https://cache.agilebits.com/dist/1P/op2/pkg/v2.30.0/op_darwin_arm64_v2.30.0.zip
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

    unzip -o op.zip op
    sudo mv op /usr/local/bin/op
    sudo chmod +x /usr/local/bin/op
    rm op.zip

    log_success "1Password CLI installed: $(op --version)"
}

# Check if 1Password CLI is installed and signed in
check_op_signin() {
    log_info "Checking 1Password CLI status..."
    if ! command -v op &> /dev/null; then
        log_error "1Password CLI 'op' could not be found. Please install it."
        exit 1
    fi

    # Loop until the user is successfully signed in.
    while ! op vault list >/dev/null 2>&1; do
        log_warning "Not signed in to 1Password, or the session is invalid."
        log_info "Please use the following prompt to sign in."
        # 'op signin' is interactive. If it fails (e.g., wrong password),
        # the loop will repeat. If the user uses Ctrl+C, the script will exit.
        eval $(op signin)
    done

    log_success "1Password CLI is installed and signed in."
}

# Install External Secrets Operator CRDs
install_external_secrets_crds() {
    log_info "Installing External Secrets Operator CRDs..."
    
    kubectl --kubeconfig="$KUBECONFIG" apply -f "https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml"
    
    log_success "External Secrets CRDs installed"
}

# Install External Secrets Operator
install_external_secrets_operator() {
    log_info "Installing External Secrets Operator..."
    
    # Create external-secrets-system namespace first
    kubectl --kubeconfig="$KUBECONFIG" apply -f "$YAML_DIR/external-secrets-namespace.yaml"
    
    kubectl --kubeconfig="$KUBECONFIG" apply -f "https://github.com/external-secrets/external-secrets/releases/download/$EXTERNAL_SECRETS_VERSION/external-secrets.yaml"
    
    # Wait for External Secrets to be ready
    log_info "Waiting for External Secrets operator to be ready..."
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s deployment/external-secrets -n default
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s deployment/external-secrets-cert-controller -n default
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s deployment/external-secrets-webhook -n default
    
    log_success "External Secrets Operator ready"
}

# Deploy 1Password Connect
deploy_1password_connect() {
    log_info "Deploying 1Password Connect..."
    
    # Create 1Password Connect credentials secret
    if kubectl --kubeconfig="$KUBECONFIG" get secret op-credentials -n default >/dev/null 2>&1; then
        log_info "1Password Connect credentials secret already exists"
    else
        if [[ ! -f "1password-credentials.json" ]]; then
            log_error "1password-credentials.json not found. Please ensure it exists in the current directory."
            exit 1
        fi
        
        kubectl --kubeconfig="$KUBECONFIG" create secret generic op-credentials \
            --from-file=1password-credentials.json=./1password-credentials.json \
            -n default
        
        log_success "1Password Connect credentials secret created"
    fi
    
    # Deploy 1Password Connect
    kubectl --kubeconfig="$KUBECONFIG" apply -f "https://raw.githubusercontent.com/1Password/connect/refs/heads/main/examples/kubernetes/op-connect-deployment.yaml"
    
    # Create service for 1Password Connect
    kubectl --kubeconfig="$KUBECONFIG" apply -f "$YAML_DIR/op-connect-service.yaml"
    
    # Wait for 1Password Connect to be ready
    log_info "Waiting for 1Password Connect to be ready..."
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s deployment/op-connect -n default
    
    log_success "1Password Connect deployed and ready"
}

# Create 1Password SecretStore
create_secretstore() {
    log_info "Creating 1Password SecretStore..."
    
    # Create a new 1Password Connect token
    OP_CONNECT_TOKEN=$(op connect token create "Homelab Bootstrap - $(date '+%Y-%m-%d %H:%M:%S')" --server "homelab" --vault="$ONEPASSWORD_VAULT")
    
    # Create the connect token secret
    kubectl --kubeconfig="$KUBECONFIG" create secret generic onepassword-connect-token \
        --from-literal=token="$OP_CONNECT_TOKEN" \
        -n external-secrets-system \
        --dry-run=client -o yaml | kubectl --kubeconfig="$KUBECONFIG" apply -f -
    
    # Create SecretStore
    kubectl --kubeconfig="$KUBECONFIG" apply -f "$YAML_DIR/secretstore.yaml"
    
    log_success "1Password SecretStore created"
}

# Create SSH key ExternalSecret for Flux
create_flux_ssh_secret() {
    log_info "Creating Flux SSH ExternalSecret..."
    
    kubectl --kubeconfig="$KUBECONFIG" apply -f "$YAML_DIR/flux-ssh-externalsecret.yaml" -n "$FLUX_NAMESPACE"
    
    log_success "Flux SSH ExternalSecret created"
}

# Bootstrap FluxCD
bootstrap_flux() {
    log_info "Bootstrapping FluxCD..."
    
    # Create flux-system namespace
    kubectl --kubeconfig="$KUBECONFIG" create namespace "$FLUX_NAMESPACE" --dry-run=client -o yaml | kubectl --kubeconfig="$KUBECONFIG" apply -f -
    
    # Wait for SSH secret to be created by External Secrets
    log_info "Waiting for SSH secret to be synced by External Secrets..."
    timeout=30
    while ! kubectl --kubeconfig="$KUBECONFIG" get secret flux-git-ssh -n "$FLUX_NAMESPACE" >/dev/null 2>&1; do
        if [ $timeout -le 0 ]; then
            log_error "Timeout waiting for SSH secret to be created"
            exit 1
        fi
        sleep 5
        timeout=$((timeout - 5))
        log_info "Still waiting for SSH secret... (${timeout}s remaining)"
    done
    
    log_success "SSH secret is ready"
    
    # Install FluxCD CRDs and controllers
    kubectl --kubeconfig="$KUBECONFIG" apply -f "https://github.com/fluxcd/flux2/releases/download/v2.6.3/install.yaml"
    
    # Wait for Flux controllers to be ready
    log_info "Waiting for FluxCD controllers to be ready..."
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s deployment/source-controller -n "$FLUX_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s deployment/kustomize-controller -n "$FLUX_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s deployment/helm-controller -n "$FLUX_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s deployment/notification-controller -n "$FLUX_NAMESPACE"
    
    # Create GitRepository
    log_info "Creating Flux GitRepository..."
    kubectl --kubeconfig="$KUBECONFIG" apply -f "$YAML_DIR/gitrepository.yaml"
    
    # Create main Kustomization
    log_info "Creating Flux Kustomization..."
    kubectl --kubeconfig="$KUBECONFIG" apply -f "$YAML_DIR/kustomization.yaml"
    
    log_success "FluxCD bootstrapped successfully"
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check External Secrets
    if kubectl --kubeconfig="$KUBECONFIG" get deployment external-secrets -n default >/dev/null 2>&1; then
        log_success "✓ External Secrets Operator is running"
    else
        log_error "✗ External Secrets Operator is not running"
    fi
    
    # Check 1Password Connect
    if kubectl --kubeconfig="$KUBECONFIG" get deployment op-connect -n default >/dev/null 2>&1; then
        log_success "✓ 1Password Connect is running"
    else
        log_error "✗ 1Password Connect is not running"
    fi
    
    # Check SecretStore
    if kubectl --kubeconfig="$KUBECONFIG" get secretstore onepassword-store -n external-secrets-system >/dev/null 2>&1; then
        log_success "✓ 1Password SecretStore exists"
    else
        log_error "✗ 1Password SecretStore not found"
    fi
    
    # Check Flux
    if kubectl --kubeconfig="$KUBECONFIG" get deployment source-controller -n "$FLUX_NAMESPACE" >/dev/null 2>&1; then
        log_success "✓ FluxCD is running"
    else
        log_error "✗ FluxCD is not running"
    fi
    
    # Check GitRepository
    if kubectl --kubeconfig="$KUBECONFIG" get gitrepository homelab-repo -n "$FLUX_NAMESPACE" >/dev/null 2>&1; then
        log_success "✓ GitRepository exists"
    else
        log_error "✗ GitRepository not found"
    fi
    
    log_success "Bootstrap verification complete!"
}

# Main execution
main() {
    echo "=================================="
    echo "FluxCD Bootstrap Script"
    echo "=================================="
    
    log_info "Starting FluxCD bootstrap for cluster: $CLUSTER_NAME"
    
    # Pre-flight checks
    check_kubectl
    
    # Install and setup 1Password CLI
    install_op_cli
    check_op_signin
    
    # Install External Secrets
    install_external_secrets_crds
    install_external_secrets_operator
    
    # Setup 1Password integration
    deploy_1password_connect
    create_secretstore
    create_flux_ssh_secret
    
    # Bootstrap FluxCD
    bootstrap_flux
    
    # Verify everything is working
    verify_installation
    
    echo "=================================="
    log_success "Bootstrap complete! 🎉"
    echo "=================================="
    
    log_info "Next steps:"
    log_info "1. Check FluxCD status: kubectl --kubeconfig=$KUBECONFIG get all -n $FLUX_NAMESPACE"
    log_info "2. Check GitRepository sync: kubectl --kubeconfig=$KUBECONFIG get gitrepository -n $FLUX_NAMESPACE"
    log_info "3. Check Kustomization: kubectl --kubeconfig=$KUBECONFIG get kustomization -n $FLUX_NAMESPACE"
    log_info "4. Monitor logs: kubectl --kubeconfig=$KUBECONFIG logs -f deployment/source-controller -n $FLUX_NAMESPACE"
}

# Run main function
main "$@" 