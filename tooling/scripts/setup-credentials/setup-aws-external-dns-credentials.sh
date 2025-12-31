#!/bin/bash

set -euo pipefail

# Configuration
VAULT_NAME="Homelab"
ITEM_NAME="AWS Credentials"
ITEM_CATEGORY="login"
IAM_USER_NAME="external-dns-homelab"
IAM_POLICY_NAME="ExternalDNSRoute53Policy"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Function to prompt for input with validation
prompt_for_input() {
    local prompt="$1"
    local var_name="$2"
    local current_value="${3:-}"
    local is_secret="${4:-false}"
    
    if [ -n "$current_value" ]; then
        if [ "$is_secret" = "true" ]; then
            echo -n "$prompt [current: ****]: "
        else
            echo -n "$prompt [current: $current_value]: "
        fi
    else
        echo -n "$prompt: "
    fi
    
    if [ "$is_secret" = "true" ]; then
        read -s input
        echo  # Add newline after hidden input
    else
        read input
    fi
    
    # Use current value if no input provided
    if [ -z "$input" ] && [ -n "$current_value" ]; then
        input="$current_value"
    fi
    
    eval "$var_name='$input'"
}

# Check if AWS CLI is available
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed or not in PATH"
        log_info "Install it from: https://aws.amazon.com/cli/"
        exit 1
    fi
    
    # Check if configured
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS CLI is not configured or credentials are invalid"
        log_info "Run: aws configure"
        exit 1
    fi
    
    log_success "AWS CLI is available and configured"
    
    # Show current identity
    CURRENT_IDENTITY=$(aws sts get-caller-identity --output json)
    CURRENT_USER=$(echo "$CURRENT_IDENTITY" | jq -r '.Arn')
    log_info "Current AWS identity: $CURRENT_USER"
}

# Check if op CLI is available
check_op_cli() {
    if ! command -v op &> /dev/null; then
        log_error "1Password CLI (op) is not installed or not in PATH"
        log_info "Install it from: https://developer.1password.com/docs/cli/get-started/"
        exit 1
    fi
    
    # Check if signed in
    if ! op account get &> /dev/null; then
        log_error "Not signed in to 1Password CLI"
        log_info "Run: op signin"
        exit 1
    fi
    
    log_success "1Password CLI is available and signed in"
}

# Check if jq is available
check_jq() {
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed or not in PATH"
        log_info "Install it: sudo apt install jq (Debian/Ubuntu) or brew install jq (macOS)"
        exit 1
    fi
}

# Check if vault exists
check_vault() {
    if ! op vault get "$VAULT_NAME" &> /dev/null; then
        log_error "Vault '$VAULT_NAME' not found"
        log_info "Available vaults:"
        op vault list
        exit 1
    fi
    
    log_success "Vault '$VAULT_NAME' found"
}

# Get current item if it exists
get_current_item() {
    log_info "Checking if item '$ITEM_NAME' exists..."
    
    if op item get "$ITEM_NAME" --vault="$VAULT_NAME" &> /dev/null; then
        log_success "Item '$ITEM_NAME' found"
        ITEM_EXISTS=true
        
        # Get current values
        CURRENT_ACCESS_KEY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="access_key_id" 2>/dev/null || echo "")
        CURRENT_SECRET_KEY=$(op item get "$ITEM_NAME" --vault="$VAULT_NAME" --fields="secret_access_key" 2>/dev/null || echo "")
    else
        log_info "Item '$ITEM_NAME' does not exist - will create new item"
        ITEM_EXISTS=false
        CURRENT_ACCESS_KEY=""
        CURRENT_SECRET_KEY=""
    fi
}

# Create IAM policy
create_iam_policy() {
    log_info "Checking if IAM policy '$IAM_POLICY_NAME' exists..."
    
    POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$IAM_POLICY_NAME'].Arn" --output text)
    
    if [ -n "$POLICY_ARN" ]; then
        log_success "Policy already exists: $POLICY_ARN"
    else
        log_info "Creating IAM policy '$IAM_POLICY_NAME'..."
        
        POLICY_DOCUMENT='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}'
        
        POLICY_ARN=$(aws iam create-policy \
            --policy-name "$IAM_POLICY_NAME" \
            --policy-document "$POLICY_DOCUMENT" \
            --description "Policy for external-dns to manage Route53 DNS records" \
            --query 'Policy.Arn' \
            --output text)
        
        log_success "Policy created: $POLICY_ARN"
    fi
}

# Create IAM user
create_iam_user() {
    log_info "Checking if IAM user '$IAM_USER_NAME' exists..."
    
    if aws iam get-user --user-name "$IAM_USER_NAME" &> /dev/null; then
        log_success "User '$IAM_USER_NAME' already exists"
        USER_EXISTS=true
    else
        log_info "Creating IAM user '$IAM_USER_NAME'..."
        
        aws iam create-user \
            --user-name "$IAM_USER_NAME" \
            --tags "Key=Purpose,Value=external-dns" "Key=Cluster,Value=homelab"
        
        log_success "User '$IAM_USER_NAME' created"
        USER_EXISTS=false
    fi
}

# Attach policy to user
attach_policy() {
    log_info "Attaching policy to user..."
    
    if aws iam list-attached-user-policies --user-name "$IAM_USER_NAME" | grep -q "$IAM_POLICY_NAME"; then
        log_success "Policy already attached to user"
    else
        aws iam attach-user-policy \
            --user-name "$IAM_USER_NAME" \
            --policy-arn "$POLICY_ARN"
        
        log_success "Policy attached to user"
    fi
}

# Create or rotate access keys
create_access_keys() {
    log_info "Checking existing access keys for user..."
    
    EXISTING_KEYS=$(aws iam list-access-keys --user-name "$IAM_USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text)
    
    if [ -n "$EXISTING_KEYS" ]; then
        log_warning "User has existing access keys"
        echo "$EXISTING_KEYS" | while read -r key_id; do
            echo "  - $key_id"
        done
        echo
        echo -n "Delete existing keys and create new ones? [y/N]: "
        read confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "$EXISTING_KEYS" | while read -r key_id; do
                log_info "Deleting access key: $key_id"
                aws iam delete-access-key --user-name "$IAM_USER_NAME" --access-key-id "$key_id"
            done
            log_success "Old access keys deleted"
        else
            log_info "Keeping existing keys - will not create new ones"
            return 1
        fi
    fi
    
    log_info "Creating new access key for user..."
    
    KEY_OUTPUT=$(aws iam create-access-key --user-name "$IAM_USER_NAME" --output json)
    
    AWS_ACCESS_KEY_ID=$(echo "$KEY_OUTPUT" | jq -r '.AccessKey.AccessKeyId')
    AWS_SECRET_ACCESS_KEY=$(echo "$KEY_OUTPUT" | jq -r '.AccessKey.SecretAccessKey')
    
    log_success "Access key created: $AWS_ACCESS_KEY_ID"
}

# Automated setup
automated_setup() {
    echo
    log_info "=== Automated AWS Setup ==="
    echo
    log_info "This will:"
    echo "  1. Create IAM policy for Route53 access"
    echo "  2. Create IAM user '$IAM_USER_NAME'"
    echo "  3. Attach policy to user"
    echo "  4. Generate access keys"
    echo "  5. Store credentials in 1Password"
    echo
    echo -n "Proceed with automated setup? [y/N]: "
    read confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Automated setup cancelled"
        return 1
    fi
    
    create_iam_policy
    create_iam_user
    attach_policy
    
    if ! create_access_keys; then
        log_warning "Access key creation skipped"
        return 1
    fi
    
    return 0
}

# Manual input
manual_input() {
    echo
    log_info "=== Manual Credential Entry ==="
    echo
    log_info "Please provide existing AWS credentials for external-dns:"
    echo
    
    # AWS Access Key ID
    prompt_for_input "AWS Access Key ID" AWS_ACCESS_KEY_ID "$CURRENT_ACCESS_KEY"
    if [ -z "$AWS_ACCESS_KEY_ID" ]; then
        log_error "AWS Access Key ID is required"
        exit 1
    fi
    
    # AWS Secret Access Key
    prompt_for_input "AWS Secret Access Key" AWS_SECRET_ACCESS_KEY "$CURRENT_SECRET_KEY" true
    if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        log_error "AWS Secret Access Key is required"
        exit 1
    fi
}

# Create or update the item
create_or_update_item() {
    echo
    log_info "Configuration summary:"
    echo "  Access Key ID: $AWS_ACCESS_KEY_ID"
    echo "  Secret Key: ****"
    echo
    
    echo -n "Proceed with $(if [ "$ITEM_EXISTS" = "true" ]; then echo "update"; else echo "creation"; fi)? [y/N]: "
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        exit 0
    fi
    
    if [ "$ITEM_EXISTS" = "true" ]; then
        log_info "Updating existing item..."
        
        op item edit "$ITEM_NAME" --vault="$VAULT_NAME" \
            "access_key_id[text]=$AWS_ACCESS_KEY_ID" \
            "secret_access_key[password]=$AWS_SECRET_ACCESS_KEY"
        
        log_success "Item '$ITEM_NAME' updated successfully"
    else
        log_info "Creating new item..."
        
        op item create --vault="$VAULT_NAME" \
            --category="$ITEM_CATEGORY" \
            --title="$ITEM_NAME" \
            "access_key_id[text]=$AWS_ACCESS_KEY_ID" \
            "secret_access_key[password]=$AWS_SECRET_ACCESS_KEY" \
            "notesPlain=AWS credentials for external-dns to manage Route53 DNS records automatically."
        
        log_success "Item '$ITEM_NAME' created successfully"
    fi
}

# Show IAM policy
show_iam_policy() {
    echo
    log_info "Required IAM Policy for external-dns:"
    echo
    cat << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
    echo
}

# Show next steps
show_next_steps() {
    echo
    log_success "AWS credentials are now configured in 1Password!"
    echo
    log_info "Next steps:"
    echo "1. Make sure your AWS IAM user has the Route53 policy shown above"
    echo "2. Commit and push your changes to trigger FluxCD deployment"
    echo "3. External Secrets Operator will automatically sync credentials"
    echo "4. external-dns will start managing DNS records for annotated Ingresses"
    echo
    log_info "To annotate an Ingress for DNS management:"
    echo "  metadata:"
    echo "    annotations:"
    echo "      external-dns.alpha.kubernetes.io/hostname: myapp.yourdomain.com"
    echo
    log_info "To monitor external-dns:"
    echo "  kubectl get externalsecrets -n external-dns"
    echo "  kubectl logs -n external-dns -l app=external-dns -f"
    echo
}

# Main execution
main() {
    echo "========================================="
    echo "  AWS External-DNS Credentials Setup"
    echo "========================================="
    echo
    
    check_op_cli
    check_vault
    check_jq
    check_aws_cli
    
    get_current_item
    
    echo
    echo "Setup options:"
    echo "  1. Automated setup (create IAM user and policy automatically)"
    echo "  2. Manual entry (enter existing credentials)"
    echo
    echo -n "Select option [1/2]: "
    read option
    
    case "$option" in
        1)
            if automated_setup; then
                create_or_update_item
                show_next_steps
            else
                log_error "Automated setup failed or was cancelled"
                exit 1
            fi
            ;;
        2)
            show_iam_policy
            manual_input
            create_or_update_item
            show_next_steps
            ;;
        *)
            log_error "Invalid option"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"

