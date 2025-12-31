#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="Monitoring Stack Credentials"
ITEM_CATEGORY="login"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Function to prompt for input with validation
prompt_for_input() {
    local prompt="$1"
    local var_name="$2"
    local current_value="${3:-}"
    local is_secret="${4:-false}"
    
    if [ -n "$current_value" ]; then
        if [ "$is_secret" = "true" ]; then
            echo -n "$prompt [current: ****]: "
        else
            echo -n "$prompt [current: $current_value]: "
        fi
    else
        echo -n "$prompt: "
    fi
    
    if [ "$is_secret" = "true" ]; then
        read -s input
        echo  # Add newline after hidden input
    else
        read input
    fi
    
    # Use current value if no input provided
    if [ -z "$input" ] && [ -n "$current_value" ]; then
        input="$current_value"
    fi
    
    eval "$var_name='$input'"
}

# Function to validate password
validate_password() {
    local password="$1"
    local min_length=8
    
    if [ ${#password} -lt $min_length ]; then
        log_warning "Password is shorter than $min_length characters"
        echo -n "Continue anyway? [y/N]: "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    return 0
}

# Generate a secure password
generate_password() {
    if command -v openssl &> /dev/null; then
        # Generate 16 character alphanumeric password
        openssl rand -base64 24 | tr -d "=+/" | cut -c1-16
    elif [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
    else
        log_error "Unable to generate secure password - no suitable tool found"
        exit 1
    fi
}

# Check if op CLI is available
check_op_cli() {
    if ! command -v op &> /dev/null; then
        log_error "1Password CLI (op) is not installed or not in PATH"
        log_info "Install it from: https://developer.1password.com/docs/cli/get-started/"
        exit 1
    fi
    
    # Check if signed in
    if ! op account get &> /dev/null; then
        log_error "Not signed in to 1Password CLI"
        log_info "Run: op signin"
        exit 1
    fi
    
    log_success "1Password CLI is available and signed in"
}

# Check if vault exists
check_vault() {
    if ! op vault get "$VAULT_NAME" &> /dev/null; then
        log_error "Vault '$VAULT_NAME' not found"
        log_info "Available vaults:"
        op vault list
        exit 1
    fi
    
    log_success "Vault '$VAULT_NAME' found"
}

# Get current item if it exists
get_current_item() {
    log_info "Checking if item '$ITEM_NAME' exists..."
    
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        
        # Get current values
        CURRENT_GRAFANA_USER=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="grafana_user" 2>/dev/null || echo "")
        CURRENT_GRAFANA_PASSWORD=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="grafana_password" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_GRAFANA_USER=""
        CURRENT_GRAFANA_PASSWORD=""
    fi
}

# Collect credentials input
collect_input() {
    echo
    log_info "=== Monitoring Stack Credentials ==="
    echo
    
    # Grafana username
    prompt_for_input "Grafana Admin Username" GRAFANA_USER "$CURRENT_GRAFANA_USER"
    if [ -z "$GRAFANA_USER" ]; then
        GRAFANA_USER="admin"
        log_info "Using default username: admin"
    fi
    
    # Grafana password
    echo
    log_info "You can:"
    echo "  1. Enter a custom password"
    echo "  2. Leave blank to auto-generate a secure password"
    echo
    
    while true; do
        prompt_for_input "Grafana Admin Password" GRAFANA_PASSWORD "$CURRENT_GRAFANA_PASSWORD" true
        
        if [ -z "$GRAFANA_PASSWORD" ]; then
            log_info "Generating secure password..."
            GRAFANA_PASSWORD=$(generate_password)
            GENERATED_PASSWORD=true
            log_success "Password generated: $GRAFANA_PASSWORD"
            break
        fi
        
        if validate_password "$GRAFANA_PASSWORD"; then
            GENERATED_PASSWORD=false
            break
        fi
    done
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Credentials summary:"
    echo "  Grafana Username: $GRAFANA_USER"
    if [ "${GENERATED_PASSWORD:-false}" = "true" ]; then
        echo "  Grafana Password: $GRAFANA_PASSWORD (auto-generated)"
    else
        echo "  Grafana Password: ****"
    fi
    echo
    
    echo -n "Proceed with credentials $(if [ "$ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        
        op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
            "grafana_user[text]=$GRAFANA_USER" \
            "grafana_password[password]=$GRAFANA_PASSWORD"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "grafana_user[text]=$GRAFANA_USER" \
            "grafana_password[password]=$GRAFANA_PASSWORD"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Monitoring stack credentials are now configured in 1Password!"
    echo
    log_info "Login Details:"
    echo "  Grafana URL: https://grafana.tkuipers.ca"
    echo "  Username: $GRAFANA_USER"
    if [ "${GENERATED_PASSWORD:-false}" = "true" ]; then
        echo "  Password: $GRAFANA_PASSWORD"
        log_warning "Save this password now!"
    else
        echo "  Password: [Your configured password]"
    fi
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger FluxCD deployment"
    echo "2. External Secrets Operator will automatically sync credentials"
    echo "3. Access Grafana at: https://grafana.tkuipers.ca"
    echo "4. Prometheus at: https://prometheus.tkuipers.ca"
    echo "5. Alertmanager at: https://alertmanager.tkuipers.ca"
    echo
    log_info "To monitor the deployment:"
    echo "  kubectl get externalsecrets -n monitoring"
    echo "  kubectl get secrets -n monitoring"
    echo "  kubectl get pods -n monitoring"
    echo
    log_info "To retrieve credentials later from 1Password:"
    echo "  op item get '$ITEM_NAME' --vault='$VAULT_NAME' --fields='grafana_user'"
    echo "  op item get '$ITEM_NAME' --vault='$VAULT_NAME' --fields='grafana_password'"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   Monitoring Stack Credentials Setup"
    echo "========================================="
    echo
    
    check_op_cli
    check_vault
    get_current_item
    collect_input
    create_or_update_item
    show_next_steps
}

# Run main function
main "$@"

