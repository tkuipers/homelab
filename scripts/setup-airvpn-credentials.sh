#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="AirVPN"
ITEM_CATEGORY="login"
TEMP_DIR="/tmp/airvpn-setup-$$"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup function
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        log_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# Check if 1Password CLI is installed
check_op_cli() {
    if ! command -v op &> /dev/null; then
        log_error "1Password CLI (op) is not installed"
        log_info "Please install it from: https://developer.1password.com/docs/cli/get-started/"
        exit 1
    fi
    
    log_success "1Password CLI is installed"
    
    # Check if signed in
    if ! op vault list &> /dev/null; then
        log_error "Not signed in to 1Password CLI"
        log_info "Please run: eval \$(op signin)"
        exit 1
    fi
    
    log_success "Signed in to 1Password CLI"
}

# Check if vault exists
check_vault() {
    if ! op vault get "$VAULT_NAME" &> /dev/null; then
        log_error "Vault '$VAULT_NAME' not found"
        exit 1
    fi
    
    log_success "Vault '$VAULT_NAME' found"
}

# Prompt for file path
prompt_for_file() {
    local prompt_message="$1"
    local var_name="$2"
    local file_type="$3"
    
    while true; do
        echo -n "$prompt_message: "
        read file_path
        
        # Expand tilde to home directory
        file_path="${file_path/#\~/$HOME}"
        
        if [ ! -f "$file_path" ]; then
            log_error "File not found: $file_path"
            continue
        fi
        
        # Validate file extension
        if [[ "$file_type" == "ovpn" && ! "$file_path" =~ \.ovpn$ ]]; then
            log_warning "File should have .ovpn extension"
            echo -n "Continue anyway? [y/N]: "
            read confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                continue
            fi
        elif [[ "$file_type" == "crt" && ! "$file_path" =~ \.crt$ ]]; then
            log_warning "File should have .crt extension"
            echo -n "Continue anyway? [y/N]: "
            read confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                continue
            fi
        elif [[ "$file_type" == "key" && ! "$file_path" =~ \.key$ ]]; then
            log_warning "File should have .key extension"
            echo -n "Continue anyway? [y/N]: "
            read confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        
        eval "$var_name=\"$file_path\""
        break
    done
}

# Validate port number
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        log_error "Invalid port number. Must be between 1024 and 65535"
        return 1
    fi
    return 0
}

# Get current item if it exists
get_current_item() {
    log_info "Checking if item exists..."
    
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        CURRENT_PORT=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="forwarded_port" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_PORT=""
    fi
}

# Show instructions
show_instructions() {
    echo "========================================="
    echo "      AirVPN Credentials Setup"
    echo "========================================="
    echo
    log_info "AirVPN uses certificate-based authentication"
    echo
    log_info "Before continuing, download your configuration from AirVPN:"
    echo "  1. Go to: https://airvpn.org/generator/"
    echo "  2. Select your OS: Linux"
    echo "  3. Choose your preferred server(s)"
    echo "  4. Protocol: UDP (recommended) or TCP"
    echo "  5. Port: 443 (recommended)"
    echo "  6. Enable 'Advanced mode'"
    echo "  7. Check 'Separate keys/certs from .ovpn file'"
    echo "  8. Click 'Generate' and download the .tar.gz file"
    echo "  9. Extract it to a directory"
    echo
    log_info "You will also need to set up port forwarding:"
    echo "  1. Go to: https://airvpn.org/ports/"
    echo "  2. Click 'Add a forwarded port'"
    echo "  3. Note the port number assigned"
    echo
    echo -n "Press Enter when you have extracted the files and have your port number..."
    read
}

# Collect input
collect_input() {
    echo
    log_info "=== File Locations ==="
    echo
    
    prompt_for_file "Path to .ovpn config file" OVPN_FILE "ovpn"
    prompt_for_file "Path to ca.crt file" CA_FILE "crt"
    prompt_for_file "Path to user.crt file" USER_CRT_FILE "crt"
    prompt_for_file "Path to user.key file" USER_KEY_FILE "key"
    prompt_for_file "Path to ta.key file" TA_KEY_FILE "key"
    
    echo
    while true; do
        prompt_for_input "Forwarded Port" FORWARDED_PORT "$CURRENT_PORT"
        if validate_port "$FORWARDED_PORT"; then
            break
        fi
    done
}

# Prompt for input with default value
prompt_for_input() {
    local prompt_message="$1"
    local var_name="$2"
    local default_value="${3:-}"
    
    if [ -n "$default_value" ]; then
        echo -n "$prompt_message [current: $default_value]: "
    else
        echo -n "$prompt_message: "
    fi
    
    read user_input
    
    if [ -z "$user_input" ] && [ -n "$default_value" ]; then
        eval "$var_name=\"$default_value\""
    else
        eval "$var_name=\"$user_input\""
    fi
}

# Modify ovpn file to use correct paths
prepare_ovpn_config() {
    log_info "Preparing OpenVPN configuration..."
    
    mkdir -p "$TEMP_DIR"
    
    # Copy ovpn file and update paths
    cp "$OVPN_FILE" "$TEMP_DIR/custom.conf"
    
    # Update certificate paths in the config
    sed -i 's|ca .*|ca /gluetun/config/ca.crt|g' "$TEMP_DIR/custom.conf"
    sed -i 's|cert .*|cert /gluetun/config/user.crt|g' "$TEMP_DIR/custom.conf"
    sed -i 's|key .*|key /gluetun/config/user.key|g' "$TEMP_DIR/custom.conf"
    sed -i 's|tls-auth .*|tls-auth /gluetun/config/ta.key|g' "$TEMP_DIR/custom.conf"
    
    log_success "OpenVPN configuration prepared"
}

# Create or update item in 1Password
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  OpenVPN Config: $(basename "$OVPN_FILE")"
    echo "  CA Certificate: $(basename "$CA_FILE")"
    echo "  User Certificate: $(basename "$USER_CRT_FILE")"
    echo "  User Key: $(basename "$USER_KEY_FILE")"
    echo "  TLS Auth Key: $(basename "$TA_KEY_FILE")"
    echo "  Forwarded Port: $FORWARDED_PORT"
    echo
    
    echo -n "Proceed with $(if [ "$ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        return 1
    fi
    
    log_info "Encoding files to base64..."
    
    # Base64 encode all files
    CA_CRT_B64=$(base64 -w 0 "$CA_FILE")
    USER_CRT_B64=$(base64 -w 0 "$USER_CRT_FILE")
    USER_KEY_B64=$(base64 -w 0 "$USER_KEY_FILE")
    TA_KEY_B64=$(base64 -w 0 "$TA_KEY_FILE")
    CUSTOM_CONF_B64=$(base64 -w 0 "$TEMP_DIR/custom.conf")
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item in 1Password..."
        
        op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
            "ca.crt[text]=$CA_CRT_B64" \
            "user.crt[text]=$USER_CRT_B64" \
            "user.key[password]=$USER_KEY_B64" \
            "ta.key[text]=$TA_KEY_B64" \
            "custom.conf[text]=$CUSTOM_CONF_B64" \
            "forwarded_port[text]=$FORWARDED_PORT"
        
        log_success "Item '$ITEM_NAME' updated successfully in 1Password"
    else
        log_info "Creating new item in 1Password..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "ca.crt[text]=$CA_CRT_B64" \
            "user.crt[text]=$USER_CRT_B64" \
            "user.key[password]=$USER_KEY_B64" \
            "ta.key[text]=$TA_KEY_B64" \
            "custom.conf[text]=$CUSTOM_CONF_B64" \
            "forwarded_port[text]=$FORWARDED_PORT" \
            "notesPlain=AirVPN OpenVPN credentials for Transmission VPN sidecar. Static port forwarding configured. Files are base64 encoded."
        
        log_success "Item '$ITEM_NAME' created successfully in 1Password"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "AirVPN credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. The ExternalSecret will automatically sync credentials from 1Password"
    echo "2. Apply the updated manifests (if not already done):"
    echo "   kubectl apply -k clusters/homelab/apps/mediacenter/"
    echo
    echo "3. Watch the Transmission pod restart with Gluetun VPN sidecar:"
    echo "   kubectl rollout status -n mediacenter deployment/transmission"
    echo
    echo "4. Verify VPN connection is active:"
    echo "   kubectl logs -n mediacenter deployment/transmission -c gluetun --tail=50"
    echo "   (Look for 'ip getter: ip: X.X.X.X' - should be AirVPN IP)"
    echo
    echo "5. Test that traffic goes through VPN:"
    echo "   kubectl exec -n mediacenter deployment/transmission -c transmission -- wget -qO- ifconfig.me"
    echo "   (Should show AirVPN IP, not your home IP)"
    echo
    log_info "Configuration details:"
    echo "  VPN Provider: AirVPN (custom OpenVPN config)"
    echo "  Forwarded Port: $FORWARDED_PORT (static)"
    echo "  Kill Switch: Enabled"
    echo "  Authentication: Certificate-based"
    echo
    log_warning "Important: All Transmission traffic will now route through AirVPN"
    log_warning "If VPN is down, Transmission will have no network connectivity (by design)"
    echo
}

# Main execution
main() {
    check_op_cli
    check_vault
    
    show_instructions
    
    get_current_item
    
    collect_input
    prepare_ovpn_config
    create_or_update_item
    
    show_next_steps
}

# Run main function
main "$@"
