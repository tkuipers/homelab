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
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_BRAVE_KEY=""
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
    
    # Allow adding more API keys in the future
    echo
    log_info "Additional API keys can be added later by running this script again"
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  Brave Search API Key: ${BRAVE_API_KEY:+****}"
    echo
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        
        # Build the edit command dynamically based on what was provided
        EDIT_ARGS=()
        [ -n "$BRAVE_API_KEY" ] && EDIT_ARGS+=("brave_api_key[password]=$BRAVE_API_KEY")
        
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
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger FluxCD deployment"
    echo "2. External Secrets Operator will automatically sync the API keys"
    echo "3. The 'mcp-api-keys' secret will be created in the ml namespace"
    echo "4. MCP server sidecars in Open WebUI will use these keys automatically"
    echo
    log_info "To monitor the deployment:"
    echo "  kubectl get externalsecrets -n ml"
    echo "  kubectl get secrets -n ml"
    echo "  kubectl get pods -n ml"
    echo
    log_info "To configure MCP servers in Open WebUI:"
    echo "  1. Navigate to Admin Settings → External Tools"
    echo "  2. Add servers with type 'OpenAPI' at these URLs:"
    echo "     - http://localhost:8001 (Brave Search)"
    echo "     - http://localhost:8002 (Fetch)"
    echo "     - http://localhost:8003 (Memory)"
    echo "     - http://localhost:8004 (Time)"
    echo "     - http://localhost:8005 (Filesystem)"
    echo "     - http://localhost:8006 (Git)"
    echo
    log_info "To retrieve keys later from 1Password:"
    echo "  op item get '$ITEM_NAME' --vault='$VAULT_NAME' --fields='brave_api_key'"
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

