#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="LLM Service API Key"
ITEM_CATEGORY="password"

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

# Generate a secure API key
generate_api_key() {
    # Generate a 64-character hex string (32 bytes)
    if command -v openssl &> /dev/null; then
        openssl rand -hex 32
    elif [ -r /dev/urandom ]; then
        # Use /dev/urandom with od (more portable than xxd)
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    elif command -v sha256sum &> /dev/null; then
        # Fallback: combine multiple entropy sources
        (date +%s%N; ps aux; echo $$) | sha256sum | cut -d' ' -f1
    else
        log_error "Unable to generate secure random key - no suitable tool found"
        log_info "Please install openssl or ensure /dev/urandom is available"
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
        
        # Get current API key (for display purposes only - we'll regenerate)
        CURRENT_API_KEY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="api_key" 2>/dev/null || echo "")
        if [ -n "$CURRENT_API_KEY" ]; then
            log_warning "Existing API key found - it will be replaced"
        fi
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_API_KEY=""
    fi
}

# Create or update item
create_or_update_item() {
    log_info "Generating new API key..."
    API_KEY=$(generate_api_key)
    
    echo
    log_info "Configuration summary:"
    echo "  Item: $ITEM_NAME"
    echo "  API Key: ${API_KEY:0:8}...${API_KEY: -8} (full key stored in 1Password)"
    echo
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        
        op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
            "api_key[password]=$API_KEY"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "api_key[password]=$API_KEY"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
    
    # Store the full key for display at the end
    GENERATED_API_KEY="$API_KEY"
}

# Show next steps
show_next_steps() {
    echo
    log_success "LLM Service API key is now configured in 1Password!"
    echo
    log_info "API Key Details:"
    echo "  Full Key: $GENERATED_API_KEY"
    echo "  (This key is also stored in 1Password: '$ITEM_NAME')"
    echo
    log_warning "IMPORTANT: Save this API key now - you'll need it to configure Cursor!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger FluxCD deployment"
    echo "2. External Secrets Operator will automatically sync the API key"
    echo "3. The 'llama-api-key' secret will be created in the ml namespace"
    echo "4. Configure Cursor to use:"
    echo "   - Base URL: https://llm.tkuipers.ca"
    echo "   - API Key: $GENERATED_API_KEY"
    echo
    log_info "To monitor the deployment:"
    echo "  kubectl get externalsecrets -n ml"
    echo "  kubectl get secrets -n ml"
    echo "  kubectl get pods -n ml"
    echo
    log_info "To retrieve the key later from 1Password:"
    echo "  op item get '$ITEM_NAME' --vault='$VAULT_NAME' --fields='api_key'"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   LLM Service API Key Setup"
    echo "========================================="
    echo
    
    check_op_cli
    check_vault
    get_current_item
    create_or_update_item
    show_next_steps
}

# Run main function
main "$@"

