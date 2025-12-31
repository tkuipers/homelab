#!/bin/bash
#
# Setup Datadog API credentials in 1Password
# Creates/updates "Datadog API Keys" item in the Homelab vault
# Used by ExternalSecret in clusters/homelab/infrastructure/datadog/
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Configuration
ITEM_NAME="Datadog API Keys"
ITEM_CATEGORY="API Credential"

# Get current item if it exists
get_current_item() {
    log_info "Checking if item '$ITEM_NAME' exists..."
    
    if op_item_exists "$ITEM_NAME"; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        CURRENT_API_KEY=$(op_get_field "$ITEM_NAME" "api_key")
        CURRENT_APP_KEY=$(op_get_field "$ITEM_NAME" "app_key")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_API_KEY=""
        CURRENT_APP_KEY=""
    fi
}

# Collect credentials input
collect_input() {
    echo
    log_info "=== Datadog API Credentials ==="
    echo
    log_info "You can find your API keys at: https://app.datadoghq.com/organization-settings/api-keys"
    log_info "You can find your App keys at: https://app.datadoghq.com/organization-settings/application-keys"
    echo
    
    # API Key (required for agent)
    prompt_for_input "Datadog API Key" API_KEY "$CURRENT_API_KEY" true
    if [ -z "$API_KEY" ]; then
        log_error "API Key is required"
        exit 1
    fi
    
    # App Key (required for some features like metrics provider)
    echo
    prompt_for_input "Datadog App Key" APP_KEY "$CURRENT_APP_KEY" true
    if [ -z "$APP_KEY" ]; then
        log_error "App Key is required"
        exit 1
    fi
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Credentials summary:"
    echo "  API Key: ****${API_KEY: -4}"
    echo "  App Key: ****${APP_KEY: -4}"
    echo
    
    if ! confirm_action "Proceed with credentials $([ "$ITEM_EXISTS" = "true" ] && echo "update" || echo "creation")?"; then
        log_info "Operation cancelled"
        exit 0
    fi
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        op_update_item "$ITEM_NAME" \
            "api_key[password]=$API_KEY" \
            "app_key[password]=$APP_KEY"
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        op_create_item "$ITEM_NAME" "$ITEM_CATEGORY" \
            "api_key[password]=$API_KEY" \
            "app_key[password]=$APP_KEY"
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Datadog credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger ArgoCD deployment"
    echo "2. External Secrets Operator will automatically sync credentials"
    echo "3. Datadog agent will start collecting metrics from your cluster"
    echo
    log_info "Datadog dashboards will be available at:"
    echo "  https://app.datadoghq.com/infrastructure"
    echo "  https://app.datadoghq.com/apm/home"
    echo "  https://app.datadoghq.com/logs"
    echo
    log_info "To retrieve credentials later from 1Password:"
    echo "  op item get '$ITEM_NAME' --vault='$VAULT_NAME' --fields='api_key'"
    echo "  op item get '$ITEM_NAME' --vault='$VAULT_NAME' --fields='app_key'"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   Datadog Credentials Setup"
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

