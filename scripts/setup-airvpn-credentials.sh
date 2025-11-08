#!/bin/bash

set -euo pipefail

# Configuration
SECRET_NAME="airvpn-credentials"
NAMESPACE="mediacenter"
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

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed"
        exit 1
    fi
    
    log_success "kubectl is installed"
}

# Check if namespace exists
check_namespace() {
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist"
        exit 1
    fi
    
    log_success "Namespace '$NAMESPACE' found"
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
    echo "  4. Enable 'Advanced mode'"
    echo "  5. Check 'Separate keys/certs from .ovpn file'"
    echo "  6. Click 'Generate' and download the .tar.gz file"
    echo "  7. Extract it to a directory"
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
        echo -n "Forwarded Port (from AirVPN portal): "
        read FORWARDED_PORT
        if validate_port "$FORWARDED_PORT"; then
            break
        fi
    done
}

# Modify ovpn file to use correct paths
prepare_ovpn_config() {
    log_info "Preparing OpenVPN configuration..."
    
    mkdir -p "$TEMP_DIR"
    
    # Copy ovpn file and update paths
    cp "$OVPN_FILE" "$TEMP_DIR/custom.conf"
    
    # Update certificate paths in the config
    sed -i 's|ca .*|ca /gluetun/ca.crt|g' "$TEMP_DIR/custom.conf"
    sed -i 's|cert .*|cert /gluetun/user.crt|g' "$TEMP_DIR/custom.conf"
    sed -i 's|key .*|key /gluetun/user.key|g' "$TEMP_DIR/custom.conf"
    sed -i 's|tls-auth .*|tls-auth /gluetun/ta.key|g' "$TEMP_DIR/custom.conf"
    
    log_success "OpenVPN configuration prepared"
}

# Create or update secret
create_or_update_secret() {
    echo
    log_info "Configuration summary:"
    echo "  OpenVPN Config: $(basename "$OVPN_FILE")"
    echo "  CA Certificate: $(basename "$CA_FILE")"
    echo "  User Certificate: $(basename "$USER_CRT_FILE")"
    echo "  User Key: $(basename "$USER_KEY_FILE")"
    echo "  TLS Auth Key: $(basename "$TA_KEY_FILE")"
    echo "  Forwarded Port: $FORWARDED_PORT"
    echo
    
    # Check if secret already exists
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_warning "Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE'"
        echo -n "Do you want to replace it? [y/N]: "
        read confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Deleting existing secret..."
            kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
        else
            log_info "Operation cancelled"
            exit 0
        fi
    fi
    
    echo -n "Proceed with secret creation? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
    
    log_info "Creating Kubernetes secret..."
    
    kubectl create secret generic "$SECRET_NAME" \
        --namespace="$NAMESPACE" \
        --from-file=custom.conf="$TEMP_DIR/custom.conf" \
        --from-file=ca.crt="$CA_FILE" \
        --from-file=user.crt="$USER_CRT_FILE" \
        --from-file=user.key="$USER_KEY_FILE" \
        --from-file=ta.key="$TA_KEY_FILE" \
        --from-literal=forwarded_port="$FORWARDED_PORT"
    
    log_success "Secret '$SECRET_NAME' created successfully in namespace '$NAMESPACE'"
}

# Show next steps
show_next_steps() {
    echo
    log_success "AirVPN configuration is complete!"
    echo
    log_info "Next steps:"
    echo "1. Apply the Transmission deployment:"
    echo "   kubectl apply -k clusters/homelab/apps/mediacenter/"
    echo
    echo "2. Watch the Transmission pod restart with Gluetun VPN sidecar:"
    echo "   kubectl rollout status -n mediacenter deployment/transmission"
    echo
    echo "3. Verify VPN connection is active:"
    echo "   kubectl logs -n mediacenter deployment/transmission -c gluetun --tail=50"
    echo "   (Look for 'ip getter: ip: X.X.X.X' - should be AirVPN IP)"
    echo
    echo "4. Test that traffic goes through VPN:"
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
    check_kubectl
    check_namespace
    
    show_instructions
    
    collect_input
    prepare_ovpn_config
    create_or_update_secret
    
    show_next_steps
}

# Run main function
main "$@"
