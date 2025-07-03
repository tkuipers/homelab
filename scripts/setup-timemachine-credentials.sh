#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="Time Machine Backup"
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

# Function to validate password strength
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

# Get current item if it exists
get_current_item() {
    log_info "Checking if item '$ITEM_NAME' exists..."
    
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        
        # Get current values
        CURRENT_USERNAME=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="username" 2>/dev/null || echo "")
        CURRENT_PASSWORD=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="password" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_USERNAME=""
        CURRENT_PASSWORD=""
    fi
}

# Collect input from user
collect_input() {
    echo
    log_info "Please provide the Time Machine SMB credentials:"
    echo
    
    # Username
    prompt_for_input "SMB Username" USERNAME "$CURRENT_USERNAME"
    if [ -z "$USERNAME" ]; then
        USERNAME="timemachine"
        log_info "Using default username: timemachine"
    fi
    
    # Password
    while true; do
        prompt_for_input "SMB Password" PASSWORD "$CURRENT_PASSWORD" true
        if [ -z "$PASSWORD" ]; then
            log_error "Password is required"
            continue
        fi
        if validate_password "$PASSWORD"; then
            break
        fi
    done
}

# Create or update the item
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
        exit 0
    fi
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        
        # Update each field
        op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
            "username[text]=$USERNAME" \
            "password[password]=$PASSWORD"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        # Create new item
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "username[text]=$USERNAME" \
            "password[password]=$PASSWORD"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Time Machine credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger FluxCD deployment"
    echo "2. External Secrets Operator will automatically sync credentials"
    echo "3. Time Machine service will restart with new credentials"
    echo "4. Configure your Mac to use the Time Machine backup:"
    echo "   - SMB Server: timemachine.tkuipers.ca (or your cluster IP)"
    echo "   - Username: $USERNAME"
    echo "   - Password: [Your configured password]"
    echo
    log_info "To monitor the deployment:"
    echo "  kubectl get externalsecrets -n timemachine"
    echo "  kubectl get secrets -n timemachine"
    echo "  kubectl get pods -n timemachine"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   Time Machine Credentials Setup"
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