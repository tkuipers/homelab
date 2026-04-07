#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="Anki Sync Server"
ITEM_CATEGORY="login"

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

    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        CURRENT_SYNC_USER1=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="sync_user1" 2>/dev/null || echo "")
        # Split stored user:password back into parts for display
        CURRENT_USERNAME="${CURRENT_SYNC_USER1%%:*}"
        CURRENT_PASSWORD="${CURRENT_SYNC_USER1#*:}"
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_USERNAME=""
        CURRENT_PASSWORD=""
    fi
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
            echo -n "$prompt_message [current: $default_value]: "
        fi
    else
        echo -n "$prompt_message: "
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

# Collect input
collect_input() {
    echo
    log_info "=== Anki Sync Server Credentials ==="
    log_info "These credentials are used by Anki clients to authenticate with anki.tkuipers.ca"
    echo

    prompt_for_input "Username" USERNAME "$CURRENT_USERNAME"
    prompt_for_input "Password" PASSWORD "$CURRENT_PASSWORD" true
}

# Create or update item
create_or_update_item() {
    local sync_user1="${USERNAME}:${PASSWORD}"

    echo
    log_info "Configuration summary:"
    echo "  Username:   $USERNAME"
    echo "  Password:   ****"
    echo "  sync_user1: ${USERNAME}:****"
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
            "password=$PASSWORD" \
            "sync_user1[password]=${sync_user1}"

        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."

        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "username=$USERNAME" \
            "password=$PASSWORD" \
            "sync_user1[password]=${sync_user1}" \
            "notesPlain=Anki sync server credentials for anki.tkuipers.ca. sync_user1 is the combined user:password value consumed by the ExternalSecret."

        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Anki sync server credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger ArgoCD deployment"
    echo "2. External Secrets Operator will automatically sync credentials to the cluster"
    echo "3. Watch the pod come up:"
    echo "   kubectl rollout status -n anki deployment/anki"
    echo
    log_info "Point Anki clients to your sync server:"
    echo "  Desktop: Tools > Preferences > Syncing > Self-hosted sync server"
    echo "  URL: https://anki.tkuipers.ca"
    echo "  Username: $USERNAME"
    echo
    log_warning "Note: Authelia is not used here - the sync server authenticates clients"
    log_warning "directly via the SYNC_USER1 credential, which is equivalent protection."
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "     Anki Sync Server Credentials Setup"
    echo "========================================="
    echo

    check_op_cli
    check_vault

    get_current_item

    collect_input
    create_or_update_item

    show_next_steps
}

main "$@"
