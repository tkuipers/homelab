#!/bin/bash
#
# Setup Stocks v2 credentials in 1Password and patch Authelia configmap.
# Creates/updates "Stocks v2" item (app secrets) and adds the OIDC client
# entry to "Authelia Credentials" so ExternalSecrets can sync everything.
#
# Usage: ./setup-stocks-credentials.sh [--skip-api-keys]
#   --skip-api-keys  Leave optional API keys (newsapi, adzuna, etc.) unchanged
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

ITEM_NAME="Stocks v2"
ITEM_CATEGORY="API Credential"
AUTHELIA_ITEM="Authelia Credentials"
CONFIGMAP_PATH="$SCRIPT_DIR/../../../clusters/homelab/infrastructure/authelia/configmap.yaml"
SKIP_API_KEYS=false

for arg in "$@"; do
    [[ "$arg" == "--skip-api-keys" ]] && SKIP_API_KEYS=true
done

# ---------------------------------------------------------------------------
# Hash an OIDC client secret with argon2id via authelia CLI or docker
# ---------------------------------------------------------------------------
hash_client_secret() {
    local secret="$1"
    if command -v authelia &>/dev/null; then
        authelia crypto hash generate argon2 --salt-size 16 --password "$secret" \
            | grep -oP '\$argon2id\$[^\s]+'
    else
        docker run --rm authelia/authelia:latest \
            authelia crypto hash generate argon2 --salt-size 16 --password "$secret" \
            | grep -oP '\$argon2id\$[^\s]+'
    fi
}

# ---------------------------------------------------------------------------
# Load existing values so re-runs preserve unchanged fields
# ---------------------------------------------------------------------------
load_existing() {
    log_info "Checking existing 1Password items..."

    if op_item_exists "$ITEM_NAME"; then
        log_success "Found '$ITEM_NAME' — existing values will be kept as defaults"
        ITEM_EXISTS=true
        CUR_PG_ROOT=$(op_get_field "$ITEM_NAME" "postgres-root-password")
        CUR_PG_USER=$(op_get_field "$ITEM_NAME" "postgres-user")
        CUR_PG_PASS=$(op_get_field "$ITEM_NAME" "postgres-password")
        CUR_PG_DB=$(op_get_field "$ITEM_NAME" "postgres-database")
        CUR_ENC_KEY=$(op_get_field "$ITEM_NAME" "credential-encryption-key")
        CUR_SESSION=$(op_get_field "$ITEM_NAME" "session-secret-key")
        CUR_MINIO_USER=$(op_get_field "$ITEM_NAME" "minio-root-user")
        CUR_MINIO_PASS=$(op_get_field "$ITEM_NAME" "minio-root-password")
        CUR_NEWSAPI=$(op_get_field "$ITEM_NAME" "newsapi-key")
        CUR_ADZUNA_ID=$(op_get_field "$ITEM_NAME" "adzuna-app-id")
        CUR_ADZUNA_KEY=$(op_get_field "$ITEM_NAME" "adzuna-app-key")
        CUR_AZURE=$(op_get_field "$ITEM_NAME" "azure-maps-key")
        CUR_GOOGLE=$(op_get_field "$ITEM_NAME" "google-places-key")
        CUR_ACLED_EMAIL=$(op_get_field "$ITEM_NAME" "acled-email")
        CUR_ACLED_PASS=$(op_get_field "$ITEM_NAME" "acled-password")
        CUR_OPENAI=$(op_get_field "$ITEM_NAME" "openai-api-key")
        CUR_ANTHROPIC=$(op_get_field "$ITEM_NAME" "anthropic-api-key")
        CUR_AWS_ID=$(op_get_field "$ITEM_NAME" "aws-access-key-id")
        CUR_AWS_SECRET=$(op_get_field "$ITEM_NAME" "aws-secret-access-key")
        CUR_S3_BUCKET=$(op_get_field "$ITEM_NAME" "s3-bucket")
        CUR_S3_REGION=$(op_get_field "$ITEM_NAME" "s3-region")
    else
        log_info "'$ITEM_NAME' not found — will create new item"
        ITEM_EXISTS=false
        CUR_PG_ROOT="" CUR_PG_USER="" CUR_PG_PASS="" CUR_PG_DB=""
        CUR_ENC_KEY="" CUR_SESSION=""
        CUR_MINIO_USER="" CUR_MINIO_PASS=""
        CUR_NEWSAPI="" CUR_ADZUNA_ID="" CUR_ADZUNA_KEY=""
        CUR_AZURE="" CUR_GOOGLE="" CUR_ACLED_EMAIL="" CUR_ACLED_PASS=""
        CUR_OPENAI="" CUR_ANTHROPIC=""
        CUR_AWS_ID="" CUR_AWS_SECRET="" CUR_S3_BUCKET="" CUR_S3_REGION=""
    fi
}

# ---------------------------------------------------------------------------
# Collect all credential values
# ---------------------------------------------------------------------------
collect_input() {
    echo
    log_info "=== PostgreSQL ==="
    prompt_for_input "Root password (blank to generate)" PG_ROOT "$CUR_PG_ROOT" true
    [ -z "$PG_ROOT" ] && PG_ROOT=$(generate_password 32) && log_info "Generated root password"

    prompt_for_input "App username" PG_USER "$CUR_PG_USER"
    [ -z "$PG_USER" ] && PG_USER="stocks" && log_info "Using default: stocks"

    prompt_for_input "App password (blank to generate)" PG_PASS "$CUR_PG_PASS" true
    [ -z "$PG_PASS" ] && PG_PASS=$(generate_password 32) && log_info "Generated app password"

    prompt_for_input "Database name" PG_DB "$CUR_PG_DB"
    [ -z "$PG_DB" ] && PG_DB="stocks" && log_info "Using default: stocks"

    echo
    log_info "=== App secrets (auto-generated) ==="
    if [ -n "$CUR_ENC_KEY" ]; then
        ENC_KEY="$CUR_ENC_KEY"
        log_info "Keeping existing credential encryption key"
    else
        # AES-256-GCM key must be exactly 32 hex bytes (64 chars)
        ENC_KEY=$(openssl rand -hex 32)
        log_success "Generated credential encryption key"
    fi

    if [ -n "$CUR_SESSION" ]; then
        SESSION_KEY="$CUR_SESSION"
        log_info "Keeping existing session secret key"
    else
        SESSION_KEY=$(openssl rand -base64 48 | tr -d '\n')
        log_success "Generated session secret key"
    fi

    echo
    log_info "=== MinIO ==="
    prompt_for_input "MinIO root user" MINIO_USER "$CUR_MINIO_USER"
    [ -z "$MINIO_USER" ] && MINIO_USER="stocks-admin" && log_info "Using default: stocks-admin"

    prompt_for_input "MinIO root password (blank to generate)" MINIO_PASS "$CUR_MINIO_PASS" true
    [ -z "$MINIO_PASS" ] && MINIO_PASS=$(generate_password 32) && log_info "Generated MinIO password"

    echo
    log_info "=== OIDC client secret (auto-generated) ==="
    if ! command -v authelia &>/dev/null && ! command -v docker &>/dev/null; then
        log_error "Either 'authelia' CLI or 'docker' is required to hash the OIDC secret"
        exit 1
    fi
    [ ! command -v docker &>/dev/null ] || docker pull authelia/authelia:latest >/dev/null 2>&1 || true

    OIDC_SECRET=$(openssl rand -hex 32)
    log_info "Hashing OIDC client secret with argon2id (this takes ~5s)..."
    OIDC_SECRET_HASH=$(hash_client_secret "$OIDC_SECRET")
    log_success "Generated and hashed OIDC client secret"

    if [ "$SKIP_API_KEYS" = "true" ]; then
        NEWSAPI="$CUR_NEWSAPI"
        ADZUNA_ID="$CUR_ADZUNA_ID"   ADZUNA_KEY="$CUR_ADZUNA_KEY"
        AZURE="$CUR_AZURE"           GOOGLE="$CUR_GOOGLE"
        ACLED_EMAIL="$CUR_ACLED_EMAIL" ACLED_PASS="$CUR_ACLED_PASS"
        OPENAI="$CUR_OPENAI"         ANTHROPIC="$CUR_ANTHROPIC"
        log_info "Skipping API key prompts (--skip-api-keys)"
    else
        echo
        log_info "=== Signal ingestion API keys (Enter to keep existing / leave blank to skip) ==="
        log_info "Get NewsAPI key: https://newsapi.org/account"
        prompt_for_input "NewsAPI key" NEWSAPI "$CUR_NEWSAPI" true

        log_info "Get Adzuna keys: https://developer.adzuna.com"
        prompt_for_input "Adzuna App ID" ADZUNA_ID "$CUR_ADZUNA_ID"
        prompt_for_input "Adzuna App Key" ADZUNA_KEY "$CUR_ADZUNA_KEY" true

        log_info "Get Azure Maps key: https://portal.azure.com"
        prompt_for_input "Azure Maps Subscription Key" AZURE "$CUR_AZURE" true

        log_info "Get Google Places key: https://console.cloud.google.com"
        prompt_for_input "Google Places API Key" GOOGLE "$CUR_GOOGLE" true

        log_info "ACLED credentials: https://acleddata.com"
        prompt_for_input "ACLED email" ACLED_EMAIL "$CUR_ACLED_EMAIL"
        prompt_for_input "ACLED password" ACLED_PASS "$CUR_ACLED_PASS" true

        echo
        log_info "=== LLM provider keys ==="
        prompt_for_input "OpenAI API Key" OPENAI "$CUR_OPENAI" true
        prompt_for_input "Anthropic API Key" ANTHROPIC "$CUR_ANTHROPIC" true
    fi

    echo
    log_info "=== AWS S3 backup ==="
    prompt_for_input "AWS Access Key ID" AWS_ID "$CUR_AWS_ID" true
    [ -z "$AWS_ID" ] && { log_error "AWS Access Key ID is required"; exit 1; }
    prompt_for_input "AWS Secret Access Key" AWS_SECRET "$CUR_AWS_SECRET" true
    [ -z "$AWS_SECRET" ] && { log_error "AWS Secret Access Key is required"; exit 1; }
    prompt_for_input "S3 Bucket name" S3_BUCKET "$CUR_S3_BUCKET"
    [ -z "$S3_BUCKET" ] && { log_error "S3 Bucket is required"; exit 1; }
    prompt_for_input "S3 Region" S3_REGION "$CUR_S3_REGION"
    if [ -z "$S3_REGION" ]; then
        S3_REGION="us-east-1"
        log_info "Using default region: us-east-1"
    fi
}

# ---------------------------------------------------------------------------
# Non-interactive path: values from setup-stocks-credentials.local.inc.sh (gitignored)
# ---------------------------------------------------------------------------
collect_input_local() {
    echo
    log_info "=== Non-interactive (local.inc) — PostgreSQL / MinIO / app secrets ==="

    PG_ROOT="${STOCKS_POSTGRES_ROOT_PASSWORD:-}"
    [ -z "$PG_ROOT" ] && PG_ROOT="$CUR_PG_ROOT"
    [ -z "$PG_ROOT" ] && PG_ROOT=$(generate_password 32) && log_info "Generated root password"

    PG_USER="${STOCKS_POSTGRES_USER:-}"
    [ -z "$PG_USER" ] && PG_USER="${CUR_PG_USER:-}"
    [ -z "$PG_USER" ] && PG_USER="stocks" && log_info "Using default: stocks"

    PG_PASS="${STOCKS_POSTGRES_PASSWORD:-}"
    [ -z "$PG_PASS" ] && PG_PASS="$CUR_PG_PASS"
    [ -z "$PG_PASS" ] && PG_PASS=$(generate_password 32) && log_info "Generated app password"

    PG_DB="${STOCKS_POSTGRES_DATABASE:-}"
    [ -z "$PG_DB" ] && PG_DB="${CUR_PG_DB:-}"
    [ -z "$PG_DB" ] && PG_DB="stocks" && log_info "Using default: stocks"

    if [ -n "$CUR_ENC_KEY" ]; then
        ENC_KEY="$CUR_ENC_KEY"
        log_info "Keeping existing credential encryption key"
    else
        ENC_KEY=$(openssl rand -hex 32)
        log_success "Generated credential encryption key"
    fi

    if [ -n "$CUR_SESSION" ]; then
        SESSION_KEY="$CUR_SESSION"
        log_info "Keeping existing session secret key"
    else
        SESSION_KEY=$(openssl rand -base64 48 | tr -d '\n')
        log_success "Generated session secret key"
    fi

    MINIO_USER="${STOCKS_MINIO_ROOT_USER:-}"
    [ -z "$MINIO_USER" ] && MINIO_USER="${CUR_MINIO_USER:-}"
    [ -z "$MINIO_USER" ] && MINIO_USER="stocks-admin" && log_info "Using default: stocks-admin"

    MINIO_PASS="${STOCKS_MINIO_ROOT_PASSWORD:-}"
    [ -z "$MINIO_PASS" ] && MINIO_PASS="$CUR_MINIO_PASS"
    [ -z "$MINIO_PASS" ] && MINIO_PASS=$(generate_password 32) && log_info "Generated MinIO password"

    echo
    log_info "=== OIDC client secret (auto-generated) ==="
    if ! command -v authelia &>/dev/null && ! command -v docker &>/dev/null; then
        log_error "Either 'authelia' CLI or 'docker' is required to hash the OIDC secret"
        exit 1
    fi
    command -v docker &>/dev/null && docker pull authelia/authelia:latest >/dev/null 2>&1 || true

    OIDC_SECRET=$(openssl rand -hex 32)
    log_info "Hashing OIDC client secret with argon2id (this takes ~5s)..."
    OIDC_SECRET_HASH=$(hash_client_secret "$OIDC_SECRET")
    log_success "Generated and hashed OIDC client secret"

    echo
    log_info "=== API keys / AWS (from local.inc or existing 1Password item) ==="
    NEWSAPI="${NEWSAPI:-$CUR_NEWSAPI}"
    ADZUNA_ID="${ADZUNA_ID:-$CUR_ADZUNA_ID}"
    ADZUNA_KEY="${ADZUNA_KEY:-$CUR_ADZUNA_KEY}"
    AZURE="${AZURE:-$CUR_AZURE}"
    GOOGLE="${GOOGLE:-$CUR_GOOGLE}"
    ACLED_EMAIL="${ACLED_EMAIL:-$CUR_ACLED_EMAIL}"
    ACLED_PASS="${ACLED_PASS:-$CUR_ACLED_PASS}"
    OPENAI="${OPENAI:-$CUR_OPENAI}"
    ANTHROPIC="${ANTHROPIC:-$CUR_ANTHROPIC}"
    AWS_ID="${AWS_ID:-$CUR_AWS_ID}"
    AWS_SECRET="${AWS_SECRET:-$CUR_AWS_SECRET}"
    S3_BUCKET="${S3_BUCKET:-$CUR_S3_BUCKET}"
    S3_REGION="${S3_REGION:-$CUR_S3_REGION}"

    [ -z "$AWS_ID" ] && { log_error "AWS Access Key ID is required (local.inc or 1Password item)"; exit 1; }
    [ -z "$AWS_SECRET" ] && { log_error "AWS Secret Access Key is required (local.inc or 1Password item)"; exit 1; }
    [ -z "$S3_BUCKET" ] && { log_error "S3 Bucket is required (local.inc or 1Password item)"; exit 1; }
    if [ -z "$S3_REGION" ]; then
        S3_REGION="us-east-1"
        log_info "Using default region: us-east-1"
    fi
}

# ---------------------------------------------------------------------------
# Write to 1Password
# ---------------------------------------------------------------------------
save_to_1password() {
    echo
    log_info "Configuration summary:"
    echo "  PostgreSQL user:      $PG_USER @ $PG_DB"
    echo "  MinIO user:           $MINIO_USER"
    echo "  OIDC client secret:   $OIDC_SECRET"
    echo "  S3 bucket:            $S3_BUCKET ($S3_REGION)"
    echo "  API keys:             $([ -n "$NEWSAPI" ] && echo "newsapi " || true)$([ -n "$OPENAI" ] && echo "openai " || true)$([ -n "$ANTHROPIC" ] && echo "anthropic" || true)"
    echo

    if [[ "${STOCKS_AUTO_CONFIRM:-}" != "1" ]]; then
        if ! confirm_action "Write to 1Password and patch Authelia configmap?"; then
            log_info "Cancelled"
            exit 0
        fi
    else
        log_info "Auto-confirm (STOCKS_AUTO_CONFIRM=1) — writing to 1Password and patching configmap"
    fi

    local fields=(
        "postgres-root-password[password]=$PG_ROOT"
        "postgres-user[text]=$PG_USER"
        "postgres-password[password]=$PG_PASS"
        "postgres-database[text]=$PG_DB"
        "credential-encryption-key[password]=$ENC_KEY"
        "session-secret-key[password]=$SESSION_KEY"
        "oidc-client-secret[password]=$OIDC_SECRET"
        "minio-root-user[text]=$MINIO_USER"
        "minio-root-password[password]=$MINIO_PASS"
        "newsapi-key[password]=$NEWSAPI"
        "adzuna-app-id[text]=$ADZUNA_ID"
        "adzuna-app-key[password]=$ADZUNA_KEY"
        "azure-maps-key[password]=$AZURE"
        "google-places-key[password]=$GOOGLE"
        "acled-email[text]=$ACLED_EMAIL"
        "acled-password[password]=$ACLED_PASS"
        "openai-api-key[password]=$OPENAI"
        "anthropic-api-key[password]=$ANTHROPIC"
        "aws-access-key-id[password]=$AWS_ID"
        "aws-secret-access-key[password]=$AWS_SECRET"
        "s3-bucket[text]=$S3_BUCKET"
        "s3-region[text]=$S3_REGION"
    )

    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating '$ITEM_NAME'..."
        op_update_item "$ITEM_NAME" "${fields[@]}"
    else
        log_info "Creating '$ITEM_NAME'..."
        op_create_item "$ITEM_NAME" "$ITEM_CATEGORY" "${fields[@]}"
    fi
    log_success "'$ITEM_NAME' saved"

    # Add stocks OIDC fields to Authelia Credentials item
    log_info "Updating '$AUTHELIA_ITEM' with stocks OIDC fields..."
    op_update_item "$AUTHELIA_ITEM" \
        "stocks_client_secret[password]=$OIDC_SECRET" \
        "stocks_client_secret_hash[password]=$OIDC_SECRET_HASH"
    log_success "'$AUTHELIA_ITEM' updated"
}

# ---------------------------------------------------------------------------
# Patch the Authelia configmap YAML with the real hash
# ---------------------------------------------------------------------------
patch_configmap() {
    log_info "Patching Authelia configmap: $CONFIGMAP_PATH"

    if [ ! -f "$CONFIGMAP_PATH" ]; then
        log_error "Configmap not found at: $CONFIGMAP_PATH"
        exit 1
    fi

    # Replace any placeholder or previous hash on the stocks client_secret line
    # The line looks like:  client_secret: '$argon2id$...' or the placeholder
    local escaped_hash
    # Escape & and / for sed
    escaped_hash=$(printf '%s\n' "$OIDC_SECRET_HASH" | sed 's/[&/\]/\\&/g')

    sed -i \
        "/client_id: 'stocks'/,/token_endpoint_auth_method/ \
        s|client_secret: '.*'|client_secret: '${escaped_hash}'|" \
        "$CONFIGMAP_PATH"

    # Verify the patch landed
    if grep -q "$OIDC_SECRET_HASH" "$CONFIGMAP_PATH"; then
        log_success "Configmap patched with argon2id hash"
    else
        log_error "sed patch did not apply — please update configmap manually:"
        echo "  client_secret: '$OIDC_SECRET_HASH'"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------
show_next_steps() {
    echo
    log_success "Stocks v2 credentials fully configured!"
    echo
    log_info "SAVE THIS — OIDC client secret (plaintext):"
    echo "  $OIDC_SECRET"
    echo
    log_info "Next steps:"
    echo "1. git add/commit the patched configmap and push to trigger ArgoCD"
    echo "2. ArgoCD will sync the authelia configmap and restart Authelia"
    echo "3. ExternalSecrets will sync 'stocks-secret' into the stocks namespace"
    echo "4. ArgoCD will deploy all stocks services"
    echo
    log_info "Services once deployed:"
    echo "  Console: https://stocks.tkuipers.ca"
    echo "  API:     https://stocks-api.tkuipers.ca"
    echo
    log_info "S3 lifecycle policy (apply to bucket '$S3_BUCKET'):"
    echo "  stocks-postgres/daily/*   → expire after 7 days"
    echo "  stocks-postgres/weekly/*  → expire after 30 days"
    echo "  stocks-postgres/monthly/* → expire after 365 days"
    echo "  stocks-postgres/yearly/*  → no expiration"
    echo
    log_info "To verify secrets synced after deployment:"
    echo "  kubectl get externalsecret -n stocks"
    echo "  kubectl get secret stocks-secret -n stocks"
    echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "========================================="
    echo "   Stocks v2 Credentials Setup"
    echo "========================================="
    echo

    LOCAL_INC_PATH="$SCRIPT_DIR/setup-stocks-credentials.local.inc.sh"
    USE_LOCAL_INC=false
    if [[ -f "$LOCAL_INC_PATH" ]]; then
        # shellcheck source=/dev/null
        source "$LOCAL_INC_PATH"
        USE_LOCAL_INC=true
        log_info "Loaded $LOCAL_INC_PATH (non-interactive mode)"
    fi

    check_op_cli
    check_vault
    load_existing
    if [[ "$USE_LOCAL_INC" == "true" ]]; then
        collect_input_local
    else
        collect_input
    fi
    save_to_1password
    patch_configmap
    show_next_steps
}

main "$@"
