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

# Collect input
collect_input() {
    echo
    log_info "=== Authelia Credentials Configuration ==="
    echo
    
    log_info "Generating cryptographic keys..."
    STORAGE_ENCRYPTION_KEY=$(generate_storage_encryption_key)
    SESSION_SECRET=$(generate_session_secret)
    JWT_SECRET=$(generate_jwt_secret)
    
    log_success "Generated storage encryption key"
    log_success "Generated session secret"
    log_success "Generated JWT secret"
    
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
}

# Create or update item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  Storage Encryption Key: **** (generated)"
    echo "  Session Secret: **** (generated)"
    echo "  JWT Secret: **** (generated)"
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
    echo
    log_info "Next steps:"
    echo "1. External Secrets Operator will automatically sync credentials to Kubernetes"
    echo "2. Deploy Authelia via ArgoCD"
    echo "3. Access Authelia at: https://auth.tkuipers.ca"
    echo "4. Login with username 'tkuipers' and the password above"
    echo "5. Test protected site: https://protected.tkuipers.ca"
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

