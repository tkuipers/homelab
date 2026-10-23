#!/bin/bash
#
# GitHub App for the self-hosted Actions runners (clusters/homelab/infrastructure/github-runners),
# stored in the 1Password item "GitHub Actions Runner App" (Homelab vault):
#
#   app-id               the App's ID (App settings page, "About")
#   installation-id      its installation on tkuipers (found by this script)
#   private-key-base64   the App's private key (.pem), base64 encoded on one line
#
# The controller authenticates as the App to register runners and poll for jobs. Repository
# runners need the App permissions Administration: Read and write + Metadata: Read-only
# (docs.github.com/en/actions/tutorials/use-actions-runner-controller/authenticate-to-the-api).
#
# Usage:
#   ./setup-github-runner-credentials.sh              # register/install the App, store it
#   ./setup-github-runner-credentials.sh --check      # only verify the stored App can reach the repos
#
# Attach another repo: github.com/settings/installations -> the App -> Configure ->
# add the repository, then add its scale set (see the github-runners README).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

ITEM_NAME="GitHub Actions Runner App"
APP_NAME="tkuipers-homelab-runners"
# repos with a scale set in clusters/homelab/infrastructure/github-runners/values.yaml
REPOS=(tkuipers/homelab-agent)

CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=true ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $arg"; exit 1 ;;
    esac
done

for tool in openssl curl jq base64; do
    command_exists "$tool" || { log_error "$tool is required"; exit 1; }
done

check_op_cli
check_vault

field() { op_get_field "$ITEM_NAME" "$1"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# app_jwt <app-id> <pem-file>: the RS256 JWT an App uses to call /app endpoints (valid 9 min)
app_jwt() {
    local now header payload unsigned
    now=$(date +%s)
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$1" | b64url)
    unsigned="$header.$payload"
    printf '%s.%s' "$unsigned" "$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$2" -binary | b64url)"
}

gh_api() {   # gh_api <bearer> <path> [curl args...]
    local token="$1" path="$2"; shift 2
    curl -fsS -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" "$@" "https://api.github.com$path"
}

# verify <app-id> <installation-id> <pem-file>: the installation can see every repo in REPOS
verify() {
    local jwt token visible missing=0
    jwt=$(app_jwt "$1" "$3")
    token=$(gh_api "$jwt" "/app/installations/$2/access_tokens" -X POST | jq -r .token) || {
        log_error "Could not get an installation token (wrong App ID, installation ID or key?)"; return 1; }
    visible=$(gh_api "$token" "/installation/repositories?per_page=100" | jq -r '.repositories[].full_name')
    for repo in "${REPOS[@]}"; do
        if grep -qx "$repo" <<<"$visible"; then
            log_success "App can reach $repo"
        else
            log_error "App is not installed on $repo (Configure the installation and add it)"; missing=1
        fi
    done
    return $missing
}

if [ "$CHECK_ONLY" = true ]; then
    pem=$(mktemp); trap 'rm -f "$pem"' EXIT
    # op read: `op item get --fields` masks concealed fields
    op read "op://$VAULT_NAME/$ITEM_NAME/private-key-base64" | base64 -d > "$pem"
    verify "$(field app-id)" "$(field installation-id)" "$pem"
    exit $?
fi

# --- 1. register the App (pre-filled form: no webhook, private, repo permissions only) ---
REGISTER_URL="https://github.com/settings/apps/new?name=$APP_NAME"
REGISTER_URL+="&description=Actions%20Runner%20Controller%20on%20the%20homelab%20cluster"
REGISTER_URL+="&url=https://github.com/tkuipers/homelab&public=false&webhook_active=false"
REGISTER_URL+="&administration=write&metadata=read"

current_app_id="$(field app-id)"
echo
log_info "1. Register the GitHub App (skip if it exists$([ -n "$current_app_id" ] && echo "; stored App ID: $current_app_id")):"
echo "     $REGISTER_URL"
echo "   Click 'Create GitHub App', then on its page: 'Generate a private key' (downloads a .pem)."
log_info "2. Install it: left sidebar 'Install App' -> tkuipers -> 'Only select repositories' -> ${REPOS[*]#tkuipers/}"
echo

echo -n "App ID${current_app_id:+ [$current_app_id; Enter keeps it]}: "
read -r app_id
app_id="${app_id:-$current_app_id}"
[[ "$app_id" =~ ^[0-9]+$ ]] || { log_error "App ID must be a number"; exit 1; }

pem_default=$(ls -t "$HOME"/Downloads/"$APP_NAME".*.private-key.pem /mnt/c/Users/*/Downloads/"$APP_NAME".*.private-key.pem 2>/dev/null | head -1 || true)
echo -n "Private key file${pem_default:+ [$pem_default]}: "
read -r pem_file
pem_file="${pem_file:-$pem_default}"
if [ -z "$pem_file" ] || ! openssl pkey -in "$pem_file" -noout 2>/dev/null; then
    log_error "Not a readable private key: ${pem_file:-<none>}"; exit 1
fi

# --- 3. find the installation on tkuipers ------------------------------------------------
installation_id=$(gh_api "$(app_jwt "$app_id" "$pem_file")" "/app/installations" |
    jq -r '.[] | select(.account.login == "tkuipers") | .id' | head -1) || true
if [ -z "$installation_id" ]; then
    log_error "The App has no installation on tkuipers yet (step 2)"; exit 1
fi
log_success "Installation ID: $installation_id"

verify "$app_id" "$installation_id" "$pem_file" || exit 1

# --- 4. store ----------------------------------------------------------------------------
if ! op_item_exists "$ITEM_NAME"; then
    op item create --vault="$VAULT_NAME" --category="Secure Note" --title="$ITEM_NAME" \
        "notesPlain=GitHub App ($APP_NAME) for the homelab's Actions runners. See tooling/scripts/setup-credentials/setup-github-runner-credentials.sh" >/dev/null
    log_success "Created 1Password item '$ITEM_NAME'"
fi
op_update_item "$ITEM_NAME" \
    "app-id[text]=$app_id" \
    "installation-id[text]=$installation_id" \
    "private-key-base64[password]=$(base64 -w0 < "$pem_file")" >/dev/null
log_success "Stored the App in '$ITEM_NAME'"

if confirm_action "Delete $pem_file (1Password has it now)?"; then
    rm -f -- "$pem_file" && log_success "Deleted"
fi

echo
log_info "ESO picks it up within an hour; to apply right away:"
echo "  kubectl -n arc-runners annotate externalsecret github-app force-sync=\$(date +%s) --overwrite"
