#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="pterodactyl"
KUBECONFIG="${KUBECONFIG:-cluster-configs/kubeconfig}"

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

# Check if kubectl is working
check_kubectl() {
    if ! kubectl --kubeconfig="$KUBECONFIG" cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig at $KUBECONFIG"
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
}

# Find the panel pod
find_panel_pod() {
    log_info "Finding Pterodactyl panel pod..."
    
    PANEL_POD=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" \
        -l app.kubernetes.io/component=panel \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$PANEL_POD" ]]; then
        log_error "No Pterodactyl panel pod found in namespace $NAMESPACE"
        log_info "Available pods:"
        kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE"
        exit 1
    fi
    
    # Check if pod is ready
    READY=$(kubectl --kubeconfig="$KUBECONFIG" get pod "$PANEL_POD" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    
    if [[ "$READY" != "True" ]]; then
        log_error "Panel pod $PANEL_POD is not ready"
        kubectl --kubeconfig="$KUBECONFIG" get pod "$PANEL_POD" -n "$NAMESPACE"
        exit 1
    fi
    
    log_success "Found ready panel pod: $PANEL_POD"
}

# Create user
create_user() {
    echo ""
    echo "=================================="
    echo "    Pterodactyl User Creation"
    echo "=================================="
    echo ""
    
    log_info "This script will help you create a new Pterodactyl user."
    log_info "You'll be prompted for the following information:"
    echo "  - Email address"
    echo "  - First name"
    echo "  - Last name"
    echo "  - Username (optional)"
    echo "  - Password (will be generated if not provided)"
    echo "  - Admin privileges (yes/no)"
    echo ""
    
    read -p "Press Enter to continue, or Ctrl+C to cancel..."
    echo ""
    
    log_info "Executing: php artisan p:user:make"
    log_info "Running in pod: $PANEL_POD"
    echo ""
    
    # Execute the artisan command interactively
    kubectl --kubeconfig="$KUBECONFIG" exec -it "$PANEL_POD" -n "$NAMESPACE" -- \
        php artisan p:user:make
    
    if [[ $? -eq 0 ]]; then
        echo ""
        log_success "User created successfully!"
        echo ""
        log_info "The user can now log in at: https://dino.tkuipers.ca"
        log_info "If you created an admin user, they'll have full panel access."
        log_warning "Make sure to provide the login credentials to the user securely."
    else
        echo ""
        log_error "User creation failed. Please check the output above for details."
        exit 1
    fi
}

# Show additional commands
show_additional_commands() {
    echo ""
    echo "=================================="
    echo "    Additional Useful Commands"
    echo "=================================="
    echo ""
    echo "List all users:"
    echo "  kubectl --kubeconfig=$KUBECONFIG exec -it $PANEL_POD -n $NAMESPACE -- php artisan p:user:list"
    echo ""
    echo "Make user admin:"
    echo "  kubectl --kubeconfig=$KUBECONFIG exec -it $PANEL_POD -n $NAMESPACE -- php artisan p:user:make --admin [email]"
    echo ""
    echo "Delete user:"
    echo "  kubectl --kubeconfig=$KUBECONFIG exec -it $PANEL_POD -n $NAMESPACE -- php artisan p:user:delete [email]"
    echo ""
    echo "Reset user password:"
    echo "  kubectl --kubeconfig=$KUBECONFIG exec -it $PANEL_POD -n $NAMESPACE -- php artisan p:user:password [email]"
    echo ""
}

# Main execution
main() {
    echo "=================================="
    echo " Pterodactyl User Creation Script"
    echo "=================================="
    
    # Pre-flight checks
    check_kubectl
    find_panel_pod
    
    # Create the user
    create_user
    
    # Show additional commands
    show_additional_commands
    
    echo "=================================="
    log_success "Script completed! 🎉"
    echo "=================================="
}

# Handle Ctrl+C gracefully
trap 'echo ""; log_warning "Script interrupted by user"; exit 1' INT

# Run main function
main "$@" 