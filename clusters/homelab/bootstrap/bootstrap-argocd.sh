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
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="v2.13.2"
KUBECONFIG="${KUBECONFIG:-cluster-configs/kubeconfig}"
UNINSTALL_FLUX="${UNINSTALL_FLUX:-false}"

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

# Uninstall Flux if requested
uninstall_flux() {
    if [[ "$UNINSTALL_FLUX" != "true" ]]; then
        log_info "Skipping Flux uninstallation (set UNINSTALL_FLUX=true to uninstall)"
        return 0
    fi

    log_warning "Uninstalling FluxCD..."
    
    if ! command_exists flux; then
        log_warning "Flux CLI not found, manually removing Flux resources..."
        # Remove Flux CRDs and resources manually
        kubectl --kubeconfig="$KUBECONFIG" delete kustomization --all -n flux-system --ignore-not-found=true
        kubectl --kubeconfig="$KUBECONFIG" delete helmrelease --all -n flux-system --ignore-not-found=true
        kubectl --kubeconfig="$KUBECONFIG" delete helmrepository --all -n flux-system --ignore-not-found=true
        kubectl --kubeconfig="$KUBECONFIG" delete gitrepository --all -n flux-system --ignore-not-found=true
        kubectl --kubeconfig="$KUBECONFIG" delete -f https://github.com/fluxcd/flux2/releases/download/v2.6.3/install.yaml --ignore-not-found=true
    else
        flux uninstall --kubeconfig="$KUBECONFIG" --silent
    fi
    
    log_success "FluxCD uninstalled (workloads preserved)"
}

# Create ArgoCD namespace
create_namespace() {
    log_info "Creating ArgoCD namespace..."
    
    kubectl --kubeconfig="$KUBECONFIG" create namespace "$ARGOCD_NAMESPACE" \
        --dry-run=client -o yaml | kubectl --kubeconfig="$KUBECONFIG" apply -f -
    
    log_success "Namespace $ARGOCD_NAMESPACE created"
}

# Install ArgoCD
install_argocd() {
    log_info "Installing ArgoCD ${ARGOCD_VERSION}..."
    
    # Install ArgoCD core components
    kubectl --kubeconfig="$KUBECONFIG" apply -n "$ARGOCD_NAMESPACE" \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
    
    log_info "Waiting for ArgoCD components to be ready..."
    
    # Wait for all ArgoCD deployments to be ready
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
        deployment/argocd-server -n "$ARGOCD_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
        deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
        deployment/argocd-redis -n "$ARGOCD_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
        deployment/argocd-dex-server -n "$ARGOCD_NAMESPACE"
    kubectl --kubeconfig="$KUBECONFIG" wait --for=condition=available --timeout=300s \
        deployment/argocd-notifications-controller -n "$ARGOCD_NAMESPACE"
    
    log_success "ArgoCD installed successfully"
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
                    curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64
                    ;;
                aarch64|arm64)
                    curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-arm64
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
                    curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-darwin-amd64
                    ;;
                arm64)
                    curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-darwin-arm64
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

    sudo install -m 755 argocd /usr/local/bin/argocd
    rm argocd

    log_success "ArgoCD CLI installed: $(argocd version --client --short)"
}

# Configure ArgoCD for insecure mode (no TLS) behind ingress
configure_argocd() {
    log_info "Configuring ArgoCD server for insecure mode (behind ingress)..."
    
    # Patch argocd-server to run with --insecure flag (for ingress)
    kubectl --kubeconfig="$KUBECONFIG" patch deployment argocd-server -n "$ARGOCD_NAMESPACE" \
        --type='json' \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/command/-", "value": "--insecure"}]' \
        2>/dev/null || log_warning "ArgoCD server already configured for insecure mode"
    
    log_success "ArgoCD configured"
}

# Get initial admin password
get_admin_password() {
    log_info "Retrieving ArgoCD admin password..."
    
    # Wait for secret to exist
    timeout=30
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

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check ArgoCD server
    if kubectl --kubeconfig="$KUBECONFIG" get deployment argocd-server -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        log_success "✓ ArgoCD server is running"
    else
        log_error "✗ ArgoCD server is not running"
    fi
    
    # Check ArgoCD repo server
    if kubectl --kubeconfig="$KUBECONFIG" get deployment argocd-repo-server -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        log_success "✓ ArgoCD repo server is running"
    else
        log_error "✗ ArgoCD repo server is not running"
    fi
    
    # Check ArgoCD application controller
    if kubectl --kubeconfig="$KUBECONFIG" get statefulset argocd-application-controller -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        log_success "✓ ArgoCD application controller is running"
    else
        log_error "✗ ArgoCD application controller is not running"
    fi
    
    log_success "Installation verification complete!"
}

# Main execution
main() {
    echo "=================================="
    echo "ArgoCD Bootstrap Script"
    echo "=================================="
    
    log_info "Starting ArgoCD bootstrap for cluster: $CLUSTER_NAME"
    
    # Pre-flight checks
    check_kubectl
    
    # Optionally uninstall Flux
    uninstall_flux
    
    # Install ArgoCD
    create_namespace
    install_argocd
    install_argocd_cli
    configure_argocd
    
    # Get admin credentials
    get_admin_password
    
    # Verify everything is working
    verify_installation
    
    echo "=================================="
    log_success "Bootstrap complete!"
    echo "=================================="
    
    echo ""
    log_info "ArgoCD Admin Credentials:"
    echo "  Username: admin"
    echo "  Password: ${ARGOCD_PASSWORD}"
    echo ""
    
    log_info "Access ArgoCD UI:"
    log_info "  Port-forward: kubectl --kubeconfig=$KUBECONFIG port-forward svc/argocd-server -n $ARGOCD_NAMESPACE 8080:443"
    log_info "  Then visit: http://localhost:8080"
    echo ""
    
    log_info "Login with ArgoCD CLI:"
    log_info "  kubectl --kubeconfig=$KUBECONFIG port-forward svc/argocd-server -n $ARGOCD_NAMESPACE 8080:443"
    log_info "  argocd login localhost:8080 --username admin --password $ARGOCD_PASSWORD --insecure"
    echo ""
    
    log_info "Next steps:"
    log_info "1. Create ArgoCD Applications to manage your workloads"
    log_info "2. Configure ingress for ArgoCD UI (optional)"
    log_info "3. Set up SSO/RBAC (optional)"
    log_info "4. Change the admin password: argocd account update-password"
}

# Run main function
main "$@"

