#!/bin/bash
#
# Seed 1Password "Polymarket Bot" item from a local .env file.
#
# This script reads the polymarket-bot's .env (typically
#   ~/polymarket-bot/.env) and pushes every field into the 1Password item
# named "Polymarket Bot" (vault: $OP_VAULT_NAME, default "Homelab"). On
# re-runs existing 1Password values are kept as defaults so a partial
# .env doesn't blow away other fields.
#
# Override priority for each field:
#   1. environment variable (e.g. WALLET_PRIVATE_KEY=...) — explicit override
#   2. value from --env-file (.env)
#   3. value currently in 1Password
#
# Generated fields (Postgres user/password/db) default to safe values on
# first run; subsequent runs keep what's already in 1Password.
#
# Usage:
#   ./setup-polymarket-bot-credentials.sh                       # use ~/polymarket-bot/.env
#   ./setup-polymarket-bot-credentials.sh --env-file PATH       # custom .env
#   ./setup-polymarket-bot-credentials.sh --dry-run             # show plan, write nothing
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

ITEM_NAME="Polymarket Bot"
ITEM_CATEGORY="API Credential"
ENV_FILE="${HOME}/polymarket-bot/.env"
DRY_RUN=false

while (( $# )); do
    case "$1" in
        --env-file)   ENV_FILE="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    grep '^#' "$0" | head -40 | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            log_error "Unknown arg: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Read .env (POSIX-y subset; tolerates surrounding quotes)
# ---------------------------------------------------------------------------
declare -A ENV_VALUES
load_env_file() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_warning "No .env at $ENV_FILE — .env values won't be used as defaults"
        return
    fi
    log_info "Reading $ENV_FILE"
    # Skip blank lines and comments; strip optional surrounding quotes.
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # Strip leading/trailing whitespace from key
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        # Strip optional surrounding quotes from value
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        ENV_VALUES["$key"]="$value"
    done < "$ENV_FILE"
}

# ---------------------------------------------------------------------------
# Field list — mirrors .env exactly, plus Postgres + dashboard fields the
# k8s manifests need. Tuple: <op-field-name>;<env-var-name>;<field-kind>;<default-on-create>
# field-kind:  password | text
# ---------------------------------------------------------------------------
# Edit this list when adding new secrets — both the .env consumer and the
# k8s ExternalSecret should agree on these op-field names.
FIELDS=(
    # --- Polymarket on-chain / API (from .env) ---
    "poly-clob-host;POLY_CLOB_HOST;text;https://clob.polymarket.com"
    "polygon-rpc-url;POLYGON_RPC_URL;password;"
    "wallet-private-key;WALLET_PRIVATE_KEY;password;"
    "poly-api-key;POLY_API_KEY;password;"
    "poly-api-secret;POLY_API_SECRET;password;"
    "poly-api-passphrase;POLY_API_PASSPHRASE;password;"
    "poly-funder;POLY_FUNDER;text;"
    "poly-signature-type;POLY_SIGNATURE_TYPE;text;2"
    "poly-proxy-address;POLY_PROXY_ADDRESS;text;"
    "builder-api-key;BUILDER_API_KEY;password;"
    "builder-secret;BUILDER_SECRET;password;"
    "builder-pass-phrase;BUILDER_PASS_PHRASE;password;"
    "relayer-url;RELAYER_URL;text;"
    # --- Postgres (k8s-only; not in .env) ---
    "postgres-user;POLYBOT_POSTGRES_USER;text;polymarket"
    "postgres-password;POLYBOT_POSTGRES_PASSWORD;password;GENERATE"
    "postgres-database;POLYBOT_POSTGRES_DATABASE;text;polymarket_bot"
)

# ---------------------------------------------------------------------------
# Resolve one field by priority (env > .env > 1Password existing > default)
# ---------------------------------------------------------------------------
declare -A RESOLVED
declare -A CURRENT_OP

load_existing_op() {
    if op_item_exists "$ITEM_NAME"; then
        log_success "Found '$ITEM_NAME' — existing fields will be kept as defaults"
        ITEM_EXISTS=true
        for spec in "${FIELDS[@]}"; do
            IFS=';' read -r op_field env_var kind default <<<"$spec"
            CURRENT_OP["$op_field"]="$(op_get_field "$ITEM_NAME" "$op_field")"
        done
    else
        log_info "'$ITEM_NAME' not found — will create it"
        ITEM_EXISTS=false
    fi
}

resolve_fields() {
    for spec in "${FIELDS[@]}"; do
        IFS=';' read -r op_field env_var kind default <<<"$spec"
        # 1. Direct environment override
        if [[ -n "${!env_var:-}" ]]; then
            RESOLVED["$op_field"]="${!env_var}"
            continue
        fi
        # 2. From .env file
        if [[ -n "${ENV_VALUES[$env_var]:-}" ]]; then
            RESOLVED["$op_field"]="${ENV_VALUES[$env_var]}"
            continue
        fi
        # 3. Existing 1Password value
        if [[ -n "${CURRENT_OP[$op_field]:-}" ]]; then
            RESOLVED["$op_field"]="${CURRENT_OP[$op_field]}"
            continue
        fi
        # 4. Default
        if [[ "$default" == "GENERATE" ]]; then
            RESOLVED["$op_field"]="$(generate_password 32)"
        else
            RESOLVED["$op_field"]="$default"
        fi
    done
}

# ---------------------------------------------------------------------------
# Print plan (always) and write to 1Password (unless --dry-run)
# ---------------------------------------------------------------------------
show_plan() {
    echo
    log_info "Plan for '$ITEM_NAME' (vault: $VAULT_NAME):"
    printf "  %-26s %-10s %s\n" "FIELD" "KIND" "VALUE"
    for spec in "${FIELDS[@]}"; do
        IFS=';' read -r op_field env_var kind default <<<"$spec"
        v="${RESOLVED[$op_field]}"
        if [[ "$kind" == "password" ]]; then
            display="${v:0:4}…${v: -4}"
            [[ ${#v} -lt 12 ]] && display="****"
        else
            display="$v"
        fi
        if [[ -z "$v" ]]; then
            display="(empty)"
        fi
        # Source markers
        src="?"
        if [[ -n "${!env_var:-}" ]]; then src="env-override"
        elif [[ -n "${ENV_VALUES[$env_var]:-}" ]]; then src=".env"
        elif [[ -n "${CURRENT_OP[$op_field]:-}" ]]; then src="1Password"
        elif [[ "$default" == "GENERATE" ]]; then src="generated"
        else src="default"
        fi
        printf "  %-26s %-10s %s  (%s)\n" "$op_field" "$kind" "$display" "$src"
    done
    echo
}

save_to_1password() {
    local fields_args=()
    for spec in "${FIELDS[@]}"; do
        IFS=';' read -r op_field env_var kind default <<<"$spec"
        local v="${RESOLVED[$op_field]}"
        # Send empty strings as empty so re-runs don't insert stale defaults;
        # 1Password tolerates empty values.
        fields_args+=( "${op_field}[${kind}]=${v}" )
    done

    if [[ "$ITEM_EXISTS" == "true" ]]; then
        log_info "Updating '$ITEM_NAME'..."
        op_update_item "$ITEM_NAME" "${fields_args[@]}"
    else
        log_info "Creating '$ITEM_NAME'..."
        op_create_item "$ITEM_NAME" "$ITEM_CATEGORY" "${fields_args[@]}"
    fi
    log_success "'$ITEM_NAME' saved"
}

show_next_steps() {
    echo
    log_success "Polymarket Bot credentials seeded."
    echo
    log_info "Next:"
    echo "  1. Deploy Step 1 (Postgres + ExternalSecret):"
    echo "       kubectl apply -k clusters/homelab/apps/polymarket-bot/"
    echo "     (kustomization initially excludes the app deployment & ingress)"
    echo
    echo "  2. Migrate local SQLite into the new Postgres:"
    echo "       kubectl -n polymarket-bot port-forward svc/postgres 5432:5432 &"
    echo "       export DATABASE_URL=\"postgresql://\$(op item get 'Polymarket Bot' --fields postgres-user):"
    echo "           \$(op item get 'Polymarket Bot' --fields postgres-password)@localhost:5432/"
    echo "           \$(op item get 'Polymarket Bot' --fields postgres-database)\""
    echo "       cd ~/polymarket-bot && .venv/bin/python -m scripts.migrate_sqlite_to_postgres \\"
    echo "         --sqlite data/bot.db --postgres \"\$DATABASE_URL\""
    echo
    echo "  3. Enable Step 2 in the kustomization (app + ingress), commit, push."
    echo
}

main() {
    echo "========================================="
    echo "   Polymarket Bot Credentials Setup"
    echo "========================================="
    check_op_cli
    check_vault
    load_env_file
    load_existing_op
    resolve_fields
    show_plan
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "--dry-run set; not writing to 1Password"
        exit 0
    fi
    if ! confirm_action "Write the above to 1Password?"; then
        log_info "Cancelled"
        exit 0
    fi
    save_to_1password
    show_next_steps
}

main "$@"
