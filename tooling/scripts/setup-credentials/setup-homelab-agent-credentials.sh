#!/bin/bash
#
# Credentials for the homelab agent (clusters/homelab/apps/homelab-agent),
# stored in the 1Password item "Homelab Agent Credentials" (Homelab vault).
# The agent's ExternalSecret takes every field of the item.
#
#   webhook-token         bearer token Grafana / Alertmanager send (generated)
#   twilio-account-sid    Twilio account (console.twilio.com, Account info)
#   twilio-auth-token     Twilio auth token (also signs the incoming-SMS webhook)
#   sms-from              the agent's Twilio number, E.164 (+1...)
#   sms-allowed-numbers   your mobile number(s), E.164, comma separated
#   typesafe-api-key      Jev classifier key (console.typesafe.ai)
#
# Other credentials the agent uses (not managed here):
#   "Agent SSH Key", "Agent SSH Signing Key" (1Password, Homelab vault): Tyler's keys; the
#        agent clones/pushes and signs commits as him through its ssh-agent sidecar
#   "Homelab Agent MCP Secrets" (optional): values MCP servers reference by name
#   HOMELAB_DEPLOY_KEY (Actions secret in tkuipers/homelab-agent): CI's write deploy key
#        on tkuipers/homelab, used only to pin new image digests
#
# Usage:
#   ./setup-homelab-agent-credentials.sh                # create what's missing, ask for the rest
#   ./setup-homelab-agent-credentials.sh --rotate-token # new webhook token (restart Grafana + Alertmanager after)
#   ./setup-homelab-agent-credentials.sh --generated-only  # only the webhook token, no prompts
#
# Afterwards ESO picks the values up within an hour; to apply right away:
#   kubectl -n homelab-agent annotate externalsecret homelab-agent force-sync=$(date +%s) --overwrite
#   kubectl -n homelab-agent rollout restart deploy/homelab-agent deploy/homelab-agent-relay
#
# Twilio: point the number's "A message comes in" webhook at
#   https://agent.tkuipers.ca/hooks/sms  (HTTP POST)
# (the agent sets the fallback URL, /hooks/sms-fallback on the relay, itself)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

ITEM_NAME="Homelab Agent Credentials"
ROTATE_TOKEN=false
GENERATED_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --rotate-token) ROTATE_TOKEN=true ;;
        --generated-only) GENERATED_ONLY=true ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
done

check_op_cli
check_vault

field() { op_get_field "$ITEM_NAME" "$1"; }

if ! op_item_exists "$ITEM_NAME"; then
    log_info "Creating 1Password item '$ITEM_NAME'"
    op item create --vault="$VAULT_NAME" --category="Secure Note" --title="$ITEM_NAME" \
        "notesPlain=Credentials for the homelab agent (agent.tkuipers.ca). See tooling/scripts/setup-credentials/setup-homelab-agent-credentials.sh" >/dev/null
fi

UPDATES=()

# --- retired: the old deploy key (the agent now uses Tyler's own SSH keys) -----------
if [ -n "$(field git-ssh-private-key)" ]; then
    op item edit "$ITEM_NAME" --vault="$VAULT_NAME" "git-ssh-private-key[delete]" >/dev/null
    log_success "Removed the unused git-ssh-private-key field"
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
