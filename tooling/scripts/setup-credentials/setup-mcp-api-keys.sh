#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="MCP API Keys"
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

# Prompt for input with default value
prompt_for_input() {
    local prompt_message="$1"
    local var_name="$2"
    local default_value="${3:-}"
    local is_password="${4:-false}"
    
    if [ -n "$default_value" ]; then
        if [ "$is_password" = "true" ]; then
            echo -n "$prompt_message [current: ****]: "
        else
            echo -n "$prompt_message [current: ${default_value:0:8}...]: "
        fi
    else
        echo -n "$prompt_message [leave empty to skip]: "
    fi
    
    if [ "$is_password" = "true" ]; then
        read -s user_input
        echo  # New line after password input
    else
        read user_input
    fi
    
    if [ -z "$user_input" ] && [ -n "$default_value" ]; then
        eval "$var_name=\"$default_value\""
    else
        eval "$var_name=\"$user_input\""
    fi
}

# Get current item if it exists
get_current_item() {
    log_info "Checking if item '$ITEM_NAME' exists..."
    
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        
        # Get current API keys
        CURRENT_BRAVE_KEY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="brave_api_key" 2>/dev/null || echo "")
        CURRENT_MCPO_KEY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="mcpo_api_key" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_BRAVE_KEY=""
        CURRENT_MCPO_KEY=""
    fi
}

# Collect input
collect_input() {
    echo
    log_info "=== MCP API Keys Configuration ==="
    echo
    log_info "Configure API keys for MCP servers (Model Context Protocol tools)"
    echo
    log_info "Brave Search API Key:"
    echo "  - Get a free API key from: https://brave.com/search/api/"
    echo "  - Provides high-quality web search for AI agents"
    echo "  - Free tier: 2,000 queries/month"
    echo
    prompt_for_input "Brave API Key" BRAVE_API_KEY "$CURRENT_BRAVE_KEY" true
    
    echo
    log_info "MCPO API Key (for securing public MCP server access):"
    echo "  - Used to authenticate requests to the MCP server via ingress"
    echo "  - Will be auto-generated if not provided"
    echo
    
    if [ -n "$CURRENT_MCPO_KEY" ]; then
        read -p "Generate new MCPO API key? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Generating new MCPO API key..."
            MCPO_API_KEY=$(generate_api_key)
        else
            MCPO_API_KEY="$CURRENT_MCPO_KEY"
        fi
    else
        log_info "Generating new MCPO API key..."
        MCPO_API_KEY=$(generate_api_key)
    fi
    
    # Allow adding more API keys in the future
    echo
    log_info "Additional API keys can be added later by running this script again"
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  Brave Search API Key: ${BRAVE_API_KEY:+****}"
    echo "  MCPO API Key: ${MCPO_API_KEY:0:8}...${MCPO_API_KEY: -8}"
    echo
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        
        # Build the edit command dynamically based on what was provided
        EDIT_ARGS=()
        [ -n "$BRAVE_API_KEY" ] && EDIT_ARGS+=("brave_api_key[password]=$BRAVE_API_KEY")
        [ -n "$MCPO_API_KEY" ] && EDIT_ARGS+=("mcpo_api_key[password]=$MCPO_API_KEY")
        
        if [ ${#EDIT_ARGS[@]} -gt 0 ]; then
            op item edit "$ITEM_NAME" --vault="$VAULT_NAME" "${EDIT_ARGS[@]}"
            log_success "Item '$ITEM_NAME' updated successfully"
        else
            log_warning "No changes to make"
        fi
    else
        log_info "Creating new item..."
        
        # Build the create command
        CREATE_ARGS=()
        [ -n "$BRAVE_API_KEY" ] && CREATE_ARGS+=("brave_api_key[password]=$BRAVE_API_KEY")
        [ -n "$MCPO_API_KEY" ] && CREATE_ARGS+=("mcpo_api_key[password]=$MCPO_API_KEY")
        
        if [ ${#CREATE_ARGS[@]} -eq 0 ]; then
            log_error "At least one API key must be provided when creating a new item"
            exit 1
        fi
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "${CREATE_ARGS[@]}"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "MCP API keys are now configured in 1Password!"
    echo
    log_info "Configured services:"
    [ -n "$BRAVE_API_KEY" ] && echo "  ✓ Brave Search (web search)"
    [ -n "$MCPO_API_KEY" ] && echo "  ✓ MCPO API Key (${MCPO_API_KEY:0:8}...${MCPO_API_KEY: -8})"
    echo
    log_warning "IMPORTANT: Save the MCPO API key for Open WebUI configuration:"
    echo "  Bearer Token: $MCPO_API_KEY"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger FluxCD deployment"
    echo "2. External Secrets Operator will automatically sync the API keys"
    echo "3. The 'mcp-api-keys' secret will be created in the ml namespace"
    echo "4. MCP servers will be available at https://mcp.tkuipers.ca"
    echo
    log_info "To monitor the deployment:"
    echo "  kubectl get externalsecrets -n ml"
    echo "  kubectl get secrets -n ml"
    echo "  kubectl get pods -n ml"
    echo
    log_info "To configure MCP servers in Open WebUI:"
    echo "  1. Navigate to Admin Settings → External Tools"
    echo "  2. Add server with type 'MCP (Streamable HTTP)' or 'OpenAPI'"
    echo "  3. Server URL: https://mcp.tkuipers.ca"
    echo "  4. Auth Header: Authorization"
    echo "  5. Auth Value: Bearer $MCPO_API_KEY"
    echo
    log_info "To retrieve keys later from 1Password:"
    echo "  op item get '$ITEM_NAME' --vault='$VAULT_NAME' --fields='brave_api_key'"
    echo "  op item get '$ITEM_NAME' --vault='$VAULT_NAME' --fields='mcpo_api_key'"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   MCP API Keys Setup"
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

