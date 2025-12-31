#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="Authentik Credentials"
ITEM_CATEGORY="password"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Check if 1Password CLI is installed
check_op_cli() {
    if ! command -v op &> /dev/null; then
        log_error "1Password CLI (op) is not installed"
        log_info "Please install it from: https://developer.1password.com/docs/cli/get-started/"
        exit 1
    fi
    
    log_success "1Password CLI is installed"
    
    # Check if signed in
    if ! op vault list &> /dev/null; then
        log_error "Not signed in to 1Password CLI"
        log_info "Please run: eval \$(op signin)"
        exit 1
    fi
    
    log_success "Signed in to 1Password CLI"
}

# Check if vault exists
check_vault() {
    if ! op vault get "$VAULT_NAME" &> /dev/null; then
        log_error "Vault '$VAULT_NAME' not found"
        exit 1
    fi
    
    log_success "Vault '$VAULT_NAME' found"
}

# Generate secure secret key (base64, 32 bytes)
generate_secret_key() {
    openssl rand -base64 32
}

# Generate secure password
generate_password() {
    # Generate a 32-character random password
    openssl rand -base64 24 | tr -d "=+/" | cut -c1-32
}

# Generate secure token
generate_token() {
    # Generate a 32-character random token
    openssl rand -hex 16
}

# Get current item if it exists
get_current_item() {
    log_info "Checking if item exists..."
    
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        CURRENT_SECRET_KEY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="secret_key" 2>/dev/null || echo "")
        CURRENT_BOOTSTRAP_PASSWORD=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="bootstrap_password" 2>/dev/null || echo "")
        CURRENT_BOOTSTRAP_TOKEN=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="bootstrap_token" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_SECRET_KEY=""
        CURRENT_BOOTSTRAP_PASSWORD=""
        CURRENT_BOOTSTRAP_TOKEN=""
    fi
}

# Collect input
collect_input() {
    echo
    log_info "=== Authentik Credentials Configuration ==="
    echo
    
    # Secret Key
    echo -n "Generate new secret key? [Y/n]: "
    read generate_sk
    if [[ "$generate_sk" =~ ^[Nn]$ ]]; then
        if [ -n "$CURRENT_SECRET_KEY" ]; then
            echo -n "Secret key [current: ****]: "
        else
            echo -n "Secret key: "
        fi
        read -s SECRET_KEY
        echo
    else
        SECRET_KEY=$(generate_secret_key)
        log_success "Generated secure secret key"
    fi
    
    # Bootstrap Password
    echo -n "Generate bootstrap password? [Y/n]: "
    read generate_bp
    if [[ "$generate_bp" =~ ^[Nn]$ ]]; then
        if [ -n "$CURRENT_BOOTSTRAP_PASSWORD" ]; then
            echo -n "Bootstrap password [current: ****]: "
        else
            echo -n "Bootstrap password: "
        fi
        read -s BOOTSTRAP_PASSWORD
        echo
    else
        BOOTSTRAP_PASSWORD=$(generate_password)
        log_success "Generated secure bootstrap password"
    fi
    
    # Bootstrap Token
    echo -n "Generate bootstrap token? [Y/n]: "
    read generate_bt
    if [[ "$generate_bt" =~ ^[Nn]$ ]]; then
        if [ -n "$CURRENT_BOOTSTRAP_TOKEN" ]; then
            echo -n "Bootstrap token [current: ****]: "
        else
            echo -n "Bootstrap token: "
        fi
        read -s BOOTSTRAP_TOKEN
        echo
    else
        BOOTSTRAP_TOKEN=$(generate_token)
        log_success "Generated secure bootstrap token"
    fi
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  Secret Key: **** (generated)"
    echo "  Bootstrap Password: ****"
    echo "  Bootstrap Token: ****"
    echo
    
    echo -n "Proceed with $(if [ "$ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        return 1
    fi
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        
        op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
            --url="https://auth.tkuipers.ca" \
            "secret_key=$SECRET_KEY" \
            "bootstrap_password=$BOOTSTRAP_PASSWORD" \
            "bootstrap_token=$BOOTSTRAP_TOKEN" \
            "bootstrap_email=tkuipers123@gmail.com" \
            "postgresql_host=authentik-postgresql" \
            "postgresql_port=5432" \
            "postgresql_db=authentik" \
            "redis_host=authentik-redis" \
            "redis_port=6379" \
            "external_host=https://auth.tkuipers.ca" \
            "external_host_https=true"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            --url="https://auth.tkuipers.ca" \
            "secret_key=$SECRET_KEY" \
            "bootstrap_password=$BOOTSTRAP_PASSWORD" \
            "bootstrap_token=$BOOTSTRAP_TOKEN" \
            "bootstrap_email=tkuipers123@gmail.com" \
            "postgresql_host=authentik-postgresql" \
            "postgresql_port=5432" \
            "postgresql_db=authentik" \
            "redis_host=authentik-redis" \
            "redis_port=6379" \
            "external_host=https://auth.tkuipers.ca" \
            "external_host_https=true"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Authentik credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. External Secrets Operator will automatically sync credentials to Kubernetes"
    echo "2. Create ArgoCD Application for Authentik (task 1.6)"
    echo "3. Authentik will bootstrap with:"
    echo "   - Email: tkuipers123@gmail.com"
    echo "   - Password: (configured above)"
    echo "   - Token: (configured above)"
    echo "4. Access Authentik at: https://auth.tkuipers.ca"
    echo
    log_info "To verify secrets are synced:"
    echo "  kubectl get secret authentik-credentials -n authentik"
    echo "  kubectl get externalsecret authentik-credentials -n authentik"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   Authentik Credentials Setup"
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

