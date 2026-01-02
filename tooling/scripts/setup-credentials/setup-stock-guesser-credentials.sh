#!/bin/bash
#
# Setup Stock Guesser credentials in 1Password
# Creates/updates "Stock Guesser" item in the Homelab vault
# Used by ExternalSecret in clusters/homelab/apps/stock-guesser/
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Configuration
ITEM_NAME="Stock Guesser"
ITEM_CATEGORY="API Credential"

# Get current item if it exists
get_current_item() {
    log_info "Checking if item '$ITEM_NAME' exists..."
    
    if op_item_exists "$ITEM_NAME"; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        # MySQL credentials
        CURRENT_MYSQL_ROOT_PASSWORD=$(op_get_field "$ITEM_NAME" "mysql-root-password")
        CURRENT_MYSQL_USER=$(op_get_field "$ITEM_NAME" "mysql-username")
        CURRENT_MYSQL_PASSWORD=$(op_get_field "$ITEM_NAME" "mysql-password")
        CURRENT_MYSQL_DATABASE=$(op_get_field "$ITEM_NAME" "mysql-database")
        # NewsAPI
        CURRENT_NEWSAPI_KEY=$(op_get_field "$ITEM_NAME" "newsapi-key")
        # Watson
        CURRENT_WATSON_URL=$(op_get_field "$ITEM_NAME" "watson-url")
        CURRENT_WATSON_KEY=$(op_get_field "$ITEM_NAME" "watson-key")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_MYSQL_ROOT_PASSWORD=""
        CURRENT_MYSQL_USER=""
        CURRENT_MYSQL_PASSWORD=""
        CURRENT_MYSQL_DATABASE=""
        CURRENT_NEWSAPI_KEY=""
        CURRENT_WATSON_URL=""
        CURRENT_WATSON_KEY=""
    fi
}

# Collect credentials input
collect_input() {
    echo
    log_info "=== MySQL Database Credentials ==="
    echo
    
    prompt_for_input "MySQL Root Password (leave blank to generate)" MYSQL_ROOT_PASSWORD "$CURRENT_MYSQL_ROOT_PASSWORD" true
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        MYSQL_ROOT_PASSWORD=$(generate_password 24)
        log_info "Generated root password"
    fi
    
    prompt_for_input "MySQL Username" MYSQL_USER "$CURRENT_MYSQL_USER"
    if [ -z "$MYSQL_USER" ]; then
        MYSQL_USER="stocker"
        log_info "Using default username: stocker"
    fi
    
    prompt_for_input "MySQL Password (leave blank to generate)" MYSQL_PASSWORD "$CURRENT_MYSQL_PASSWORD" true
    if [ -z "$MYSQL_PASSWORD" ]; then
        MYSQL_PASSWORD=$(generate_password 24)
        log_info "Generated user password"
    fi
    
    prompt_for_input "MySQL Database Name" MYSQL_DATABASE "$CURRENT_MYSQL_DATABASE"
    if [ -z "$MYSQL_DATABASE" ]; then
        MYSQL_DATABASE="stocker"
        log_info "Using default database: stocker"
    fi
    
    echo
    log_info "=== NewsAPI Credentials ==="
    log_info "Get your API key at: https://newsapi.org/account"
    echo
    
    prompt_for_input "NewsAPI Key" NEWSAPI_KEY "$CURRENT_NEWSAPI_KEY" true
    if [ -z "$NEWSAPI_KEY" ]; then
        log_error "NewsAPI Key is required"
        exit 1
    fi
    
    echo
    log_info "=== IBM Watson Tone Analyzer Credentials ==="
    log_info "Get credentials from IBM Cloud: https://cloud.ibm.com/catalog/services/tone-analyzer"
    echo
    
    prompt_for_input "Watson API URL" WATSON_URL "$CURRENT_WATSON_URL"
    if [ -z "$WATSON_URL" ]; then
        log_error "Watson URL is required"
        exit 1
    fi
    
    prompt_for_input "Watson API Key" WATSON_KEY "$CURRENT_WATSON_KEY" true
    if [ -z "$WATSON_KEY" ]; then
        log_error "Watson Key is required"
        exit 1
    fi
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  MySQL Root Password: ****${MYSQL_ROOT_PASSWORD: -4}"
    echo "  MySQL Username: $MYSQL_USER"
    echo "  MySQL Password: ****${MYSQL_PASSWORD: -4}"
    echo "  MySQL Database: $MYSQL_DATABASE"
    echo "  NewsAPI Key: ****${NEWSAPI_KEY: -4}"
    echo "  Watson URL: $WATSON_URL"
    echo "  Watson Key: ****${WATSON_KEY: -4}"
    echo
    
    if ! confirm_action "Proceed with credentials $([ "$ITEM_EXISTS" = "true" ] && echo "update" || echo "creation")?"; then
        log_info "Operation cancelled"
        exit 0
    fi
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        op_update_item "$ITEM_NAME" \
            "mysql-root-password[password]=$MYSQL_ROOT_PASSWORD" \
            "mysql-username[text]=$MYSQL_USER" \
            "mysql-password[password]=$MYSQL_PASSWORD" \
            "mysql-database[text]=$MYSQL_DATABASE" \
            "newsapi-key[password]=$NEWSAPI_KEY" \
            "watson-url[text]=$WATSON_URL" \
            "watson-key[password]=$WATSON_KEY"
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        op_create_item "$ITEM_NAME" "$ITEM_CATEGORY" \
            "mysql-root-password[password]=$MYSQL_ROOT_PASSWORD" \
            "mysql-username[text]=$MYSQL_USER" \
            "mysql-password[password]=$MYSQL_PASSWORD" \
            "mysql-database[text]=$MYSQL_DATABASE" \
            "newsapi-key[password]=$NEWSAPI_KEY" \
            "watson-url[text]=$WATSON_URL" \
            "watson-key[password]=$WATSON_KEY"
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Stock Guesser credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Commit and push your changes to trigger ArgoCD deployment"
    echo "2. External Secrets Operator will automatically sync credentials"
    echo "3. MySQL will start with the configured credentials"
    echo "4. The app will connect using DATABASE_URL"
    echo
    log_info "Service will be available at:"
    echo "  https://stock-guesser.tkuipers.ca"
    echo
    log_info "To retrieve credentials later from 1Password:"
    echo "  op item get '$ITEM_NAME' --vault='$VAULT_NAME'"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   Stock Guesser Credentials Setup"
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
