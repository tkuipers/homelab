#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

VAULT_NAME="Homelab"
ITEM_NAME="Authelia Credentials"
CONFIGMAP="$SCRIPT_DIR/../../../clusters/homelab/infrastructure/authelia/configmap.yaml"
PLACEHOLDER="REPLACE_WITH_ARGON2ID_HASH_HOMEASSISTANT"
CLIENT_ID="homeassistant"

check_op_cli
check_vault "$VAULT_NAME"

# ---------------------------------------------------------------------------
# Hash helper (matches setup-authelia-credentials.sh exactly)
# ---------------------------------------------------------------------------
hash_client_secret() {
    local secret="$1"
    if command -v authelia &> /dev/null; then
        authelia crypto hash generate argon2 --salt-size 16 --password "$secret" \
            | grep -oP '\$argon2id\$[^\s]+'
    else
        docker run --rm authelia/authelia:4.39.16 \
            authelia crypto hash generate argon2 --salt-size 16 --password "$secret" \
            | grep -oP '\$argon2id\$[^\s]+'
    fi
}

# ---------------------------------------------------------------------------
# Check that configmap still has the placeholder (idempotency guard)
# ---------------------------------------------------------------------------
if ! grep -q "$PLACEHOLDER" "$CONFIGMAP"; then
    log_warning "Configmap does not contain $PLACEHOLDER."
    log_warning "Either this script already ran or the hash was set manually."
    log_info "If you want to re-run, restore the placeholder and try again."
    exit 1
fi

# ---------------------------------------------------------------------------
# Check the 1Password item exists before we try to edit it
# ---------------------------------------------------------------------------
if ! op item get "$ITEM_NAME" --vault="$VAULT_NAME" &>/dev/null; then
    log_error "Item '$ITEM_NAME' not found in vault '$VAULT_NAME'."
    log_info "Run setup-authelia-credentials.sh first."
    exit 1
fi
log_success "Found '$ITEM_NAME' in 1Password"

# ---------------------------------------------------------------------------
# Generate secret and hash
# ---------------------------------------------------------------------------
echo
log_info "Generating Home Assistant OIDC client secret..."
CLIENT_SECRET=$(openssl rand -hex 32)
log_success "Generated client secret"

if ! command -v authelia &>/dev/null; then
    log_info "Pulling authelia docker image for hashing..."
    docker pull authelia/authelia:4.39.16 >/dev/null 2>&1
fi

log_info "Hashing with argon2id (this takes a few seconds)..."
CLIENT_SECRET_HASH=$(hash_client_secret "$CLIENT_SECRET")
log_success "Generated argon2id hash"

# ---------------------------------------------------------------------------
# Confirm before writing anywhere
# ---------------------------------------------------------------------------
echo
log_info "About to:"
echo "  1. Add homeassistant_client_secret + hash to '$ITEM_NAME' in 1Password"
echo "  2. Patch $CONFIGMAP with the real hash"
echo
if ! confirm_action "Proceed?"; then
    log_info "Cancelled."
    exit 0
fi

# ---------------------------------------------------------------------------
# Save to 1Password (edit existing item — adds fields if absent, updates if present)
# ---------------------------------------------------------------------------
log_info "Saving to 1Password..."
op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
    "homeassistant_client_secret[password]=$CLIENT_SECRET" \
    "homeassistant_client_secret_hash[password]=$CLIENT_SECRET_HASH" \
    >/dev/null
log_success "Saved to 1Password"

# ---------------------------------------------------------------------------
# Patch the configmap (in-place sed, preserving YAML indentation)
# ---------------------------------------------------------------------------
log_info "Patching configmap..."
sed -i "s|${PLACEHOLDER}|${CLIENT_SECRET_HASH}|g" "$CONFIGMAP"
log_success "Configmap updated"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "========================================="
echo "   Home Assistant OIDC — setup complete"
echo "========================================="
echo
log_info "Commit and push the configmap change, then sync Authelia in ArgoCD"
log_info "and restart the authelia deployment so the new client is loaded:"
echo
echo "  kubectl -n authelia rollout restart deployment/authelia"
echo
log_success "Values to plug into Home Assistant's auth_oidc config:"
echo
echo "  client_id:     $CLIENT_ID"
echo "  client_secret: $CLIENT_SECRET"
echo "  discovery_url: https://auth.tkuipers.ca/.well-known/openid-configuration"
echo
log_info "The plaintext secret is also stored in 1Password under:"
echo "  Vault:  $VAULT_NAME"
echo "  Item:   $ITEM_NAME"
echo "  Field:  homeassistant_client_secret"
echo
