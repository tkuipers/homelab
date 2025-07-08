#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="Pterodactyl Panel"
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

# Function to generate a Laravel app key
generate_app_key() {
    # Generate a 32-byte base64 encoded key for Laravel
    local key=$(openssl rand -base64 32)
    echo "base64:$key"
}

# Function to generate a secure password
generate_password() {
    local length="${1:-32}"
    # Generate password with letters, numbers, and safe special characters
    openssl rand -base64 $length | tr -d "=+/" | cut -c1-$length
}

# Function to prompt for input with validation
prompt_for_input() {
    local prompt="$1"
    local var_name="$2"
    local current_value="${3:-}"
    local is_secret="${4:-false}"
    local allow_generate="${5:-false}"
    
    if [ -n "$current_value" ]; then
        if [ "$is_secret" = "true" ]; then
            echo -n "$prompt [current: ****]: "
        else
            echo -n "$prompt [current: $current_value]: "
        fi
    else
        if [ "$allow_generate" = "true" ]; then
            echo -n "$prompt (or press Enter to generate): "
        else
            echo -n "$prompt: "
        fi
    fi
    
    if [ "$is_secret" = "true" ] && [ "$allow_generate" = "false" ]; then
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

# Function to validate password strength
validate_password() {
    local password="$1"
    local min_length=12
    
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

# Get current item if it exists
get_current_item() {
    log_info "Checking if item '$ITEM_NAME' exists..."
    
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        
        # Get current values
        CURRENT_APP_KEY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="app-key" 2>/dev/null || echo "")
        CURRENT_DB_PASSWORD=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="database-password" 2>/dev/null || echo "")
        CURRENT_MYSQL_ROOT_PASSWORD=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="mysql-root-password" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_APP_KEY=""
        CURRENT_DB_PASSWORD=""
        CURRENT_MYSQL_ROOT_PASSWORD=""
    fi
}

# Collect input from user
collect_input() {
    echo
    log_info "Please provide the Pterodactyl credentials:"
    echo
    
    # App Key
    prompt_for_input "Laravel App Key" APP_KEY "$CURRENT_APP_KEY" true true
    if [ -z "$APP_KEY" ]; then
        APP_KEY=$(generate_app_key)
        log_success "Generated Laravel app key"
    fi
    
    # Database Password
    prompt_for_input "Database Password" DB_PASSWORD "$CURRENT_DB_PASSWORD" true true
    if [ -z "$DB_PASSWORD" ]; then
        DB_PASSWORD=$(generate_password 24)
        log_success "Generated database password"
    else
        if ! validate_password "$DB_PASSWORD"; then
            return 1
        fi
    fi
    
    # MySQL Root Password
    prompt_for_input "MySQL Root Password" MYSQL_ROOT_PASSWORD "$CURRENT_MYSQL_ROOT_PASSWORD" true true
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        MYSQL_ROOT_PASSWORD=$(generate_password 32)
        log_success "Generated MySQL root password"
    else
        if ! validate_password "$MYSQL_ROOT_PASSWORD"; then
            return 1
        fi
    fi
}

# Create or update the item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  App Key: ****"
    echo "  Database Password: ****"
    echo "  MySQL Root Password: ****"
    echo
    
    echo -n "Proceed with $(if [ "$ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        
        # Update each field
        op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
            "app-key[password]=$APP_KEY" \
            "database-password[password]=$DB_PASSWORD" \
            "mysql-root-password[password]=$MYSQL_ROOT_PASSWORD"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        # Create new item with custom fields
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "app-key[password]=$APP_KEY" \
            "database-password[password]=$DB_PASSWORD" \
            "mysql-root-password[password]=$MYSQL_ROOT_PASSWORD" \
            "notesPlain=Pterodactyl Panel credentials for games.tkuipers.ca"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Verify the created/updated item
verify_item() {
    echo
    log_info "Verifying 1Password item..."
    
    # Test reading each field
    local test_app_key=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="app-key" 2>/dev/null || echo "")
    local test_db_pass=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="database-password" 2>/dev/null || echo "")
    local test_mysql_pass=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="mysql-root-password" 2>/dev/null || echo "")
    
    if [ -n "$test_app_key" ] && [ -n "$test_db_pass" ] && [ -n "$test_mysql_pass" ]; then
        log_success "All credentials stored and accessible in 1Password"
    else
        log_error "Failed to verify some credentials in 1Password"
        exit 1
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Pterodactyl credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger FluxCD deployment"
    echo "2. Monitor the deployment:"
    echo "   kubectl get hr pterodactyl -n flux-system"
    echo "   kubectl get pods -n pterodactyl"
    echo "3. Once deployed, create an admin user:"
    echo "   kubectl exec -it deployment/pterodactyl-panel -n pterodactyl -- php artisan p:user:make"
    echo "4. Access the panel at: https://games.tkuipers.ca"
    echo
    log_info "The External Secret will automatically sync these credentials to Kubernetes"
    echo "and Flux will substitute them into the HelmRelease values."
    echo
    log_warning "Important: Keep these credentials secure and rotate them periodically!"
}

# Main execution
main() {
    echo "🦀 Pterodactyl Panel Credentials Setup"
    echo "====================================="
    echo
    
    # Prerequisites checks
    check_op_cli
    check_vault
    
    # Get current state
    get_current_item
    
    # Collect input
    if ! collect_input; then
        log_error "Failed to collect valid input"
        exit 1
    fi
    
    # Create or update
    create_or_update_item
    
    # Verify
    verify_item
    
    # Show next steps
    show_next_steps
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 