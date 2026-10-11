#!/bin/bash
#
# Credentials for the homelab agent (clusters/homelab/apps/homelab-agent),
# stored in the 1Password item "Homelab Agent Credentials" (Homelab vault).
# The agent's ExternalSecret takes every field of the item.
#
#   git-ssh-private-key   deploy key with WRITE access to tkuipers/homelab
#                         (generated here; the public half is added to GitHub)
#   webhook-token         bearer token Grafana / Alertmanager send (generated)
#   twilio-account-sid    Twilio account (console.twilio.com, Account info)
#   twilio-auth-token     Twilio auth token (also signs the incoming-SMS webhook)
#   sms-from              the agent's Twilio number, E.164 (+1...)
#   sms-allowed-numbers   your mobile number(s), E.164, comma separated
#   typesafe-api-key      Jev classifier key (console.typesafe.ai)
#
# Usage:
#   ./setup-homelab-agent-credentials.sh                # create what's missing, ask for the rest
#   ./setup-homelab-agent-credentials.sh --rotate-key   # new deploy key (old one removed from GitHub)
#   ./setup-homelab-agent-credentials.sh --rotate-token # new webhook token (restart Grafana + Alertmanager after)
#   ./setup-homelab-agent-credentials.sh --generated-only  # only the deploy key + webhook token, no prompts
#
# Afterwards ESO picks the values up within an hour; to apply right away:
#   kubectl -n homelab-agent annotate externalsecret homelab-agent force-sync=$(date +%s) --overwrite
#   kubectl -n homelab-agent rollout restart deploy/homelab-agent deploy/homelab-agent-relay
#
# Twilio: point the number's "A message comes in" webhook at
#   https://agent.tkuipers.ca/hooks/sms  (HTTP POST)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

ITEM_NAME="Homelab Agent Credentials"
REPO="tkuipers/homelab"
DEPLOY_KEY_TITLE="homelab-agent (write)"

ROTATE_KEY=false
ROTATE_TOKEN=false
GENERATED_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --rotate-key) ROTATE_KEY=true ;;
        --rotate-token) ROTATE_TOKEN=true ;;
        --generated-only) GENERATED_ONLY=true ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
done

check_op_cli
check_vault
command -v gh &>/dev/null || { log_error "GitHub CLI (gh) is required for the deploy key"; exit 1; }

field() { op_get_field "$ITEM_NAME" "$1"; }

if ! op_item_exists "$ITEM_NAME"; then
    log_info "Creating 1Password item '$ITEM_NAME'"
    op item create --vault="$VAULT_NAME" --category="Secure Note" --title="$ITEM_NAME" \
        "notesPlain=Credentials for the homelab agent (agent.tkuipers.ca). See tooling/scripts/setup-credentials/setup-homelab-agent-credentials.sh" >/dev/null
fi

UPDATES=()

# --- deploy key -----------------------------------------------------------------
if [ "$ROTATE_KEY" = true ] || [ -z "$(field git-ssh-private-key)" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    ssh-keygen -q -t ed25519 -N "" -C "homelab-agent@tkuipers.ca" -f "$tmp/key"
    # remove an older key with the same title
    for id in $(gh api "repos/$REPO/keys" --jq ".[] | select(.title == \"$DEPLOY_KEY_TITLE\") | .id"); do
        gh api -X DELETE "repos/$REPO/keys/$id" >/dev/null
        log_info "Removed old deploy key $id"
    done
    gh repo deploy-key add "$tmp/key.pub" --repo "$REPO" --allow-write --title "$DEPLOY_KEY_TITLE" >/dev/null
    log_success "Deploy key with write access added to $REPO"
    UPDATES+=("git-ssh-private-key[password]=$(cat "$tmp/key")")
else
    log_info "Deploy key: keeping the existing one"
fi

# --- webhook token ----------------------------------------------------------------
if [ "$ROTATE_TOKEN" = true ] || [ -z "$(field webhook-token)" ]; then
    UPDATES+=("webhook-token[password]=$(openssl rand -hex 32)")
    log_success "Generated a new webhook token"
    [ "$ROTATE_TOKEN" = true ] && log_warning "Restart Grafana and Alertmanager once ESO has synced the new token"
else
    log_info "Webhook token: keeping the existing one"
fi

# --- values only you have -----------------------------------------------------------
ask() {   # ask <field> <prompt> <secret:true|false>
    local name="$1" prompt="$2" secret="$3" current value
    current="$(field "$name")"
    if [ -n "$current" ]; then
        echo -n "$prompt [set; Enter keeps it]: "
    else
        echo -n "$prompt [Enter skips]: "
    fi
    if [ "$secret" = true ]; then read -rs value; echo; else read -r value; fi
    if [ -n "$value" ]; then
        local type=text
        [ "$secret" = true ] && type=password
        UPDATES+=("$name[$type]=$value")
    fi
}

if [ "$GENERATED_ONLY" = false ]; then
    echo
    log_info "Twilio (console.twilio.com) and Jev (console.typesafe.ai)"
    ask twilio-account-sid "Twilio Account SID (AC...)" false
    ask twilio-auth-token "Twilio Auth Token" true
    ask sms-from "Agent's Twilio number, E.164 (+1...)" false
    ask sms-allowed-numbers "Your mobile number(s), E.164, comma separated" false
    ask typesafe-api-key "TypeSafe (Jev) API key" true
fi

if [ ${#UPDATES[@]} -gt 0 ]; then
    op_update_item "$ITEM_NAME" "${UPDATES[@]}" >/dev/null
    log_success "Updated '$ITEM_NAME' (${#UPDATES[@]} field(s))"
else
    log_info "Nothing to change"
fi

echo
log_info "To apply now:"
echo "  kubectl -n homelab-agent annotate externalsecret homelab-agent force-sync=\$(date +%s) --overwrite"
echo "  kubectl -n homelab-agent rollout restart deploy/homelab-agent deploy/homelab-agent-relay"
log_info "Twilio number -> Messaging -> 'A message comes in': https://agent.tkuipers.ca/hooks/sms (HTTP POST)"
