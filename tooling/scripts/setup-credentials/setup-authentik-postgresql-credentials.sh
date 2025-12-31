#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="Authentik PostgreSQL"
ITEM_CATEGORY="database"

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

# Generate secure password
generate_password() {
    # Generate a 32-character random password
    openssl rand -base64 24 | tr -d "=+/" | cut -c1-32
}

# Get current item if it exists
get_current_item() {
    log_info "Checking if item exists..."
    
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        CURRENT_USERNAME=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="username" 2>/dev/null || echo "authentik")
        CURRENT_PASSWORD=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="password" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_USERNAME="authentik"
        CURRENT_PASSWORD=""
    fi
}

# Collect input
collect_input() {
    echo
    log_info "=== Authentik PostgreSQL Credentials Configuration ==="
    echo
    
    echo -n "PostgreSQL username [default: authentik]: "
    read user_input
    if [ -z "$user_input" ]; then
        USERNAME="authentik"
    else
        USERNAME="$user_input"
    fi
    
    echo -n "Generate random password? [Y/n]: "
    read generate_pw
    if [[ "$generate_pw" =~ ^[Nn]$ ]]; then
        echo -n "PostgreSQL password: "
        read -s PASSWORD
        echo
    else
        PASSWORD=$(generate_password)
        log_success "Generated secure password"
    fi
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  Username: $USERNAME"
    echo "  Password: ****"
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
            "username=$USERNAME" \
            "password=$PASSWORD"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "username=$USERNAME" \
            "password=$PASSWORD"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Authentik PostgreSQL credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger ArgoCD deployment"
    echo "2. External Secrets Operator will automatically sync credentials"
    echo "3. PostgreSQL will start and create the 'authentik' database"
    echo "4. Verify PostgreSQL is running: kubectl get pods -n authentik"
    echo
    log_info "Connection details:"
    echo "  Host: authentik-postgresql.authentik.svc.cluster.local"
    echo "  Port: 5432"
    echo "  Database: authentik"
    echo "  Username: $USERNAME"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   Authentik PostgreSQL Credentials Setup"
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

