#!/bin/bash

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="Umami Credentials"
ITEM_CATEGORY="login"

# Check prerequisites
check_op_cli
check_vault "$VAULT_NAME"

# Get current item if it exists
get_current_item() {
    log_info "Checking if item exists..."
    
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
    fi
}

# Generate secure random values
generate_postgres_password() {
    openssl rand -base64 24 | tr -d "=+/" | cut -c1-24
}

generate_app_secret() {
    openssl rand -hex 32
}

# Collect input
collect_input() {
    echo
    log_info "=== Umami Credentials Configuration ==="
    echo
    
    log_info "Generating credentials..."
    POSTGRES_PASSWORD=$(generate_postgres_password)
    APP_SECRET=$(generate_app_secret)
    DATABASE_URL="postgresql://umami:${POSTGRES_PASSWORD}@umami-postgres:5432/umami"
    
    log_success "Generated PostgreSQL password"
    log_success "Generated app secret"
    log_success "Generated database URL"
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  PostgreSQL Password: $POSTGRES_PASSWORD"
    echo "  App Secret: $APP_SECRET"
    echo "  Database URL: $DATABASE_URL"
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
            --url="https://umami.tkuipers.ca" \
            "username=admin" \
            "password=umami" \
            "postgres_password[password]=$POSTGRES_PASSWORD" \
            "app_secret[password]=$APP_SECRET" \
            "database_url[password]=$DATABASE_URL"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            --url="https://umami.tkuipers.ca" \
            "username=admin" \
            "password=umami" \
            "postgres_password[password]=$POSTGRES_PASSWORD" \
            "app_secret[password]=$APP_SECRET" \
            "database_url[password]=$DATABASE_URL"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Umami credentials are now configured in 1Password!"
    echo
    log_info "Default Umami login (change after first login):"
    echo "  Username: admin"
    echo "  Password: umami"
    echo
    log_info "Next steps:"
    echo "1. Add argocd-application-umami.yaml to kustomization.yaml in base/root/applications/"
    echo "2. Commit and push the homelab changes"
    echo "3. External Secrets Operator will automatically sync credentials to Kubernetes"
    echo "4. ArgoCD will deploy Umami"
    echo "5. Access Umami at: https://umami.tkuipers.ca"
    echo "6. Login with admin/umami and CHANGE THE PASSWORD"
    echo "7. Add a website (tkuipers.ca) and get the tracking code"
    echo "8. Add the tracking script to your Nuxt app"
    echo
    log_info "To verify secrets are synced:"
    echo "  kubectl get secret umami-secrets -n umami"
    echo "  kubectl get externalsecret umami-secrets -n umami"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   Umami Credentials Setup"
    echo "========================================="
    echo
    
    get_current_item
    collect_input
    create_or_update_item
    show_next_steps
}

# Run main function
main "$@"

