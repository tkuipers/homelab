#!/bin/bash

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="Authelia Credentials"
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

# Generate secure random keys
generate_storage_encryption_key() {
    openssl rand -base64 64 | tr -d '\n'
}

generate_oidc_hmac_secret() {
    openssl rand -base64 64 | tr -d '\n'
}

generate_jwt_secret() {
    openssl rand -base64 64 | tr -d '\n'
}

generate_session_secret() {
    openssl rand -base64 64 | tr -d '\n'
}

generate_oidc_issuer_private_key() {
    # Generate RSA private key
    openssl genrsa 4096 2>/dev/null
}

# Generate password
generate_password() {
    openssl rand -base64 24 | tr -d "=+/" | cut -c1-24
}

# Hash password with argon2id
hash_password() {
    local password="$1"
    # Use authelia CLI to generate argon2id hash (or docker if not installed)
    if command -v authelia &> /dev/null; then
        authelia crypto hash generate argon2 --salt-size 16 --password "$password" | grep -oP '\$argon2id\$[^\s]+'
    else
        # Fallback: use docker
        docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --salt-size 16 --password "$password" | grep -oP '\$argon2id\$[^\s]+'
    fi
}

# Hash OIDC client secret
hash_client_secret() {
    local secret="$1"
    if command -v authelia &> /dev/null; then
        authelia crypto hash generate argon2 --salt-size 16 --password "$secret" | grep -oP '\$argon2id\$[^\s]+'
    else
        docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --salt-size 16 --password "$secret" | grep -oP '\$argon2id\$[^\s]+'
    fi
}

# Generate ArgoCD OIDC client secret
generate_argocd_client_secret() {
    openssl rand -hex 32
}

# Collect input
collect_input() {
    echo
    log_info "=== Authelia Credentials Configuration ==="
    echo
    
    log_info "Generating cryptographic keys..."
    STORAGE_ENCRYPTION_KEY=$(generate_storage_encryption_key)
    SESSION_SECRET=$(generate_session_secret)
    JWT_SECRET=$(generate_jwt_secret)
    OIDC_HMAC_SECRET=$(generate_oidc_hmac_secret)
    
    log_success "Generated storage encryption key"
    log_success "Generated session secret"
    log_success "Generated JWT secret"
    log_success "Generated OIDC HMAC secret"
    
    echo
    log_info "Generating OIDC issuer private key (RSA 4096)..."
    OIDC_ISSUER_PRIVATE_KEY=$(generate_oidc_issuer_private_key)
    log_success "Generated OIDC issuer private key"
    
    echo
    log_info "Generating ArgoCD OIDC client secret..."
    ARGOCD_CLIENT_SECRET=$(generate_argocd_client_secret)
    log_info "ArgoCD client secret: $ARGOCD_CLIENT_SECRET"
    
    echo
    log_info "Generating Actual Budget OIDC client secret..."
    ACTUAL_BUDGET_CLIENT_SECRET=$(generate_argocd_client_secret)
    log_info "Actual Budget client secret: $ACTUAL_BUDGET_CLIENT_SECRET"
    
    echo
    log_info "Generating user password..."
    USER_PASSWORD=$(generate_password)
    log_info "User password: $USER_PASSWORD"
    echo "SAVE THIS PASSWORD - it's needed for login!"
    echo
    
    if ! command -v authelia &> /dev/null; then
        log_info "Pulling authelia docker image (first time only)..."
        docker pull authelia/authelia:latest >/dev/null 2>&1
    fi
    
    log_info "Hashing user password with argon2id..."
    USER_PASSWORD_HASH=$(hash_password "$USER_PASSWORD")
    log_success "Generated password hash"
    
    log_info "Hashing ArgoCD client secret..."
    ARGOCD_CLIENT_SECRET_HASH=$(hash_client_secret "$ARGOCD_CLIENT_SECRET")
    log_success "Generated ArgoCD client secret hash"
    
    log_info "Hashing Actual Budget client secret..."
    ACTUAL_BUDGET_CLIENT_SECRET_HASH=$(hash_client_secret "$ACTUAL_BUDGET_CLIENT_SECRET")
    log_success "Generated Actual Budget client secret hash"
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  Storage Encryption Key: **** (generated)"
    echo "  Session Secret: **** (generated)"
    echo "  JWT Secret: **** (generated)"
    echo "  OIDC HMAC Secret: **** (generated)"
    echo "  OIDC Issuer Private Key: **** (RSA 4096)"
    echo "  ArgoCD Client Secret: $ARGOCD_CLIENT_SECRET"
    echo "  Actual Budget Client Secret: $ACTUAL_BUDGET_CLIENT_SECRET"
    echo "  User Password: $USER_PASSWORD"
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
            --url="https://auth.tkuipers.ca" \
            "username=tkuipers" \
            "password=$USER_PASSWORD" \
            "storage_encryption_key[password]=$STORAGE_ENCRYPTION_KEY" \
            "session_secret[password]=$SESSION_SECRET" \
            "jwt_secret[password]=$JWT_SECRET" \
            "oidc_hmac_secret[password]=$OIDC_HMAC_SECRET" \
            "oidc_issuer_private_key[password]=$OIDC_ISSUER_PRIVATE_KEY" \
            "argocd_client_secret[password]=$ARGOCD_CLIENT_SECRET" \
            "argocd_client_secret_hash[password]=$ARGOCD_CLIENT_SECRET_HASH" \
            "actual_budget_client_secret[password]=$ACTUAL_BUDGET_CLIENT_SECRET" \
            "actual_budget_client_secret_hash[password]=$ACTUAL_BUDGET_CLIENT_SECRET_HASH" \
            "user_password_hash[password]=$USER_PASSWORD_HASH"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            --url="https://auth.tkuipers.ca" \
            "username=tkuipers" \
            "password=$USER_PASSWORD" \
            "storage_encryption_key[password]=$STORAGE_ENCRYPTION_KEY" \
            "session_secret[password]=$SESSION_SECRET" \
            "jwt_secret[password]=$JWT_SECRET" \
            "oidc_hmac_secret[password]=$OIDC_HMAC_SECRET" \
            "oidc_issuer_private_key[password]=$OIDC_ISSUER_PRIVATE_KEY" \
            "argocd_client_secret[password]=$ARGOCD_CLIENT_SECRET" \
            "argocd_client_secret_hash[password]=$ARGOCD_CLIENT_SECRET_HASH" \
            "actual_budget_client_secret[password]=$ACTUAL_BUDGET_CLIENT_SECRET" \
            "actual_budget_client_secret_hash[password]=$ACTUAL_BUDGET_CLIENT_SECRET_HASH" \
            "user_password_hash[password]=$USER_PASSWORD_HASH"
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "Authelia credentials are now configured in 1Password!"
    echo
    log_info "IMPORTANT - Save these credentials:"
    echo "  User: tkuipers"
    echo "  Password: $USER_PASSWORD"
    echo "  ArgoCD Client Secret: $ARGOCD_CLIENT_SECRET"
    echo "  Actual Budget Client Secret: $ACTUAL_BUDGET_CLIENT_SECRET"
    echo
    log_info "CRITICAL: Update Authelia ConfigMap with hashed secrets:"
    echo
    echo "1. ArgoCD client_secret hash (should already be set):"
    echo "   $ARGOCD_CLIENT_SECRET_HASH"
    echo
    echo "2. Actual Budget client_secret hash (NEW - must be added):"
    echo "   $ACTUAL_BUDGET_CLIENT_SECRET_HASH"
    echo
    log_info "Next steps:"
    echo "1. Update clusters/homelab/infrastructure/authelia/configmap.yaml"
    echo "   - Find 'actual-budget' client"
    echo "   - Replace placeholder with: $ACTUAL_BUDGET_CLIENT_SECRET_HASH"
    echo "2. Commit and push the Authelia configmap"
    echo "3. External Secrets Operator will automatically sync credentials to Kubernetes"
    echo "4. Deploy/Sync Authelia via ArgoCD"
    echo "5. Deploy Actual Budget via ArgoCD"
    echo "6. Access Authelia at: https://auth.tkuipers.ca"
    echo "7. Login with username 'tkuipers' and the password above"
    echo "8. Access Actual Budget at: https://budget.tkuipers.ca"
    echo
    log_info "To verify secrets are synced:"
    echo "  kubectl get secret authelia-secrets -n authelia"
    echo "  kubectl get externalsecret authelia-secrets -n authelia"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "   Authelia Credentials Setup"
    echo "========================================="
    echo
    
    get_current_item
    collect_input
    create_or_update_item
    show_next_steps
}

# Run main function
main "$@"

