#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ADMIN_ITEM_NAME="Guacamole Admin Credentials"
POSTGRES_ITEM_NAME="Guacamole PostgreSQL Credentials"
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

# Get current admin item if it exists
get_current_admin_item() {
    log_info "Checking if item '$ADMIN_ITEM_NAME' exists..."
    
    if op item get "$ADMIN_ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ADMIN_ITEM_NAME' found"
        ADMIN_ITEM_EXISTS=true
        
        # Get current values
        CURRENT_ADMIN_PASSWORD=$(op item get "$ADMIN_ITEM_NAME" --vault="$VAULT_NAME" --fields="password" 2>/dev/null || echo "")
    else
        log_info "Item '$ADMIN_ITEM_NAME' does not exist - will create new item"
        ADMIN_ITEM_EXISTS=false
        CURRENT_ADMIN_PASSWORD=""
    fi
}

# Get current postgres item if it exists
get_current_postgres_item() {
    log_info "Checking if item '$POSTGRES_ITEM_NAME' exists..."
    
    if op item get "$POSTGRES_ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$POSTGRES_ITEM_NAME' found"
        POSTGRES_ITEM_EXISTS=true
        
        # Get current values
        CURRENT_POSTGRES_PASSWORD=$(op item get "$POSTGRES_ITEM_NAME" --vault="$VAULT_NAME" --fields="postgres_password" 2>/dev/null || echo "")
        CURRENT_USERNAME=$(op item get "$POSTGRES_ITEM_NAME" --vault="$VAULT_NAME" --fields="username" 2>/dev/null || echo "")
        CURRENT_USER_PASSWORD=$(op item get "$POSTGRES_ITEM_NAME" --vault="$VAULT_NAME" --fields="password" 2>/dev/null || echo "")
        CURRENT_DATABASE=$(op item get "$POSTGRES_ITEM_NAME" --vault="$VAULT_NAME" --fields="database" 2>/dev/null || echo "")
    else
        log_info "Item '$POSTGRES_ITEM_NAME' does not exist - will create new item"
        POSTGRES_ITEM_EXISTS=false
        CURRENT_POSTGRES_PASSWORD=""
        CURRENT_USERNAME=""
        CURRENT_USER_PASSWORD=""
        CURRENT_DATABASE=""
    fi
}

# Collect admin credentials input
collect_admin_input() {
    echo
    log_info "=== Guacamole Admin Credentials ==="
    echo
    
    # Admin Password
    while true; do
        prompt_for_input "Guacamole Admin Password" ADMIN_PASSWORD "$CURRENT_ADMIN_PASSWORD" true
        if [ -z "$ADMIN_PASSWORD" ]; then
            log_error "Admin password is required"
            continue
        fi
        if validate_password "$ADMIN_PASSWORD"; then
            break
        fi
    done
}

# Collect PostgreSQL credentials input
collect_postgres_input() {
    echo
    log_info "=== PostgreSQL Database Credentials ==="
    echo
    
    # PostgreSQL admin password
    while true; do
        prompt_for_input "PostgreSQL Admin Password" POSTGRES_PASSWORD "$CURRENT_POSTGRES_PASSWORD" true
        if [ -z "$POSTGRES_PASSWORD" ]; then
            log_error "PostgreSQL admin password is required"
            continue
        fi
        if validate_password "$POSTGRES_PASSWORD"; then
            break
        fi
    done
    
    # Database username
    prompt_for_input "Database Username" USERNAME "$CURRENT_USERNAME"
    if [ -z "$USERNAME" ]; then
        USERNAME="guacamole"
        log_info "Using default username: guacamole"
    fi
    
    # Database user password
    while true; do
        prompt_for_input "Database User Password" USER_PASSWORD "$CURRENT_USER_PASSWORD" true
        if [ -z "$USER_PASSWORD" ]; then
            log_error "Database user password is required"
            continue
        fi
        if validate_password "$USER_PASSWORD"; then
            break
        fi
    done
    
    # Database name
    prompt_for_input "Database Name" DATABASE "$CURRENT_DATABASE"
    if [ -z "$DATABASE" ]; then
        DATABASE="guacamole"
        log_info "Using default database name: guacamole"
    fi
}

# Create or update admin item
create_or_update_admin_item() {
    echo
    log_info "Admin credentials summary:"
    echo "  Password: ****"
    echo
    
    echo -n "Proceed with admin credentials $(if [ "$ADMIN_ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Admin credentials operation cancelled"
        return 1
    fi
    
    if [ "$ADMIN_ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing admin item..."
        
        op item edit "$ADMIN_ITEM_NAME" --vault="$VAULT_NAME" \
            "password[password]=$ADMIN_PASSWORD"
        
        log_success "Item '$ADMIN_ITEM_NAME' updated successfully"
    else
        log_info "Creating new admin item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ADMIN_ITEM_NAME" \
            "password[password]=$ADMIN_PASSWORD"
        
        log_success "Item '$ADMIN_ITEM_NAME' created successfully"
    fi
}

# Create or update postgres item
create_or_update_postgres_item() {
    echo
    log_info "PostgreSQL credentials summary:"
    echo "  Postgres Password: ****"
    echo "  Username: $USERNAME"
    echo "  User Password: ****"
    echo "  Database: $DATABASE"
    echo
    
    echo -n "Proceed with PostgreSQL credentials $(if [ "$POSTGRES_ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "PostgreSQL credentials operation cancelled"
        return 1
    fi
    
    if [ "$POSTGRES_ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing PostgreSQL item..."
        
        op item edit "$POSTGRES_ITEM_NAME" --vault="$VAULT_NAME" \
            "postgres_password[password]=$POSTGRES_PASSWORD" \
            "username[text]=$USERNAME" \
            "password[password]=$USER_PASSWORD" \
            "database[text]=$DATABASE"
        
        log_success "Item '$POSTGRES_ITEM_NAME' updated successfully"
    else
        log_info "Creating new PostgreSQL item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$POSTGRES_ITEM_NAME" \
            "postgres_password[password]=$POSTGRES_PASSWORD" \
            "username[text]=$USERNAME" \
            "password[password]=$USER_PASSWORD" \
            "database[text]=$DATABASE"
        
        log_success "Item '$POSTGRES_ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Guacamole credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger FluxCD deployment"
    echo "2. External Secrets Operator will automatically sync credentials"
    echo "3. Access Guacamole at: https://guacamole.tkuipers.ca"
    echo "4. Login with username: guacadmin and your configured password"
    echo
    log_info "To monitor the deployment:"
    echo "  kubectl get externalsecrets -n guacamole"
    echo "  kubectl get secrets -n guacamole"
    echo "  kubectl get pods -n guacamole"
    echo
    log_info "Admin login:"
    echo "  Username: guacadmin"
    echo "  Password: [Your configured admin password]"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "    Guacamole Credentials Setup"
    echo "========================================="
    echo
    
    check_op_cli
    check_vault
    
    get_current_admin_item
    get_current_postgres_item
    
    collect_admin_input
    collect_postgres_input
    
    create_or_update_admin_item
    create_or_update_postgres_item
    
    show_next_steps
}

# Run main function
main "$@" 