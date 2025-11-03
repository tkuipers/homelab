#!/usr/bin/env bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
INDEXERS_ITEM_NAME="Prowlarr Indexers"
ITEM_CATEGORY="login"

# Predefined indexer list (name|description|baseurl triplets)
INDEXERS=(
    "NZBGeek|Popular general Usenet indexer with great retention|https://api.nzbgeek.info"
    "NZBFinder|Comprehensive Usenet indexer with excellent API|https://nzbfinder.ws"
    "DrunkenSlug|High-quality Usenet indexer with active community|https://api.drunkenslug.com"
    "AnimeTosho|Specialized in anime, Japanese media, and Asian content|https://feed.animetosho.org"
    "6box|Asian content specialist - Chinese dramas, K-dramas, and Asian TV|https://6box.me"
    "NinjaCentral|Well-rounded Usenet indexer with good coverage|https://ninjacentral.co.za"
)

# Helper function to get indexer name
get_indexer_name() {
    echo "$1" | cut -d'|' -f1
}

# Helper function to get indexer description
get_indexer_desc() {
    echo "$1" | cut -d'|' -f2
}

# Helper function to get indexer base URL
get_indexer_url() {
    echo "$1" | cut -d'|' -f3
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

log_header() {
    echo -e "${CYAN}$1${NC}"
}

# Function to prompt for input with validation
prompt_for_input() {
    local prompt="$1"
    local var_name="$2"
    local current_value="${3:-}"
    local is_secret="${4:-false}"
    local allow_skip="${5:-false}"
    
    if [ -n "$current_value" ]; then
        if [ "$is_secret" = "true" ]; then
            echo -n "$prompt [current: ****]: "
        else
            echo -n "$prompt [current: $current_value]: "
        fi
    else
        if [ "$allow_skip" = "true" ]; then
            echo -n "$prompt (or 'skip' to skip): "
        else
            echo -n "$prompt: "
        fi
    fi
    
    if [ "$is_secret" = "true" ]; then
        read -s user_input
        echo  # New line after password input
    else
        read user_input
    fi
    
    # Check for skip
    if [ "$allow_skip" = "true" ] && [ "$user_input" = "skip" ]; then
        eval "$var_name=\"SKIP\""
        return
    fi
    
    if [ -z "$user_input" ] && [ -n "$current_value" ]; then
        eval "$var_name=\"$current_value\""
    else
        eval "$var_name=\"$user_input\""
    fi
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

# Get current item if it exists
get_current_item() {
    log_info "Checking if item exists..."
    
    if op item get "$INDEXERS_ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$INDEXERS_ITEM_NAME' found"
        ITEM_EXISTS=true
    else
        log_info "Item '$INDEXERS_ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
    fi
}

# Get current value for a field
get_current_value() {
    local field_name="$1"
    if [ "$ITEM_EXISTS" = "true" ]; then
        op item get "$INDEXERS_ITEM_NAME" --vault="$VAULT_NAME" --fields="$field_name" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Collect indexer credentials
collect_indexer_credentials() {
    # Store data in simple variables instead of associative array
    INDEXER_NAMES=()
    INDEXER_URLS=()
    INDEXER_APIKEYS=()
    INDEXER_SKIPS=()
    
    echo
    log_header "========================================="
    log_header "   Available Indexers"
    log_header "========================================="
    echo
    
    for indexer_entry in "${INDEXERS[@]}"; do
        local name=$(get_indexer_name "$indexer_entry")
        local desc=$(get_indexer_desc "$indexer_entry")
        echo -e "${CYAN}${name}${NC}: ${desc}"
    done
    
    echo
    log_info "You'll be prompted for each indexer. Enter 'skip' to skip any indexer you don't have."
    echo
    
    local idx=1
    for indexer_entry in "${INDEXERS[@]}"; do
        local indexer_name=$(get_indexer_name "$indexer_entry")
        local indexer_desc=$(get_indexer_desc "$indexer_entry")
        local indexer_baseurl=$(get_indexer_url "$indexer_entry")
        
        echo
        log_header "--- Indexer ${idx}/${#INDEXERS[@]}: $indexer_name ---"
        echo -e "${indexer_desc}"
        echo
        
        # Get current values
        local current_url=$(get_current_value "indexer${idx}_url")
        local current_apikey=$(get_current_value "indexer${idx}_apikey")
        
        # Use base URL as default if no current value
        if [ -z "$current_url" ]; then
            current_url="$indexer_baseurl"
        fi
        
        # Prompt for URL
        prompt_for_input "Base URL" "url" "$current_url" false true
        
        if [ "$url" = "SKIP" ]; then
            log_warning "Skipping $indexer_name"
            INDEXER_SKIPS+=("true")
            INDEXER_NAMES+=("")
            INDEXER_URLS+=("")
            INDEXER_APIKEYS+=("")
        else
            # Prompt for API key
            prompt_for_input "API Key" "apikey" "$current_apikey" true false
            
            INDEXER_SKIPS+=("false")
            INDEXER_NAMES+=("$indexer_name")
            INDEXER_URLS+=("$url")
            INDEXER_APIKEYS+=("$apikey")
            
            log_success "$indexer_name configured!"
        fi
        
        idx=$((idx + 1))
    done
}

# Build op command arguments
build_op_args() {
    local args=""
    
    for idx in "${!INDEXER_SKIPS[@]}"; do
        local array_idx=$((idx))
        local item_idx=$((idx + 1))
        
        if [ "${INDEXER_SKIPS[$array_idx]}" != "true" ]; then
            args+=" indexer${item_idx}_name[text]=${INDEXER_NAMES[$array_idx]}"
            args+=" indexer${item_idx}_url[text]=${INDEXER_URLS[$array_idx]}"
            args+=" indexer${item_idx}_apikey[password]=${INDEXER_APIKEYS[$array_idx]}"
        fi
    done
    
    echo "$args"
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    
    for idx in "${!INDEXER_SKIPS[@]}"; do
        local array_idx=$((idx))
        local item_idx=$((idx + 1))
        
        if [ "${INDEXER_SKIPS[$array_idx]}" != "true" ]; then
            echo "  Indexer ${item_idx}: ${INDEXER_NAMES[$array_idx]}"
            echo "    URL: ${INDEXER_URLS[$array_idx]}"
            echo "    API Key: ****"
        fi
    done
    
    echo
    echo -n "Proceed with $(if [ "$ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        return 1
    fi
    
    local op_args=$(build_op_args)
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        
        op item edit "$INDEXERS_ITEM_NAME" --vault="$VAULT_NAME" $op_args
        
        log_success "Item '$INDEXERS_ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$INDEXERS_ITEM_NAME" \
            $op_args
        
        log_success "Item '$INDEXERS_ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Prowlarr indexer credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Update the mediacenter ExternalSecret to include all configured indexers"
    echo "2. Update the arr-integration-job to support multiple indexers"
    echo "3. Commit and push your changes to trigger FluxCD deployment"
    echo "4. The arr-integration-job will automatically:"
    echo "   - Add all configured indexers to Prowlarr"
    echo "   - Link Prowlarr to Sonarr and Radarr"
    echo "   - Sync indexers from Prowlarr to both apps"
    echo
    log_info "Access your services:"
    echo "  Prowlarr:    https://prowlarr.tkuipers.ca"
    echo "  Sonarr:      https://sonarr.tkuipers.ca"
    echo "  Radarr:      https://radarr.tkuipers.ca"
    echo
}

# Main execution
main() {
    log_header "========================================="
    log_header "   Prowlarr Multi-Indexer Setup"
    log_header "========================================="
    echo
    
    check_op_cli
    check_vault
    
    get_current_item
    
    collect_indexer_credentials
    create_or_update_item
    
    show_next_steps
}

# Run main function
main "$@"
