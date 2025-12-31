#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="AirVPN"
ITEM_CATEGORY="login"

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
        CURRENT_COUNTRY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="server_country" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_PORT=""
        CURRENT_COUNTRY=""
    fi
}

# Show instructions
show_instructions() {
    echo "========================================="
    echo "      AirVPN WireGuard Setup"
    echo "========================================="
    echo
    log_info "Before continuing, download your WireGuard configuration from AirVPN:"
    echo "  1. Go to: https://airvpn.org/generator/"
    echo "  2. Select your OS: Linux"
    echo "  3. Protocol: WireGuard"
    echo "  4. Choose your preferred server(s)"
    echo "  5. Click 'Generate' and download the .tar.gz file"
    echo "  6. Extract it to a directory"
    echo
    log_info "You will also need to set up port forwarding:"
    echo "  1. Go to: https://airvpn.org/ports/"
    echo "  2. Click 'Add a forwarded port'"
    echo "  3. Note the port number assigned"
    echo
}

# Find WireGuard config file in directory
find_wireguard_config() {
    local config_dir="$1"
    
    log_info "Searching for WireGuard config in: $config_dir"
    
    # Find .conf files
    local conf_files=($(find "$config_dir" -maxdepth 1 -name "*.conf" 2>/dev/null))
    
    if [ ${#conf_files[@]} -eq 0 ]; then
        log_error "No .conf files found in directory"
        return 1
    fi
    
    if [ ${#conf_files[@]} -eq 1 ]; then
        WG_CONFIG_FILE="${conf_files[0]}"
        log_success "Found WireGuard config: $(basename "$WG_CONFIG_FILE")"
        return 0
    fi
    
    # Multiple configs found, let user choose
    log_info "Multiple WireGuard configs found:"
    local i=1
    for conf in "${conf_files[@]}"; do
        echo "  $i) $(basename "$conf")"
        ((i++))
    done
    
    while true; do
        echo -n "Select config file (1-${#conf_files[@]}): "
        read selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#conf_files[@]}" ]; then
            WG_CONFIG_FILE="${conf_files[$((selection-1))]}"
            log_success "Selected: $(basename "$WG_CONFIG_FILE")"
            return 0
        fi
        log_error "Invalid selection"
    done
}

# Parse WireGuard config file
parse_wireguard_config() {
    log_info "Parsing WireGuard configuration..."
    
    if [ ! -f "$WG_CONFIG_FILE" ]; then
        log_error "Config file not found: $WG_CONFIG_FILE"
        return 1
    fi
    
    # Extract PrivateKey
    PRIVATE_KEY=$(grep -oP '^PrivateKey\s*=\s*\K.*' "$WG_CONFIG_FILE" | tr -d '[:space:]')
    if [ -z "$PRIVATE_KEY" ]; then
        log_error "Could not find PrivateKey in config"
        return 1
    fi
    
    # Extract Address
    ADDRESSES=$(grep -oP '^Address\s*=\s*\K.*' "$WG_CONFIG_FILE" | tr -d '[:space:]')
    if [ -z "$ADDRESSES" ]; then
        log_error "Could not find Address in config"
        return 1
    fi
    
    # Extract PresharedKey
    PRESHARED_KEY=$(grep -oP '^PresharedKey\s*=\s*\K.*' "$WG_CONFIG_FILE" | tr -d '[:space:]')
    if [ -z "$PRESHARED_KEY" ]; then
        log_warning "Could not find PresharedKey in config (may not be required)"
        PRESHARED_KEY=""
    fi
    
    # Extract server location from filename or endpoint
    local filename=$(basename "$WG_CONFIG_FILE" .conf)
    
    # Try to extract country from filename (e.g., AirVPN_America-USA_UDP-1637.conf -> USA)
    if [[ "$filename" =~ -([A-Za-z]+)_ ]]; then
        SERVER_COUNTRY="${BASH_REMATCH[1]}"
    elif [[ "$filename" =~ ^([A-Za-z]+)- ]]; then
        SERVER_COUNTRY="${BASH_REMATCH[1]}"
    else
        # Fallback: extract from endpoint hostname
        local endpoint=$(grep -oP '^Endpoint\s*=\s*\K[^:]+' "$WG_CONFIG_FILE")
        if [[ "$endpoint" =~ ^([a-z]+)[0-9] ]]; then
            SERVER_COUNTRY="${BASH_REMATCH[1]}"
        else
            SERVER_COUNTRY="USA"  # Default fallback
        fi
    fi
    
    log_success "Parsed WireGuard configuration:"
    echo "  Private Key: ${PRIVATE_KEY:0:20}..."
    echo "  Addresses: $ADDRESSES"
    if [ -n "$PRESHARED_KEY" ]; then
        echo "  Preshared Key: ${PRESHARED_KEY:0:20}..."
    fi
    echo "  Detected Country: $SERVER_COUNTRY"
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

# Collect input
collect_input() {
    echo
    log_info "=== Configuration Directory ==="
    echo
    
    while true; do
        echo -n "Path to AirVPN config directory: "
        read config_dir
        
        # Expand tilde to home directory
        config_dir="${config_dir/#\~/$HOME}"
        
        if [ ! -d "$config_dir" ]; then
            log_error "Directory not found: $config_dir"
            continue
        fi
        
        if find_wireguard_config "$config_dir"; then
            break
        fi
    done
    
    if ! parse_wireguard_config; then
        log_error "Failed to parse WireGuard config"
        exit 1
    fi
    
    echo
    log_info "=== Additional Configuration ==="
    echo
    
    # Allow user to override detected country
    prompt_for_input "Server Country" SERVER_COUNTRY "$SERVER_COUNTRY"
    
    # Get forwarded port
    while true; do
        prompt_for_input "Forwarded Port (from AirVPN portal)" FORWARDED_PORT "$CURRENT_PORT"
        if validate_port "$FORWARDED_PORT"; then
            break
        fi
    done
}

# Create or update item in 1Password
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  WireGuard Config: $(basename "$WG_CONFIG_FILE")"
    echo "  Server Country: $SERVER_COUNTRY"
    echo "  Addresses: $ADDRESSES"
    echo "  Forwarded Port: $FORWARDED_PORT"
    echo
    
    echo -n "Proceed with $(if [ "$ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        return 1
    fi
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item in 1Password..."
        
        if [ -n "$PRESHARED_KEY" ]; then
            op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
                "private_key[password]=$PRIVATE_KEY" \
                "preshared_key[password]=$PRESHARED_KEY" \
                "addresses[text]=$ADDRESSES" \
                "server_country[text]=$SERVER_COUNTRY" \
                "forwarded_port[text]=$FORWARDED_PORT"
        else
            op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
                "private_key[password]=$PRIVATE_KEY" \
                "addresses[text]=$ADDRESSES" \
                "server_country[text]=$SERVER_COUNTRY" \
                "forwarded_port[text]=$FORWARDED_PORT"
        fi
        
        log_success "Item '$ITEM_NAME' updated successfully in 1Password"
    else
        log_info "Creating new item in 1Password..."
        
        if [ -n "$PRESHARED_KEY" ]; then
            op item create --vault="$VAULT_NAME" \
                --category="$ITEM_CATEGORY" \
                --title="$ITEM_NAME" \
                "private_key[password]=$PRIVATE_KEY" \
                "preshared_key[password]=$PRESHARED_KEY" \
                "addresses[text]=$ADDRESSES" \
                "server_country[text]=$SERVER_COUNTRY" \
                "forwarded_port[text]=$FORWARDED_PORT" \
                "notesPlain=AirVPN WireGuard credentials for Transmission VPN sidecar. Static port forwarding configured."
        else
            op item create --vault="$VAULT_NAME" \
                --category="$ITEM_CATEGORY" \
                --title="$ITEM_NAME" \
                "private_key[password]=$PRIVATE_KEY" \
                "addresses[text]=$ADDRESSES" \
                "server_country[text]=$SERVER_COUNTRY" \
                "forwarded_port[text]=$FORWARDED_PORT" \
                "notesPlain=AirVPN WireGuard credentials for Transmission VPN sidecar. Static port forwarding configured."
        fi
        
        log_success "Item '$ITEM_NAME' created successfully in 1Password"
    fi
}

# Show next steps
show_next_steps() {
    echo
    log_success "AirVPN WireGuard credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. The ExternalSecret will automatically sync credentials from 1Password"
    echo "2. Commit and push the updated manifests if not already done"
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
    echo "  VPN Provider: AirVPN"
    echo "  Protocol: WireGuard"
    echo "  Server Country: $SERVER_COUNTRY"
    echo "  Forwarded Port: $FORWARDED_PORT (static)"
    echo "  Kill Switch: Enabled"
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
    create_or_update_item
    
    show_next_steps
}

# Run main function
main "$@"
