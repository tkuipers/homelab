#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="Dreame Vacuum"
ITEM_CATEGORY="login"

# Country codes accepted by the dreame-vacuum integration's Dreamehome cloud login (v2.x).
# (Different from Mi cloud's list — no de/tw/in/i2; eu replaces de, kr added.)
VALID_COUNTRIES=("eu" "cn" "us" "ru" "sg" "kr")

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
        echo
    else
        read input
    fi

    if [ -z "$input" ] && [ -n "$current_value" ]; then
        input="$current_value"
    fi

    eval "$var_name='$input'"
}

check_op_cli() {
    if ! command -v op &> /dev/null; then
        log_error "1Password CLI (op) is not installed or not in PATH"
        log_info "Install it from: https://developer.1password.com/docs/cli/get-started/"
        exit 1
    fi

    if ! op account get &> /dev/null; then
        log_error "Not signed in to 1Password CLI"
        log_info "Run: op signin"
        exit 1
    fi

    log_success "1Password CLI is available and signed in"
}

check_vault() {
    if ! op vault get "$VAULT_NAME" &> /dev/null; then
        log_error "Vault '$VAULT_NAME' not found"
        log_info "Available vaults:"
        op vault list
        exit 1
    fi

    log_success "Vault '$VAULT_NAME' found"
}

get_current_item() {
    log_info "Checking if item '$ITEM_NAME' exists in vault '$VAULT_NAME'..."

    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true

        CURRENT_USERNAME=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="username" 2>/dev/null || echo "")
        CURRENT_PASSWORD=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="password" 2>/dev/null || echo "")
        CURRENT_COUNTRY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="country" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_USERNAME=""
        CURRENT_PASSWORD=""
        CURRENT_COUNTRY=""
    fi
}

is_valid_country() {
    local candidate="$1"
    for c in "${VALID_COUNTRIES[@]}"; do
        if [ "$c" = "$candidate" ]; then
            return 0
        fi
    done
    return 1
}

collect_input() {
    echo
    log_info "=== Dreame Vacuum (Dreamehome Cloud) Credentials ==="
    echo
    log_info "These are your Dreamehome app account credentials — same email + password"
    log_info "you use to log in to the Dreame Home app on your phone."
    log_info "Used by the dreame-vacuum v2.x custom_component (account_type=dreame)."
    echo
    log_info "Valid country codes: ${VALID_COUNTRIES[*]}"
    log_info "  eu=Europe  cn=China  us=USA  ru=Russia  sg=Singapore  kr=Korea"
    echo

    prompt_for_input "Dreamehome account email" USERNAME "$CURRENT_USERNAME"
    if [ -z "$USERNAME" ]; then
        log_error "Username is required"
        exit 1
    fi

    prompt_for_input "Dreamehome account password" PASSWORD "$CURRENT_PASSWORD" true
    if [ -z "$PASSWORD" ]; then
        log_error "Password is required"
        exit 1
    fi

    while true; do
        prompt_for_input "Server country code" COUNTRY "$CURRENT_COUNTRY"
        if [ -z "$COUNTRY" ]; then
            log_error "Country is required"
            continue
        fi
        if is_valid_country "$COUNTRY"; then
            break
        fi
        log_error "Invalid country '$COUNTRY'. Must be one of: ${VALID_COUNTRIES[*]}"
    done
}

create_or_update_item() {
    echo
    log_info "Credentials summary:"
    echo "  Username: $USERNAME"
    echo "  Password: ****"
    echo "  Country:  $COUNTRY"
    echo

    echo -n "Proceed with credentials $(if [ "$ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi

    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."

        op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
            "username[text]=$USERNAME" \
            "password[password]=$PASSWORD" \
            "country[text]=$COUNTRY"

        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."

        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "username[text]=$USERNAME" \
            "password[password]=$PASSWORD" \
            "country[text]=$COUNTRY"

        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

show_next_steps() {
    echo
    log_success "Dreame Vacuum credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger ArgoCD sync"
    echo "2. External Secrets Operator will sync the 'homeassistant-dreame-vacuum' secret"
    echo "3. The reconciler will configure the Dreame Vacuum integration in HA automatically"
    echo
    log_warning "If your Xiaomi account requires 2FA or a captcha at login, the reconciler"
    log_warning "cannot complete the flow headlessly. Watch the reconciler Job logs and"
    log_warning "finish the flow in the HA UI (Settings > Devices > Add integration > Dreame Vacuum)"
    log_warning "if a captcha/2FA prompt is reported."
    echo
    log_info "To monitor:"
    echo "  kubectl get externalsecret homeassistant-dreame-vacuum -n homeassistant"
    echo "  kubectl get secret homeassistant-dreame-vacuum -n homeassistant"
    echo "  kubectl logs -n homeassistant -l job-name=homeassistant-reconciler --tail=50"
    echo
}

main() {
    echo "========================================="
    echo "   Dreame Vacuum Credentials Setup"
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
