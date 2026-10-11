#!/bin/bash
#
# Move the observability stack's credentials into 1Password and switch the
# cluster from the temporary hand-made Secrets to ExternalSecrets.
#
# Credentials involved
#   - Grafana admin user/password          (Secret observability/grafana-admin)
#   - Grafana <-> Authelia OIDC client     (Secret observability/grafana-oidc,
#     secret, + its argon2 hash in          hash in infrastructure/authelia/
#     the Authelia configmap)               configmap.yaml, client 'grafana')
#   - read-only Grafana service account token used by the grafana MCP server
#     (optional, stored for convenience)
#
# Usage:
#   ./setup-observability-credentials.sh            # store current values in 1Password
#   ./setup-observability-credentials.sh --rotate   # generate NEW values, store them,
#                                                   # re-hash the OIDC secret into the
#                                                   # Authelia configmap
#   ./setup-observability-credentials.sh finalize   # after commit + push + ArgoCD sync:
#                                                   # hand the Secrets over to ESO and
#                                                   # restart Grafana (+ Authelia)
#
# Flow:
#   1. run without args (or --rotate)  -> 1Password item "Observability Credentials"
#                                         + fields on "Authelia Credentials"
#                                         + enables secrets/external-secrets.yaml
#   2. git commit + push (configmap / kustomization changes), wait for ArgoCD
#   3. run "finalize"
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ITEM_NAME="Observability Credentials"
ITEM_CATEGORY="login"
AUTHELIA_ITEM="Authelia Credentials"
NAMESPACE="observability"
AUTHELIA_CONFIGMAP="$REPO_ROOT/clusters/homelab/infrastructure/authelia/configmap.yaml"
OBS_KUSTOMIZATION="$REPO_ROOT/clusters/homelab/infrastructure/observability/kustomization.yaml"
TEMP_SECRETS_DIR="${TEMP_SECRETS_DIR:-$HOME/tmp/observability-temp-secrets}"
AUTHELIA_IMAGE="authelia/authelia:4.39.16"

MODE="store"
ROTATE=false
for arg in "$@"; do
    case "$arg" in
        --rotate) ROTATE=true ;;
        finalize) MODE="finalize" ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
done

# kubectl: use the current context unless KUBECONFIG points at a real file
kc() {
    if [ -f "${KUBECONFIG:-}" ]; then kubectl --kubeconfig="$KUBECONFIG" "$@"; else kubectl "$@"; fi
}

secret_value() {
    kc -n "$NAMESPACE" get secret "$1" -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d
}

hash_client_secret() {
    local secret="$1"
    if command -v authelia &>/dev/null; then
        authelia crypto hash generate argon2 --salt-size 16 --password "$secret" | grep -oP '\$argon2id\$[^\s]+'
    elif kc -n authelia get deploy authelia &>/dev/null; then
        # the running Authelia pod ships the CLI
        kc -n authelia exec deploy/authelia -- authelia crypto hash generate argon2 --salt-size 16 --password "$secret" \
            | grep -oP '\$argon2id\$[^\s]+'
    else
        docker run --rm "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --salt-size 16 --password "$secret" \
            | grep -oP '\$argon2id\$[^\s]+'
    fi
}

# Replace the client_secret hash of the 'grafana' client in the Authelia configmap
patch_authelia_hash() {
    local new_hash="$1"
    python3 - "$AUTHELIA_CONFIGMAP" "$new_hash" <<'PY'
import re, sys
path, new = sys.argv[1], sys.argv[2]
s = open(path).read()
m = re.search(r"(- client_id: 'grafana'\n(?:\s+#.*\n)?(?:.*\n)*?\s+client_secret: ')([^']+)(')", s)
if not m:
    sys.exit("grafana client not found in authelia configmap")
s = s[:m.start(2)] + new + s[m.end(2):]
open(path, "w").write(s)
PY
}

# =============================================================================
store() {
    check_op_cli
    check_vault

    local admin_user admin_pass oidc_secret mcp_token oidc_hash
    if [ "$ROTATE" = true ]; then
        log_info "Generating new credentials (--rotate)"
        admin_user="admin"
        admin_pass="$(generate_password 32)"
        oidc_secret="$(openssl rand -hex 32)"
    else
        log_info "Reading the temporary values currently used by the cluster"
        admin_user="$(secret_value grafana-admin admin-user)"
        admin_pass="$(secret_value grafana-admin admin-password)"
        oidc_secret="$(secret_value grafana-oidc client-secret)"
        if [ -z "$admin_pass" ] || [ -z "$oidc_secret" ]; then
            log_error "Could not read observability/grafana-admin or grafana-oidc. Use --rotate."
            exit 1
        fi
    fi
    mcp_token=""
    [ -f "$TEMP_SECRETS_DIR/grafana-mcp-readonly-token" ] && mcp_token="$(cat "$TEMP_SECRETS_DIR/grafana-mcp-readonly-token")"

    log_info "Hashing the OIDC client secret (argon2id)..."
    oidc_hash="$(hash_client_secret "$oidc_secret")"

    echo
    log_info "About to:"
    echo "  1. create/update 1Password item '$ITEM_NAME' (vault $VAULT_NAME)"
    echo "  2. add grafana_client_secret(+_hash) to '$AUTHELIA_ITEM'"
    [ "$ROTATE" = true ] && echo "  3. write the new hash into $AUTHELIA_CONFIGMAP"
    echo "  4. enable secrets/external-secrets.yaml in the observability kustomization"
    confirm_action "Proceed?" || { log_info "Cancelled."; exit 0; }

    local fields=(
        "username=$admin_user"
        "password=$admin_pass"
        "grafana-admin-user[text]=$admin_user"
        "grafana-admin-password[password]=$admin_pass"
        "grafana-oidc-client-secret[password]=$oidc_secret"
        "grafana-oidc-client-secret-hash[password]=$oidc_hash"
        "website[url]=https://logs.tkuipers.ca"
    )
    [ -n "$mcp_token" ] && fields+=("grafana-mcp-readonly-token[password]=$mcp_token")

    if op_item_exists "$ITEM_NAME"; then
        op_update_item "$ITEM_NAME" "${fields[@]}" >/dev/null
        log_success "Updated '$ITEM_NAME'"
    else
        op_create_item "$ITEM_NAME" "$ITEM_CATEGORY" "${fields[@]}" >/dev/null
        log_success "Created '$ITEM_NAME'"
    fi

    if op_item_exists "$AUTHELIA_ITEM"; then
        op_update_item "$AUTHELIA_ITEM" \
            "grafana_client_secret[password]=$oidc_secret" \
            "grafana_client_secret_hash[password]=$oidc_hash" >/dev/null
        log_success "Added Grafana client fields to '$AUTHELIA_ITEM'"
    else
        log_warning "'$AUTHELIA_ITEM' not found - skipped (hash is still in the configmap)"
    fi

    if [ "$ROTATE" = true ]; then
        patch_authelia_hash "$oidc_hash"
        log_success "Authelia configmap updated with the new hash"
        # keep the new admin password handy for finalize (Grafana stores it in its DB)
        umask 077; mkdir -p "$TEMP_SECRETS_DIR"
        printf '%s' "$admin_pass" > "$TEMP_SECRETS_DIR/.rotated-admin-password"
    fi

    sed -i 's|^  # - secrets/external-secrets.yaml|  - secrets/external-secrets.yaml|' "$OBS_KUSTOMIZATION"
    log_success "ExternalSecrets enabled in $OBS_KUSTOMIZATION"

    echo
    log_info "Next:"
    echo "  git add -A clusters && git commit -m 'observability: Grafana secrets from 1Password' && git push"
    echo "  # wait until ArgoCD synced infrastructure-observability, then:"
    echo "  $0 finalize"
}

# =============================================================================
finalize() {
    log_info "Waiting for the ExternalSecrets to exist..."
    for es in grafana-admin grafana-oidc; do
        if ! kc -n "$NAMESPACE" get externalsecret "$es" &>/dev/null; then
            log_error "ExternalSecret $NAMESPACE/$es not found - has ArgoCD synced the kustomization change?"
            exit 1
        fi
    done

    # ESO (creationPolicy Owner) will not adopt a Secret it did not create:
    # remove the temporary ones and let ESO recreate them from 1Password.
    log_info "Deleting temporary secrets (label temp-secret=true) so ESO can own them"
    kc -n "$NAMESPACE" delete secret -l temp-secret=true --ignore-not-found
    for es in grafana-admin grafana-oidc; do
        kc -n "$NAMESPACE" annotate externalsecret "$es" force-sync="$(date +%s)" --overwrite >/dev/null
    done
    for i in $(seq 1 30); do
        if kc -n "$NAMESPACE" get secret grafana-admin grafana-oidc &>/dev/null; then break; fi
        sleep 2
    done
    kc -n "$NAMESPACE" get secret grafana-admin grafana-oidc >/dev/null
    log_success "Secrets recreated by External Secrets Operator"

    # Grafana only reads the admin password when the user is first created;
    # set it explicitly so the DB matches 1Password.
    local new_pass
    new_pass="$(secret_value grafana-admin admin-password)"
    kc -n "$NAMESPACE" rollout restart deploy/kps-grafana
    kc -n "$NAMESPACE" rollout status deploy/kps-grafana --timeout=180s
    kc -n "$NAMESPACE" exec deploy/kps-grafana -c grafana -- grafana cli admin reset-admin-password "$new_pass" >/dev/null
    log_success "Grafana restarted, admin password matches 1Password"

    if [ -f "$TEMP_SECRETS_DIR/.rotated-admin-password" ]; then
        kc -n authelia rollout restart deploy/authelia
        log_success "Authelia restarted (new OIDC client hash)"
    fi
    rm -f "$TEMP_SECRETS_DIR/.rotated-admin-password"

    echo
    log_success "Done. Grafana: https://logs.tkuipers.ca (Authelia SSO; local admin at /login?disableAutoLogin)"
    log_info "Once everything works you can delete $TEMP_SECRETS_DIR"
}

[ "$MODE" = "finalize" ] && finalize || store
