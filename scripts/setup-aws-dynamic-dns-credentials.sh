#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="AWS Dynamic DNS Credentials"
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

# Function to validate AWS region
validate_aws_region() {
    local region="$1"
    # Basic AWS region format validation
    if [[ ! "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
        log_warning "Region format looks unusual. Expected format: us-east-1, eu-west-1, etc."
        echo -n "Continue anyway? [y/N]: "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    return 0
}

# Function to validate hosted zone ID
validate_hosted_zone_id() {
    local zone_id="$1"
    # Basic AWS hosted zone ID format validation
    if [[ ! "$zone_id" =~ ^Z[A-Z0-9]+$ ]]; then
        log_warning "Hosted Zone ID format looks unusual. Expected format: Z1234567890ABC"
        echo -n "Continue anyway? [y/N]: "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    return 0
}

# Function to validate record name
validate_record_name() {
    local record_name="$1"
    # DNS name validation - supports both regular domains and wildcard domains
    if [[ ! "$record_name" =~ ^(\*\.)?[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_warning "Record name format looks unusual. Expected format: example.com or *.example.com"
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
        CURRENT_ACCESS_KEY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="access_key_id" 2>/dev/null || echo "")
        CURRENT_SECRET_KEY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="secret_access_key" 2>/dev/null || echo "")
        CURRENT_REGION=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="region" 2>/dev/null || echo "")
        CURRENT_HOSTED_ZONE_ID=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="hosted_zone_id" 2>/dev/null || echo "")
        CURRENT_RECORD_NAME=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="record_name" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_ACCESS_KEY=""
        CURRENT_SECRET_KEY=""
        CURRENT_REGION=""
        CURRENT_HOSTED_ZONE_ID=""
        CURRENT_RECORD_NAME=""
    fi
}

# Collect input from user
collect_input() {
    echo
    log_info "Please provide the AWS Dynamic DNS configuration:"
    echo
    
    # AWS Access Key ID
    prompt_for_input "AWS Access Key ID" AWS_ACCESS_KEY_ID "$CURRENT_ACCESS_KEY"
    if [ -z "$AWS_ACCESS_KEY_ID" ]; then
        log_error "AWS Access Key ID is required"
        exit 1
    fi
    
    # AWS Secret Access Key
    prompt_for_input "AWS Secret Access Key" AWS_SECRET_ACCESS_KEY "$CURRENT_SECRET_KEY" true
    if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        log_error "AWS Secret Access Key is required"
        exit 1
    fi
    
    # AWS Region
    while true; do
        prompt_for_input "AWS Region (e.g., us-east-1)" AWS_REGION "$CURRENT_REGION"
        if [ -z "$AWS_REGION" ]; then
            log_error "AWS Region is required"
            continue
        fi
        if validate_aws_region "$AWS_REGION"; then
            break
        fi
    done
    
    # Hosted Zone ID
    while true; do
        prompt_for_input "Route53 Hosted Zone ID (e.g., Z1234567890ABC)" HOSTED_ZONE_ID "$CURRENT_HOSTED_ZONE_ID"
        if [ -z "$HOSTED_ZONE_ID" ]; then
            log_error "Hosted Zone ID is required"
            continue
        fi
        if validate_hosted_zone_id "$HOSTED_ZONE_ID"; then
            break
        fi
    done
    
    # Record Name(s)
    while true; do
        prompt_for_input "DNS Record Name(s) (e.g., tkuipers.ca,*.tkuipers.ca)" RECORD_NAME "$CURRENT_RECORD_NAME"
        if [ -z "$RECORD_NAME" ]; then
            log_error "Record Name is required"
            continue
        fi
        
        # Validate each record name in the comma-separated list
        IFS=',' read -ra RECORD_NAMES_ARRAY <<< "$RECORD_NAME"
        ALL_VALID=true
        
        for record_name in "${RECORD_NAMES_ARRAY[@]}"; do
            # Remove whitespace
            record_name=$(echo "$record_name" | xargs)
            if ! validate_record_name "$record_name"; then
                ALL_VALID=false
                break
            fi
        done
        
        if [ "$ALL_VALID" = "true" ]; then
            break
        fi
    done
}

# Create or update the item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  Access Key ID: $AWS_ACCESS_KEY_ID"
    echo "  Secret Key: ****"
    echo "  Region: $AWS_REGION"
    echo "  Hosted Zone ID: $HOSTED_ZONE_ID"
    echo "  Record Name(s): $RECORD_NAME"
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
            "access_key_id[text]=$AWS_ACCESS_KEY_ID" \
            "secret_access_key[password]=$AWS_SECRET_ACCESS_KEY" \
            "region[text]=$AWS_REGION" \
            "hosted_zone_id[text]=$HOSTED_ZONE_ID" \
            "record_name[text]=$RECORD_NAME"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        # Create new item
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "access_key_id[text]=$AWS_ACCESS_KEY_ID" \
            "secret_access_key[password]=$AWS_SECRET_ACCESS_KEY" \
            "region[text]=$AWS_REGION" \
            "hosted_zone_id[text]=$HOSTED_ZONE_ID" \
            "record_name[text]=$RECORD_NAME"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "AWS Dynamic DNS credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Make sure your AWS user has the required Route53 permissions"
    echo "2. Your Kubernetes cluster will automatically pick up these credentials"
    echo "3. The cronjob will start updating your DNS record(s) every 5 minutes"
    echo
    log_info "To monitor the cronjob:"
    echo "  kubectl logs -n aws-ip-updater -l app=aws-ip-updater"
    echo "  kubectl get cronjobs -n aws-ip-updater"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "  AWS Dynamic DNS Credentials Setup"
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