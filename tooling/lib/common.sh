#!/bin/bash
# Common utilities for homelab scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

set -euo pipefail

# =============================================================================
# Colors and Logging
# =============================================================================

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

# =============================================================================
# 1Password CLI Helpers
# =============================================================================

VAULT_NAME="${OP_VAULT_NAME:-Homelab}"

# Check if op CLI is available and signed in
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

# Check if 1Password item exists
op_item_exists() {
    local item_name="$1"
    op item get "$item_name" --vault="$VAULT_NAME" &> /dev/null
}

# Get field from 1Password item
op_get_field() {
    local item_name="$1"
    local field_name="$2"
    op item get "$item_name" --vault="$VAULT_NAME" --fields="$field_name" 2>/dev/null || echo ""
}

# Create 1Password item
op_create_item() {
    local item_name="$1"
    local category="${2:-login}"
    shift 2
    # Remaining arguments are field definitions like "field_name[type]=value"
    op item create --vault="$VAULT_NAME" \
        --category="$category" \
        --title="$item_name" \
        "$@"
}

# Update 1Password item
op_update_item() {
    local item_name="$1"
    shift
    # Remaining arguments are field definitions
    op item edit "$item_name" --vault="$VAULT_NAME" "$@"
}

# =============================================================================
# Input Helpers
# =============================================================================

# Prompt for input with optional current value display
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

# Confirm action with user
confirm_action() {
    local message="${1:-Proceed?}"
    echo -n "$message [y/N]: "
    read confirm
    [[ "$confirm" =~ ^[Yy]$ ]]
}

# =============================================================================
# Password Generation
# =============================================================================

generate_password() {
    local length="${1:-16}"
    if command -v openssl &> /dev/null; then
        openssl rand -base64 32 | tr -d "=+/" | cut -c1-"$length"
    elif [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
    else
        log_error "Unable to generate secure password - no suitable tool found"
        exit 1
    fi
}

# =============================================================================
# Kubernetes Helpers
# =============================================================================

KUBECONFIG="${KUBECONFIG:-cluster-configs/kubeconfig}"

# Check if kubectl can connect
check_kubectl() {
    if ! kubectl --kubeconfig="$KUBECONFIG" cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig at $KUBECONFIG"
        exit 1
    fi
    log_success "Connected to Kubernetes cluster"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

