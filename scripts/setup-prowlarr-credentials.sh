#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
INDEXERS_ITEM_NAME="Prowlarr Indexers"
APPS_ITEM_NAME="Prowlarr Apps"
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

# Get current items if they exist
get_current_items() {
    log_info "Checking if items exist..."
    
    # Check Indexers item
    if op item get "$INDEXERS_ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$INDEXERS_ITEM_NAME' found"
        INDEXERS_EXISTS=true
        CURRENT_INDEXER1_NAME=$(op item get "$INDEXERS_ITEM_NAME" --vault="$VAULT_NAME" --fields="indexer1_name" 2>/dev/null || echo "")
        CURRENT_INDEXER1_URL=$(op item get "$INDEXERS_ITEM_NAME" --vault="$VAULT_NAME" --fields="indexer1_url" 2>/dev/null || echo "")
        CURRENT_INDEXER1_APIKEY=$(op item get "$INDEXERS_ITEM_NAME" --vault="$VAULT_NAME" --fields="indexer1_apikey" 2>/dev/null || echo "")
    else
        log_info "Item '$INDEXERS_ITEM_NAME' does not exist - will create new item"
        INDEXERS_EXISTS=false
        CURRENT_INDEXER1_NAME=""
        CURRENT_INDEXER1_URL=""
        CURRENT_INDEXER1_APIKEY=""
    fi
    
    # Check Apps item
    if op item get "$APPS_ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$APPS_ITEM_NAME' found"
        APPS_EXISTS=true
        CURRENT_SONARR_APIKEY=$(op item get "$APPS_ITEM_NAME" --vault="$VAULT_NAME" --fields="sonarr_api_key" 2>/dev/null || echo "")
    else
        log_info "Item '$APPS_ITEM_NAME' does not exist - will create new item"
        APPS_EXISTS=false
        CURRENT_SONARR_APIKEY=""
    fi
}

# Collect indexer input
collect_indexer_input() {
    echo
    log_info "=== Prowlarr Indexers Configuration ==="
    echo
    log_info "Configure your indexer (Newznab/Torznab). You can add more later."
    echo
    
    prompt_for_input "Indexer Name (e.g., NZBgeek)" INDEXER1_NAME "$CURRENT_INDEXER1_NAME"
    prompt_for_input "Indexer Base URL (e.g., https://api.nzbgeek.info)" INDEXER1_URL "$CURRENT_INDEXER1_URL"
    prompt_for_input "Indexer API Key" INDEXER1_APIKEY "$CURRENT_INDEXER1_APIKEY" true
}

# Collect apps input
collect_apps_input() {
    echo
    log_info "=== Prowlarr Apps Configuration ==="
    echo
    log_info "Note: You'll need to get the Sonarr API key after Sonarr starts"
    log_info "Find it at: Sonarr → Settings → General → API Key"
    echo
    
    prompt_for_input "Sonarr API Key" SONARR_APIKEY "$CURRENT_SONARR_APIKEY" true
}

# Create or update indexers item
create_or_update_indexers() {
    echo
    log_info "Indexers summary:"
    echo "  Name: $INDEXER1_NAME"
    echo "  URL: $INDEXER1_URL"
    echo "  API Key: ****"
    echo
    
    echo -n "Proceed with indexers $(if [ "$INDEXERS_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Indexers operation cancelled"
        return 1
    fi
    
    if [ "$INDEXERS_EXISTS" = "true" ]; then
        log_info "Updating existing indexers item..."
        
        op item edit "$INDEXERS_ITEM_NAME" --vault="$VAULT_NAME" \
            "indexer1_name[text]=$INDEXER1_NAME" \
            "indexer1_url[text]=$INDEXER1_URL" \
            "indexer1_apikey[password]=$INDEXER1_APIKEY"
        
        log_success "Item '$INDEXERS_ITEM_NAME' updated successfully"
    else
        log_info "Creating new indexers item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$INDEXERS_ITEM_NAME" \
            "indexer1_name[text]=$INDEXER1_NAME" \
            "indexer1_url[text]=$INDEXER1_URL" \
            "indexer1_apikey[password]=$INDEXER1_APIKEY"
        
        log_success "Item '$INDEXERS_ITEM_NAME' created successfully"
    fi
}

# Create or update apps item
create_or_update_apps() {
    echo
    log_info "Apps summary:"
    echo "  Sonarr API Key: ****"
    echo
    
    echo -n "Proceed with apps $(if [ "$APPS_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Apps operation cancelled"
        return 1
    fi
    
    if [ "$APPS_EXISTS" = "true" ]; then
        log_info "Updating existing apps item..."
        
        op item edit "$APPS_ITEM_NAME" --vault="$VAULT_NAME" \
            "sonarr_api_key[password]=$SONARR_APIKEY"
        
        log_success "Item '$APPS_ITEM_NAME' updated successfully"
    else
        log_info "Creating new apps item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$APPS_ITEM_NAME" \
            "sonarr_api_key[password]=$SONARR_APIKEY"
        
        log_success "Item '$APPS_ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Prowlarr credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger FluxCD deployment"
    echo "2. External Secrets Operator will automatically sync credentials"
    echo "3. Prowlarr will bootstrap automatically with your indexer"
    echo "4. The indexer will be synced to Sonarr automatically"
    echo
    log_info "To get the Sonarr API key:"
    echo "  1. Wait for Sonarr to start: kubectl -n mediacenter get pods"
    echo "  2. Access Sonarr at: https://sonarr.tkuipers.ca"
    echo "  3. Go to: Settings → General → Security → API Key"
    echo "  4. Run this script again to add the API key"
    echo
    log_info "To monitor the deployment:"
    echo "  kubectl get externalsecrets -n mediacenter"
    echo "  kubectl get secrets -n mediacenter"
    echo "  kubectl get pods -n mediacenter"
    echo "  kubectl -n mediacenter logs -f prowlarr-xxx -c bootstrap"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   Prowlarr Credentials Setup"
    echo "========================================="
    echo
    
    check_op_cli
    check_vault
    
    get_current_items
    
    collect_indexer_input
    create_or_update_indexers
    
    echo
    collect_apps_input
    create_or_update_apps
    
    show_next_steps
}

# Run main function
main "$@"

