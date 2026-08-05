#!/bin/bash
# Enhanced OCI Bastion Service Tunnel Setup for Multi-Subnet OKE Cluster Access
#
# This script provides menu-driven access with enhanced multi-subnet support:
# 1. SSH tunnel to specific OKE worker nodes (works with ANY subnet)
# 2. kubectl connectivity to the Kubernetes cluster
# 3. Both functions together
#
# Enhanced Architecture Features:
# - Dedicated bastion subnet with VCN routing to all worker subnets
# - Universal worker node connectivity (no subnet compatibility issues)
# - Supports worker nodes in multiple availability domains
# - Eliminates "VNIC not in bastion target subnet" errors

set -e

# Suppress OCI CLI warnings
export SUPPRESS_LABEL_WARNING=True

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
LOCAL_PORT="${LOCAL_PORT:-6443}"
SSH_PORT="${SSH_PORT:-2222}"
SESSION_DURATION="${SESSION_DURATION:-3600}"
DEBUG="${DEBUG:-1}"  # Enable debug by default

# Debug function
debug() {
    if [ "$DEBUG" = "1" ]; then
        echo -e "${CYAN}[DEBUG] $1${NC}"
    fi
}

echo -e "${BLUE}OCI Bastion Service Management for OKE${NC}"
echo "======================================"
echo ""
echo "Available Functions:"
echo "1. SSH access to OKE worker nodes (with node selection)"
echo "2. kubectl connectivity to Kubernetes cluster"
echo "3. Both SSH and kubectl access"
echo "4. Exit"
echo ""

# Change to Terraform root directory
cd "$ROOT_DIR"

# Function to ensure SSH config compatibility
ensure_ssh_config() {
    debug "Checking SSH client configuration..."
    
    SSH_CONFIG_FILE="$HOME/.ssh/config"
    
    # Create .ssh directory if it doesn't exist
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    
    # Check if SSH config has OCI Bastion compatibility settings
    if [ ! -f "$SSH_CONFIG_FILE" ] || ! grep -q "HostKeyAlgorithms.*ssh-rsa" "$SSH_CONFIG_FILE" 2>/dev/null; then
        debug "Adding OCI Bastion compatibility settings to SSH config"
        echo "" >> "$SSH_CONFIG_FILE"
        echo "# OCI Bastion Service compatibility settings" >> "$SSH_CONFIG_FILE"
        echo "Host *.oci.oraclecloud.com" >> "$SSH_CONFIG_FILE"
        echo "    HostKeyAlgorithms +ssh-rsa" >> "$SSH_CONFIG_FILE"
        echo "    PubkeyAcceptedKeyTypes +ssh-rsa" >> "$SSH_CONFIG_FILE"
        echo "    ServerAliveInterval 30" >> "$SSH_CONFIG_FILE"
        echo "    ServerAliveCountMax 5" >> "$SSH_CONFIG_FILE"
        echo "    TCPKeepAlive yes" >> "$SSH_CONFIG_FILE"
        echo "" >> "$SSH_CONFIG_FILE"
        
        chmod 600 "$SSH_CONFIG_FILE"
        echo -e "${GREEN}✓ Updated SSH config for OCI Bastion compatibility${NC}"
    else
        debug "SSH config already has compatibility settings"
    fi
}

# Function to extract configuration
extract_config() {
    debug "Extracting configuration from Terraform outputs..."
    
    BASTION_SERVICE_ID=$(terraform output -raw bastion_service_id 2>/dev/null || echo "")
    debug "Bastion Service ID: $BASTION_SERVICE_ID"
    
    if [ -z "$BASTION_SERVICE_ID" ] || [ "$BASTION_SERVICE_ID" = "null" ]; then
        echo -e "${RED}Error: No OCI Bastion Service found${NC}"
        echo "Make sure provision_bastion = true in terraform.tfvars and infrastructure is deployed"
        exit 1
    fi

    COMPARTMENT_ID=$(terraform output -raw compartment_ocid 2>/dev/null || echo "")
    debug "Compartment ID: $COMPARTMENT_ID"
    
    REGION=$(terraform output -raw region 2>/dev/null || echo "")
    debug "Region: $REGION"
    
    OCI_PROFILE=$(terraform output -raw oci_profile_used 2>/dev/null || echo "")
    debug "OCI Profile: $OCI_PROFILE"
    
    SSH_KEY_PATH=$(terraform output -raw ssh_public_key_path 2>/dev/null || echo "~/.oci/oci_api_key_public.pem")
    SSH_KEY_PATH=$(eval echo "$SSH_KEY_PATH")
    
    # Derive private key path using actual OCI naming convention
    if [[ "$SSH_KEY_PATH" == *"_public.pem" ]]; then
        # For oci_api_key_public.pem -> oci_api_key.pem
        PRIVATE_KEY_PATH="${SSH_KEY_PATH/_public.pem/.pem}"
    elif [[ "$SSH_KEY_PATH" == *".pub" ]]; then
        PRIVATE_KEY_PATH="${SSH_KEY_PATH%.pub}"
    else
        # Fallback: remove extension
        PRIVATE_KEY_PATH="${SSH_KEY_PATH%.*}"
    fi
    debug "SSH Public Key: $SSH_KEY_PATH"
    debug "SSH Private Key: $PRIVATE_KEY_PATH"
    
    CLUSTER_ID=$(terraform output -raw cluster_id 2>/dev/null || echo "")
    debug "Cluster ID: $CLUSTER_ID"

    # Collect node pool subnet IDs (used to pick the correct worker VNIC)
    NODE_POOL_SUBNETS_JSON=$(terraform output -json subnet_ids 2>/dev/null || echo "{}")
    # Flatten map values to a space-separated list
    NODE_POOL_SUBNET_IDS=$(echo "$NODE_POOL_SUBNETS_JSON" | jq -r 'to_entries | map(.value) | @sh' 2>/dev/null | tr -d "'")
    debug "Node pool subnet IDs: $NODE_POOL_SUBNET_IDS"

    # Verify SSH keys exist
    if [ ! -f "$SSH_KEY_PATH" ]; then
        echo -e "${RED}Error: SSH public key not found at: $SSH_KEY_PATH${NC}"
        exit 1
    fi
    if [ ! -f "$PRIVATE_KEY_PATH" ]; then
        echo -e "${RED}Error: SSH private key not found at: $PRIVATE_KEY_PATH${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Configuration loaded successfully:${NC}"
    echo "  Bastion Service ID: $BASTION_SERVICE_ID"
    echo "  Compartment ID: $COMPARTMENT_ID"
    echo "  Region: $REGION"
    echo "  OCI Profile: $OCI_PROFILE"
    echo "  SSH Key Path: $SSH_KEY_PATH"
    echo "  Cluster ID: $CLUSTER_ID"
}

# Function to list and select worker nodes
list_and_select_worker_node() {
    echo ""
    echo -e "${BLUE}Available OKE Worker Nodes:${NC}"
    echo "=========================="
    
    debug "Listing worker nodes in compartment: $COMPARTMENT_ID"
    
    # Get all OKE worker nodes with detailed info
    NODES_OUTPUT=$(oci compute instance list \
        --compartment-id "$COMPARTMENT_ID" \
        --lifecycle-state RUNNING \
        --query 'data[].{Name:"display-name",OCID:id,"Private-IP":"private-ip"}' \
        --output json \
        --profile "$OCI_PROFILE" 2>/dev/null)
    
    debug "Raw nodes output: $NODES_OUTPUT"
    
    # Filter for OKE nodes
    OKE_NODES=$(echo "$NODES_OUTPUT" | jq -r '[.[] | select(.Name | startswith("oke-"))]')
    debug "Filtered OKE nodes: $OKE_NODES"
    
    if [ "$OKE_NODES" = "[]" ] || [ -z "$OKE_NODES" ]; then
        echo -e "${RED}Error: No OKE worker nodes found${NC}"
        echo "Make sure your OKE cluster has worker nodes and they are in RUNNING state"
        return 1
    fi
    
    # Display nodes with numbers
    echo "$OKE_NODES" | jq -r 'to_entries[] | "\(.key + 1). \(.value.Name) (\(.value.OCID | split(".") | .[4]))"'
    echo ""
    
    # Get user selection
    NODE_COUNT=$(echo "$OKE_NODES" | jq length)
    while true; do
        read -p "Select worker node (1-$NODE_COUNT): " SELECTION
        if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "$NODE_COUNT" ]; then
            break
        fi
        echo -e "${RED}Invalid selection. Please enter a number between 1 and $NODE_COUNT.${NC}"
    done
    
    # Get selected node details
    SELECTED_NODE=$(echo "$OKE_NODES" | jq -r ".[$((SELECTION-1))]")
    NODE_OCID=$(echo "$SELECTED_NODE" | jq -r '.OCID')
    NODE_NAME=$(echo "$SELECTED_NODE" | jq -r '.Name')
    
    debug "Selected node OCID: $NODE_OCID"
    debug "Selected node name: $NODE_NAME"
    
    # Enhanced multi-subnet support - Get worker node private IP
    debug "Getting VNIC details for private IP..."
    VNIC_ATTACHMENTS=$(oci compute vnic-attachment list \
        --compartment-id "$COMPARTMENT_ID" \
        --instance-id "$NODE_OCID" \
        --profile "$OCI_PROFILE" 2>/dev/null)
    
    debug "VNIC attachments: $VNIC_ATTACHMENTS"
    
    # With enhanced architecture, pick the VNIC in a node pool subnet (not the pod subnet)
    VNIC_COUNT=$(echo "$VNIC_ATTACHMENTS" | jq '.data | length')
    debug "Found $VNIC_COUNT VNICs for this worker node"

    if [ "$VNIC_COUNT" -eq 0 ]; then
        echo -e "${RED}Error: No VNICs found for worker node${NC}"
        return 1
    fi

    # Prepare array of node pool subnet IDs
    read -r -a NODE_POOL_SUBNET_ID_ARR <<< "$NODE_POOL_SUBNET_IDS"

    CHOSEN_VNIC_ID=""
    CHOSEN_VNIC_SUBNET=""
    CHOSEN_NODE_IP=""

    for i in $(seq 0 $((VNIC_COUNT-1))); do
        CANDIDATE_VNIC_ID=$(echo "$VNIC_ATTACHMENTS" | jq -r ".data[$i].\"vnic-id\"")
        CANDIDATE_DETAILS=$(oci network vnic get --vnic-id "$CANDIDATE_VNIC_ID" --profile "$OCI_PROFILE" 2>/dev/null)
        CANDIDATE_SUBNET=$(echo "$CANDIDATE_DETAILS" | jq -r '.data."subnet-id"')
        CANDIDATE_IP=$(echo "$CANDIDATE_DETAILS" | jq -r '.data."private-ip"')

        # Prefer a VNIC whose subnet is in the node pool subnets
        if [ ${#NODE_POOL_SUBNET_ID_ARR[@]} -gt 0 ]; then
            for sid in "${NODE_POOL_SUBNET_ID_ARR[@]}"; do
                if [ "$CANDIDATE_SUBNET" = "$sid" ]; then
                    CHOSEN_VNIC_ID="$CANDIDATE_VNIC_ID"
                    CHOSEN_VNIC_SUBNET="$CANDIDATE_SUBNET"
                    CHOSEN_NODE_IP="$CANDIDATE_IP"
                    break 2
                fi
            done
        fi
    done

    # Fallback to the first VNIC if no match found
    if [ -z "$CHOSEN_VNIC_ID" ]; then
        CHOSEN_VNIC_ID=$(echo "$VNIC_ATTACHMENTS" | jq -r '.data[0]."vnic-id"')
        CANDIDATE_DETAILS=$(oci network vnic get --vnic-id "$CHOSEN_VNIC_ID" --profile "$OCI_PROFILE" 2>/dev/null)
        CHOSEN_VNIC_SUBNET=$(echo "$CANDIDATE_DETAILS" | jq -r '.data."subnet-id"')
        CHOSEN_NODE_IP=$(echo "$CANDIDATE_DETAILS" | jq -r '.data."private-ip"')
    fi

    VNIC_ID="$CHOSEN_VNIC_ID"
    VNIC_SUBNET="$CHOSEN_VNIC_SUBNET"
    NODE_IP="$CHOSEN_NODE_IP"

    debug "Selected VNIC: $VNIC_ID"
    debug "Selected VNIC subnet: $VNIC_SUBNET"
    debug "Selected node IP: $NODE_IP"
    
    if [ -z "$NODE_IP" ] || [ "$NODE_IP" = "null" ]; then
        echo -e "${RED}Error: Could not determine private IP for worker node${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Enhanced Architecture:${NC} Bastion can reach worker nodes in ANY subnet"
    echo -e "${GREEN}Worker Node Subnet:${NC} $VNIC_SUBNET"
    echo -e "${GREEN}Bastion Target Subnet:${NC} $BASTION_TARGET_SUBNET (dedicated bastion subnet)"
    echo -e "${GREEN}Connectivity Method:${NC} VCN routing enables cross-subnet access"
    
    debug "Selected IP: $NODE_IP"
    
    echo -e "${GREEN}Selected:${NC} $NODE_NAME"
    echo -e "${GREEN}Private IP:${NC} $NODE_IP"
    echo -e "${GREEN}OCID:${NC} $NODE_OCID"
}

# Function to test network connectivity to bastion
test_bastion_connectivity() {
    echo ""
    echo -e "${BLUE}Testing network connectivity to bastion endpoint...${NC}"
    
    BASTION_HOST="host.bastion.${REGION}.oci.oraclecloud.com"
    debug "Testing connectivity to $BASTION_HOST:22"
    
    # Test basic network connectivity
    set +e
    NC_TEST=$(timeout 10 nc -z "$BASTION_HOST" 22 2>&1)
    NC_RESULT=$?
    set -e
    
    if [ $NC_RESULT -eq 0 ]; then
        echo -e "${GREEN}✓ Network connectivity to bastion endpoint successful${NC}"
        debug "Network connectivity test passed"
    else
        echo -e "${YELLOW}⚠ Network connectivity test failed or timed out${NC}"
        debug "Network connectivity test result: $NC_RESULT"
        debug "Network connectivity test output: $NC_TEST"
        
        # Try alternative test with telnet
        set +e
        TELNET_TEST=$(timeout 5 bash -c "echo '' | telnet $BASTION_HOST 22" 2>&1)
        TELNET_RESULT=$?
        set -e
        
        if [ $TELNET_RESULT -eq 0 ] && echo "$TELNET_TEST" | grep -q "Connected"; then
            echo -e "${GREEN}✓ Alternative connectivity test successful${NC}"
        else
            echo -e "${YELLOW}⚠ Network connectivity issues detected${NC}"
            echo "This may indicate firewall or network restrictions"
            debug "Telnet test result: $TELNET_RESULT"
            debug "Telnet test output: $TELNET_TEST"
        fi
    fi
}


# Function to validate bastion service configuration
validate_bastion_service() {
    echo ""
    echo -e "${BLUE}Validating Enhanced OCI Bastion Service configuration...${NC}"
    
    # Check current public IP
    echo "Checking current public IP address..."
    CURRENT_IP=$(curl -s --connect-timeout 5 http://checkip.amazonaws.com/ || curl -s --connect-timeout 5 http://ipecho.net/plain || echo "unknown")
    debug "Current public IP: $CURRENT_IP"
    
    debug "Getting bastion service details: $BASTION_SERVICE_ID"
    
    set +e
    BASTION_DETAILS=$(oci bastion bastion get \
        --bastion-id "$BASTION_SERVICE_ID" \
        --profile "$OCI_PROFILE" \
        --output json 2>/dev/null)
    BASTION_RESULT=$?
    set -e
    
    if [ $BASTION_RESULT -ne 0 ]; then
        echo -e "${RED}Error: Cannot access bastion service${NC}"
        return 1
    fi
    
    BASTION_STATE=$(echo "$BASTION_DETAILS" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
    BASTION_NAME=$(echo "$BASTION_DETAILS" | jq -r '.data."name" // "unknown"')
    TARGET_SUBNET=$(echo "$BASTION_DETAILS" | jq -r '.data."target-subnet-id" // "unknown"')
    CLIENT_CIDRS=$(echo "$BASTION_DETAILS" | jq -r '.data."client-cidr-block-allow-list" // []')
    
    debug "Bastion state: $BASTION_STATE"
    debug "Bastion name: $BASTION_NAME"
    debug "Target subnet: $TARGET_SUBNET (dedicated bastion subnet)"
    debug "Client CIDR allow list: $CLIENT_CIDRS"
    
    echo "Enhanced Bastion Service Status:"
    echo "  Name: $BASTION_NAME"
    echo "  State: $BASTION_STATE"
    echo "  Architecture: Multi-Subnet Enhanced (dedicated bastion subnet)"
    echo "  Bastion Subnet: $TARGET_SUBNET"
    echo "  Client Allow List: $CLIENT_CIDRS"
    echo "  Your current IP: $CURRENT_IP"
    echo "  Connectivity: Can reach worker nodes in ANY subnet via VCN routing"
    
    # Check if current IP is in the allow list
    IP_IN_ALLOW_LIST=false
    if [ "$CURRENT_IP" != "unknown" ] && [ -n "$CLIENT_CIDRS" ]; then
        if echo "$CLIENT_CIDRS" | grep -q "$CURRENT_IP"; then
            echo -e "  ${GREEN}✓ Your IP is in the bastion allow list${NC}"
            IP_IN_ALLOW_LIST=true
        else
            echo -e "  ${YELLOW}⚠ Warning: Your current IP ($CURRENT_IP) is not in the bastion allow list${NC}"
            echo -e "  ${YELLOW}  This will cause connection failures.${NC}"
            echo ""
            echo -e "  ${YELLOW}Manual fix required:${NC}"
            echo "  1. Go to OCI Console → Bastion → $BASTION_NAME"
            echo "  2. Click 'Edit' and add ${CURRENT_IP}/32 to the CIDR allow list"
            echo "  3. Save the changes and re-run this script"
        fi
    fi
    
    if [ "$BASTION_STATE" != "ACTIVE" ]; then
        echo -e "${RED}Warning: Bastion service is not ACTIVE (state: $BASTION_STATE)${NC}"
        echo "The bastion service must be ACTIVE to create sessions"
        return 1
    fi
    
    # Store bastion target subnet for later use
    BASTION_TARGET_SUBNET="$TARGET_SUBNET"
    
    echo -e "${GREEN}✓ Bastion service validation completed${NC}"
}

# Function to create bastion session
create_bastion_session() {
    echo ""
    echo -e "${BLUE}Creating OCI Bastion Service session...${NC}"
    
    debug "Creating PORT_FORWARDING session to: $NODE_IP:22"
    debug "Bastion ID: $BASTION_SERVICE_ID"
    debug "SSH public key: $SSH_KEY_PATH"
    debug "Session TTL: $SESSION_DURATION"
    
    # Try to extract OpenSSH format key content from PEM file or find OpenSSH key
    SSH_KEY_CONTENT=""
    
    # First, try to find an OpenSSH format key (.pub file)
    if [[ "$SSH_KEY_PATH" == *".pem" ]]; then
        OPENSSH_KEY_PATH="${SSH_KEY_PATH%.pem}.pub"
        if [ -f "$OPENSSH_KEY_PATH" ]; then
            debug "Found OpenSSH format key: $OPENSSH_KEY_PATH"
            SSH_KEY_CONTENT=$(cat "$OPENSSH_KEY_PATH")
        else
            # Try converting PEM to OpenSSH format using the private key
            debug "Attempting to generate OpenSSH public key from private key..."
            if [ -f "$PRIVATE_KEY_PATH" ]; then
                SSH_KEY_CONTENT=$(ssh-keygen -y -f "$PRIVATE_KEY_PATH" 2>/dev/null || echo "")
            fi
            
            # If that fails, try converting the public key PEM
            if [ -z "$SSH_KEY_CONTENT" ]; then
                debug "Attempting to extract OpenSSH key content from PEM file..."
                SSH_KEY_CONTENT=$(ssh-keygen -f "$SSH_KEY_PATH" -i -m PKCS8 2>/dev/null || ssh-keygen -f "$SSH_KEY_PATH" -i -m PEM 2>/dev/null || echo "")
            fi
        fi
    else
        # Assume it's already in OpenSSH format
        SSH_KEY_CONTENT=$(cat "$SSH_KEY_PATH" 2>/dev/null || echo "")
    fi
    
    if [ -z "$SSH_KEY_CONTENT" ]; then
        echo -e "${RED}Error: Cannot extract OpenSSH format public key${NC}"
        echo "OCI Bastion Service requires an OpenSSH format public key (starting with ssh-rsa, ssh-ed25519, etc.)"
        echo "Please ensure you have a .pub file corresponding to your private key, or create one with:"
        echo "  ssh-keygen -y -f $PRIVATE_KEY_PATH > ${SSH_KEY_PATH%.pem}.pub"
        echo ""
        echo "Available key files:"
        ls -la ~/.oci/*.pem ~/.oci/*.pub ~/.ssh/id_* 2>/dev/null || echo "  No key files found in ~/.oci or ~/.ssh"
        return 1
    fi
    
    # Validate that we have a proper OpenSSH key format
    if ! echo "$SSH_KEY_CONTENT" | grep -qE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-)'; then
        echo -e "${RED}Error: Extracted key is not in valid OpenSSH format${NC}"
        echo "Key content preview: ${SSH_KEY_CONTENT:0:50}..."
        echo "Expected format: ssh-rsa AAAAB3... or ssh-ed25519 AAAAC3..."
        return 1
    fi
    
    debug "SSH key content: ${SSH_KEY_CONTENT:0:50}..."
    
    # Create session with detailed error handling using extracted key content
    set +e  # Disable exit on error to capture output
    
    # Create a temporary file with the OpenSSH key content
    TEMP_KEY_FILE=$(mktemp)
    echo "$SSH_KEY_CONTENT" > "$TEMP_KEY_FILE"
    
    SESSION_OUTPUT=$(oci bastion session create-port-forwarding \
        --bastion-id "$BASTION_SERVICE_ID" \
        --target-private-ip "$NODE_IP" \
        --target-port 22 \
        --ssh-public-key-file "$TEMP_KEY_FILE" \
        --session-ttl "$SESSION_DURATION" \
        --output json \
        --profile "$OCI_PROFILE" 2>&1)
    RESULT=$?
    
    # Clean up temporary file
    rm -f "$TEMP_KEY_FILE"
    
    set -e  # Re-enable exit on error
    
    debug "Session creation result code: $RESULT"
    debug "Session creation output: $SESSION_OUTPUT"
    
    if [ $RESULT -ne 0 ]; then
        echo -e "${RED}Error: Failed to create bastion session${NC}"
        echo "Error details: $SESSION_OUTPUT"
        return 1
    fi
    
    # Validate JSON output
    if ! echo "$SESSION_OUTPUT" | jq . >/dev/null 2>&1; then
        echo -e "${RED}Error: Invalid JSON response from OCI CLI${NC}"
        echo "Raw output: $SESSION_OUTPUT"
        return 1
    fi
    
    SESSION_ID=$(echo "$SESSION_OUTPUT" | jq -r '.data.id // empty')
    if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
        echo -e "${RED}Error: Could not extract session ID${NC}"
        echo "Session output: $SESSION_OUTPUT"
        return 1
    fi
    
    debug "Session ID created: $SESSION_ID"
    echo -e "${GREEN}✓ Bastion session created: $SESSION_ID${NC}"
    
    # Wait for session to become active with manual polling and detailed status
    echo "Waiting for session to become active..."
    debug "Waiting for session $SESSION_ID to become ACTIVE..."
    
    MAX_ATTEMPTS=24  # 4 minutes with 10-second intervals
    ATTEMPT=0
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        set +e
        SESSION_STATUS=$(oci bastion session get \
            --session-id "$SESSION_ID" \
            --profile "$OCI_PROFILE" \
            --output json 2>/dev/null)
        GET_RESULT=$?
        set -e
        
        if [ $GET_RESULT -eq 0 ]; then
            CURRENT_STATE=$(echo "$SESSION_STATUS" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
            LIFECYCLE_DETAILS=$(echo "$SESSION_STATUS" | jq -r '.data."lifecycle-details" // "none"')
            
            debug "Attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS - Session state: $CURRENT_STATE"
            debug "Lifecycle details: $LIFECYCLE_DETAILS"
            
            echo "Session status check $((ATTEMPT + 1))/$MAX_ATTEMPTS: $CURRENT_STATE"
            
            if [ "$CURRENT_STATE" = "ACTIVE" ]; then
                echo -e "${GREEN}✓ Session is now active${NC}"
                debug "Session $SESSION_ID is now ACTIVE"
                return 0
            elif [ "$CURRENT_STATE" = "FAILED" ]; then
                echo -e "${RED}Error: Session failed to activate${NC}"
                echo "Failure details: $LIFECYCLE_DETAILS"
                debug "Full session status: $SESSION_STATUS"
                return 1
            elif [ "$CURRENT_STATE" = "TERMINATED" ]; then
                echo -e "${RED}Error: Session was terminated${NC}"
                echo "Termination details: $LIFECYCLE_DETAILS"
                debug "Full session status: $SESSION_STATUS"
                return 1
            fi
        else
            debug "Failed to get session status, attempt $((ATTEMPT + 1))"
            echo "Unable to check session status (attempt $((ATTEMPT + 1)))"
        fi
        
        ATTEMPT=$((ATTEMPT + 1))
        sleep 10
    done
    
    echo -e "${RED}Error: Session did not become active within timeout (4 minutes)${NC}"
    
    # Get final session status for debugging
    set +e
    FINAL_STATUS=$(oci bastion session get --session-id "$SESSION_ID" --profile "$OCI_PROFILE" --output json 2>/dev/null)
    if [ $? -eq 0 ]; then
        FINAL_STATE=$(echo "$FINAL_STATUS" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
        FINAL_DETAILS=$(echo "$FINAL_STATUS" | jq -r '.data."lifecycle-details" // "none"')
        echo "Final session state: $FINAL_STATE"
        echo "Final details: $FINAL_DETAILS"
        debug "Full final session status: $FINAL_STATUS"
    fi
    set -e
    
    return 1
}

# Function to establish SSH tunnel with extensive debugging
establish_ssh_tunnel() {
    echo ""
    echo -e "${BLUE}Establishing SSH tunnel to worker node...${NC}"
    
    # Kill any existing tunnels on the SSH port
    debug "Killing any existing SSH tunnels on port $SSH_PORT..."
    pkill -f "ssh.*-L.*$SSH_PORT" 2>/dev/null || true
    sleep 2
    
    # Construct SSH command with enhanced options for OCI Bastion Service
    SSH_BASTION_HOST="host.bastion.${REGION}.oci.oraclecloud.com"
    SSH_CMD="ssh -i \"$PRIVATE_KEY_PATH\" -L \"127.0.0.1:${SSH_PORT}:${NODE_IP}:22\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15 -o ExitOnForwardFailure=yes -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o TCPKeepAlive=yes -o BatchMode=yes -o LogLevel=ERROR -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PreferredAuthentications=publickey -4 -N -p 22 \"${SESSION_ID}@${SSH_BASTION_HOST}\""
    
    debug "SSH tunnel command: $SSH_CMD"
    debug "Local port: $SSH_PORT"
    debug "Target: $NODE_IP:22"
    debug "Bastion host: $SSH_BASTION_HOST"
    
    # Start SSH tunnel in background
    echo "Starting SSH tunnel..."
    set +e
    eval "$SSH_CMD" &
    SSH_PID=$!
    set -e
    
    debug "SSH tunnel process started with PID: $SSH_PID"
    echo "SSH tunnel PID: $SSH_PID"
    
    # Wait for tunnel to establish with better monitoring
    echo "Waiting for tunnel to establish..."
    sleep 5
    
    # Give additional time if process is still starting up
    if kill -0 $SSH_PID 2>/dev/null; then
        debug "SSH process is running, waiting additional time for tunnel establishment..."
        sleep 10
    fi
    
    # Check if process is still running
    if ! kill -0 $SSH_PID 2>/dev/null; then
        echo -e "${RED}Error: SSH tunnel process died immediately${NC}"
        debug "SSH process $SSH_PID is no longer running"
        
        # Check if this is likely an IP restriction issue
        echo ""
        echo -e "${YELLOW}Common causes for connection failures:${NC}"
        echo "1. Your IP address may not be in the bastion's CIDR allow list"
        echo "2. Network connectivity issues between your location and OCI"
        echo "3. Firewall restrictions blocking SSH traffic"
        echo ""
        echo -e "${BLUE}Recommended fixes:${NC}"
        echo "1. Add your IP in OCI Console → Bastion → Edit"
        echo "2. Or use a VPN/network that's already in the allow list"
        echo ""
        
        # Try to get more details about why it failed
        echo "Debugging SSH connection..."
        debug "Testing direct SSH connection with verbose output..."
        
        set +e
        echo "Testing SSH connection with enhanced debugging..."
        echo "If the connection hangs at 'Entering interactive session', that's normal for port forwarding."
        echo "The tunnel is working if you see 'Local forwarding listening on 127.0.0.1 port $SSH_PORT'"
        
        # Test with timeout to prevent hanging
        timeout 30 ssh -i "$PRIVATE_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes \
            -o ConnectTimeout=15 \
            -o ExitOnForwardFailure=yes \
            -o HostKeyAlgorithms=+ssh-rsa \
            -o PubkeyAcceptedKeyTypes=+ssh-rsa \
            -o TCPKeepAlive=yes \
            -v \
            -p 22 \
            -N -L "127.0.0.1:${SSH_PORT}:${NODE_IP}:22" \
            "${SESSION_ID}@${SSH_BASTION_HOST}" || true
        set -e
        
        return 1
    fi
    
    # Test if tunnel is actually working with retries
    echo "Testing SSH tunnel connectivity..."
    debug "Testing connection to 127.0.0.1:$SSH_PORT"
    
    # Try multiple times as tunnel may take time to be ready
    for attempt in 1 2 3; do
        debug "Tunnel test attempt $attempt/3"
        set +e
        TEST_OUTPUT=$(timeout 20 ssh -i "$PRIVATE_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            -p $SSH_PORT opc@127.0.0.1 \
            "echo 'SSH tunnel test successful'" 2>&1)
        TEST_RESULT=$?
        set -e
        
        debug "SSH test attempt $attempt result: $TEST_RESULT"
        debug "SSH test attempt $attempt output: $TEST_OUTPUT"
        
        if [ $TEST_RESULT -eq 0 ]; then
            echo -e "${GREEN}✓ SSH tunnel established successfully${NC}"
            echo -e "${GREEN}  Access command: ssh -i $PRIVATE_KEY_PATH -p $SSH_PORT opc@127.0.0.1${NC}"
            return 0
        else
            if [ $attempt -lt 3 ]; then
                echo "Tunnel test attempt $attempt failed, retrying in 5 seconds..."
                sleep 5
            fi
        fi
    done
    
    echo -e "${YELLOW}Warning: SSH tunnel test failed after 3 attempts${NC}"
    echo "Last test output: $TEST_OUTPUT"
    echo -e "${YELLOW}Tunnel process is running, you may still be able to connect manually${NC}"
    echo -e "${GREEN}  Try: ssh -i $PRIVATE_KEY_PATH -p $SSH_PORT opc@127.0.0.1${NC}"
    return 0
}

# Function to setup kubectl connectivity
setup_kubectl_connectivity() {
    echo ""
    echo -e "${BLUE}Setting up kubectl connectivity to Kubernetes cluster...${NC}"
    
    # Get cluster endpoint details
    debug "Getting cluster endpoint details..."
    CLUSTER_DETAILS=$(terraform output -json cluster_endpoint_details 2>/dev/null || echo "{}")
    debug "Cluster details: $CLUSTER_DETAILS"
    
    KUBERNETES_ENDPOINT=$(echo "$CLUSTER_DETAILS" | jq -r '.kubernetes_endpoint // empty')
    debug "Kubernetes endpoint: $KUBERNETES_ENDPOINT"
    
    if [ -z "$KUBERNETES_ENDPOINT" ] || [ "$KUBERNETES_ENDPOINT" = "null" ]; then
        echo -e "${RED}Error: Could not get Kubernetes endpoint${NC}"
        return 1
    fi
    
    echo "Kubernetes endpoint: $KUBERNETES_ENDPOINT"
    
    # Extract host and port
    CLUSTER_HOST=$(echo "$KUBERNETES_ENDPOINT" | sed 's/https\?:\/\///' | sed 's/:.*//')
    CLUSTER_PORT=$(echo "$KUBERNETES_ENDPOINT" | sed 's/.*://')
    if [ "$CLUSTER_PORT" = "$CLUSTER_HOST" ]; then
        CLUSTER_PORT=6443
    fi
    
    debug "Cluster host: $CLUSTER_HOST"
    debug "Cluster port: $CLUSTER_PORT"
    
    # Test API access from worker node
    echo "Testing Kubernetes API access from worker node..."
    debug "Testing API endpoint: https://${CLUSTER_HOST}:${CLUSTER_PORT}/version"
    
    set +e
    K8S_TEST=$(ssh -i "$PRIVATE_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -p $SSH_PORT opc@127.0.0.1 \
        "curl -k --connect-timeout 5 https://${CLUSTER_HOST}:${CLUSTER_PORT}/version 2>/dev/null")
    K8S_RESULT=$?
    set -e
    
    debug "API test result: $K8S_RESULT"
    debug "API test output: $K8S_TEST"
    
    if [ $K8S_RESULT -eq 0 ] && [ -n "$K8S_TEST" ] && [ "$K8S_TEST" != "failed" ]; then
        echo -e "${GREEN}✓ Kubernetes API accessible from worker node${NC}"
        
        # Create tunnel to Kubernetes API
        echo "Creating tunnel to Kubernetes API..."
        debug "Creating kubectl tunnel: 127.0.0.1:$LOCAL_PORT -> $CLUSTER_HOST:$CLUSTER_PORT"
        
        set +e
        ssh -i "$PRIVATE_KEY_PATH" \
            -L "127.0.0.1:${LOCAL_PORT}:${CLUSTER_HOST}:${CLUSTER_PORT}" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -4 -f -N -p $SSH_PORT "opc@127.0.0.1" &
        KUBECTL_PID=$!
        set -e
        
        sleep 5
        debug "kubectl tunnel PID: $KUBECTL_PID"
        
        if kill -0 $KUBECTL_PID 2>/dev/null; then
            echo -e "${GREEN}✓ Kubernetes API tunnel established${NC}"
        else
            echo -e "${RED}Error: kubectl tunnel failed to start${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}Warning: Direct API access failed, using kubectl proxy...${NC}"
        
        # Start kubectl proxy on worker node
        debug "Starting kubectl proxy on worker node..."
        ssh -i "$PRIVATE_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -p $SSH_PORT opc@127.0.0.1 \
            "nohup kubectl proxy --port=8080 --address=0.0.0.0 >/dev/null 2>&1 &" 2>/dev/null
        sleep 3
        
        # Create tunnel to kubectl proxy
        debug "Creating tunnel to kubectl proxy: 127.0.0.1:$LOCAL_PORT -> 127.0.0.1:8080"
        set +e
        ssh -i "$PRIVATE_KEY_PATH" \
            -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:8080" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -4 -f -N -p $SSH_PORT "opc@127.0.0.1" &
        KUBECTL_PID=$!
        set -e
        
        sleep 3
        debug "kubectl proxy tunnel PID: $KUBECTL_PID"
        echo -e "${GREEN}✓ kubectl proxy tunnel established${NC}"
    fi
    
    # Configure kubectl
    echo ""
    echo "Configuring kubectl..."
    debug "Configuring kubectl for cluster: $CLUSTER_ID"
    
    set +e
    oci ce cluster create-kubeconfig \
        --cluster-id "$CLUSTER_ID" \
        --file "$HOME/.kube/config" \
        --region "$REGION" \
        --token-version 2.0.0 \
        --profile "$OCI_PROFILE" 2>/dev/null
    set -e
    
    # Configure to use tunnel
    CLUSTER_NAME="cluster-${CLUSTER_ID}"
    USER_NAME="user-$(echo "$CLUSTER_ID" | cut -d'.' -f5)"
    
    debug "Configuring cluster: $CLUSTER_NAME"
    debug "Configuring user: $USER_NAME"
    
    kubectl config set-cluster "$CLUSTER_NAME" \
        --server="https://127.0.0.1:$LOCAL_PORT" \
        --insecure-skip-tls-verify=true 2>/dev/null
    
    kubectl config set-credentials "$USER_NAME" \
        --exec-command=oci \
        --exec-arg=ce \
        --exec-arg=cluster \
        --exec-arg=generate-token \
        --exec-arg=--cluster-id \
        --exec-arg="$CLUSTER_ID" \
        --exec-arg=--region \
        --exec-arg="$REGION" \
        --exec-arg=--profile \
        --exec-arg="$OCI_PROFILE" \
        --exec-api-version=client.authentication.k8s.io/v1beta1 2>/dev/null
    
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
    if [ -n "$CURRENT_CONTEXT" ]; then
        kubectl config set-context "$CURRENT_CONTEXT" \
            --cluster="$CLUSTER_NAME" \
            --user="$USER_NAME" 2>/dev/null
    fi
    
    echo -e "${GREEN}✓ kubectl configured successfully${NC}"
    
    # Test kubectl connectivity
    echo "Testing kubectl connectivity..."
    set +e
    KUBECTL_TEST=$(kubectl get nodes --timeout=10s 2>&1)
    KUBECTL_RESULT=$?
    set -e
    
    debug "kubectl test result: $KUBECTL_RESULT"
    debug "kubectl test output: $KUBECTL_TEST"
    
    if [ $KUBECTL_RESULT -eq 0 ]; then
        echo -e "${GREEN}✓ kubectl connectivity test successful${NC}"
    else
        echo -e "${YELLOW}Warning: kubectl test failed, but configuration is complete${NC}"
        echo "Test output: $KUBECTL_TEST"
    fi
}

# Function to setup kubectl-only connectivity (automated via worker node)
setup_kubectl_only_connectivity() {
    echo ""
    echo -e "${BLUE}Setting up kubectl connectivity via worker node...${NC}"
    
    # Get cluster endpoint details
    debug "Getting cluster endpoint details..."
    CLUSTER_DETAILS=$(terraform output -json cluster_endpoint_details 2>/dev/null || echo "{}")
    debug "Cluster details: $CLUSTER_DETAILS"
    
    K8S_ENDPOINT=$(echo "$CLUSTER_DETAILS" | jq -r '.private_endpoint // .kubernetes_endpoint // empty')
    debug "Kubernetes endpoint: $K8S_ENDPOINT"
    
    if [ -z "$K8S_ENDPOINT" ] || [ "$K8S_ENDPOINT" = "null" ]; then
        echo -e "${RED}Error: Could not get Kubernetes endpoint${NC}"
        return 1
    fi
    
    # Extract host and port from endpoint  
    K8S_HOST=$(echo "$K8S_ENDPOINT" | sed 's/https\?:\/\///' | sed 's/:.*//')
    K8S_PORT=$(echo "$K8S_ENDPOINT" | sed 's/.*://')
    if [ "$K8S_PORT" = "$K8S_HOST" ]; then
        K8S_PORT=6443
    fi
    
    echo "Target Kubernetes API: $K8S_HOST:$K8S_PORT"
    debug "K8s API host: $K8S_HOST"
    debug "K8s API port: $K8S_PORT"
    
    # Auto-select first compatible worker node (no user interaction)
    echo "Auto-selecting worker node for kubectl tunnel..."
    
    # Use same worker discovery logic as option 1
    NODES_OUTPUT=$(oci compute instance list \
        --compartment-id "$COMPARTMENT_ID" \
        --lifecycle-state RUNNING \
        --query 'data[].{Name:"display-name",OCID:id,"Private-IP":"private-ip"}' \
        --output json \
        --profile "$OCI_PROFILE" 2>/dev/null)
    
    debug "Raw nodes output: $NODES_OUTPUT"
    
    # Filter for OKE nodes
    OKE_NODES=$(echo "$NODES_OUTPUT" | jq -r '[.[] | select(.Name | startswith("oke-"))]')
    debug "Filtered OKE nodes: $OKE_NODES"
    
    if [ "$OKE_NODES" = "[]" ] || [ -z "$OKE_NODES" ]; then
        echo -e "${RED}Error: No OKE worker nodes found${NC}"
        echo "Make sure your OKE cluster has worker nodes and they are in RUNNING state"
        return 1
    fi
    
    # Get first node and find compatible VNIC
    SELECTED_NODE=$(echo "$OKE_NODES" | jq -r '.[0]')
    NODE_OCID=$(echo "$SELECTED_NODE" | jq -r '.OCID')
    NODE_NAME=$(echo "$SELECTED_NODE" | jq -r '.Name')
    
    debug "Auto-selected node: $NODE_NAME ($NODE_OCID)"
    
    # Get compatible VNIC for the selected node
    echo "Finding compatible network interface..."
    VNIC_ATTACHMENTS=$(oci compute vnic-attachment list \
        --compartment-id "$COMPARTMENT_ID" \
        --instance-id "$NODE_OCID" \
        --profile "$OCI_PROFILE" 2>/dev/null)
    
    COMPATIBLE_VNIC=""
    VNIC_COUNT=$(echo "$VNIC_ATTACHMENTS" | jq '.data | length')
    
    # Reuse node pool subnet IDs to choose the correct VNIC
    read -r -a NODE_POOL_SUBNET_ID_ARR <<< "$NODE_POOL_SUBNET_IDS"
    for i in $(seq 0 $((VNIC_COUNT-1))); do
        VNIC_ID=$(echo "$VNIC_ATTACHMENTS" | jq -r ".data[$i].\"vnic-id\"")
        VNIC_DETAILS=$(oci network vnic get --vnic-id "$VNIC_ID" --profile "$OCI_PROFILE" 2>/dev/null)
        VNIC_SUBNET=$(echo "$VNIC_DETAILS" | jq -r '.data."subnet-id"')
        VNIC_IP=$(echo "$VNIC_DETAILS" | jq -r '.data."private-ip"')
        
        for sid in "${NODE_POOL_SUBNET_ID_ARR[@]}"; do
            if [ "$VNIC_SUBNET" = "$sid" ]; then
                COMPATIBLE_VNIC="$VNIC_ID"
                NODE_IP="$VNIC_IP"
                break 2
            fi
        done
    done
    
    if [ -z "$COMPATIBLE_VNIC" ]; then
        # Fallback to first VNIC
        VNIC_ID=$(echo "$VNIC_ATTACHMENTS" | jq -r '.data[0]."vnic-id"')
        VNIC_DETAILS=$(oci network vnic get --vnic-id "$VNIC_ID" --profile "$OCI_PROFILE" 2>/dev/null)
        NODE_IP=$(echo "$VNIC_DETAILS" | jq -r '.data."private-ip"')
        COMPATIBLE_VNIC="$VNIC_ID"
    fi
    
    echo "Using worker node: $NODE_NAME ($NODE_IP) as jump host"
    
    # Create bastion session to worker node
    echo "Creating bastion session to worker node..."
    SESSION_NAME="kubectl-session-$(date +%Y%m%d-%H%M%S)"
    
    # Use the same SSH key content extraction logic
    if [ -z "$SSH_KEY_CONTENT" ]; then
        if [[ "$SSH_KEY_PATH" == *".pem" ]]; then
            OPENSSH_KEY_PATH="${SSH_KEY_PATH%.pem}.pub"
            if [ -f "$OPENSSH_KEY_PATH" ]; then
                SSH_KEY_CONTENT=$(cat "$OPENSSH_KEY_PATH")
            else
                # Try converting PEM to OpenSSH format using the private key
                if [ -f "$PRIVATE_KEY_PATH" ]; then
                    SSH_KEY_CONTENT=$(ssh-keygen -y -f "$PRIVATE_KEY_PATH" 2>/dev/null || echo "")
                fi
                
                # If that fails, try converting the public key PEM
                if [ -z "$SSH_KEY_CONTENT" ]; then
                    SSH_KEY_CONTENT=$(ssh-keygen -f "$SSH_KEY_PATH" -i -m PKCS8 2>/dev/null || ssh-keygen -f "$SSH_KEY_PATH" -i -m PEM 2>/dev/null || echo "")
                fi
            fi
        else
            SSH_KEY_CONTENT=$(cat "$SSH_KEY_PATH" 2>/dev/null || echo "")
        fi
        
        if [ -z "$SSH_KEY_CONTENT" ]; then
            echo -e "${RED}Error: Cannot extract OpenSSH format public key${NC}"
            return 1
        fi
        
        # Validate that we have a proper OpenSSH key format
        if ! echo "$SSH_KEY_CONTENT" | grep -qE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-)'; then
            echo -e "${RED}Error: Extracted key is not in valid OpenSSH format${NC}"
            return 1
        fi
    fi

    set +e
    # Create a temporary file with the OpenSSH key content
    TEMP_KEY_FILE=$(mktemp)
    echo "$SSH_KEY_CONTENT" > "$TEMP_KEY_FILE"
    
    SESSION_OUTPUT=$(oci bastion session create-port-forwarding \
        --bastion-id "$BASTION_SERVICE_ID" \
        --target-private-ip "$NODE_IP" \
        --target-port 22 \
        --ssh-public-key-file "$TEMP_KEY_FILE" \
        --session-ttl 3600 \
        --display-name "$SESSION_NAME" \
        --output json \
        --profile "$OCI_PROFILE" 2>/dev/null)
    CREATE_RESULT=$?
    
    # Clean up temporary file
    rm -f "$TEMP_KEY_FILE"
    set -e
    
    if [ $CREATE_RESULT -ne 0 ] || [ -z "$SESSION_OUTPUT" ]; then
        echo -e "${RED}Error: Failed to create bastion session to worker node${NC}"
        return 1
    fi
    
    SESSION_ID=$(echo "$SESSION_OUTPUT" | jq -r '.data.id')
    echo "Bastion session ID: $SESSION_ID"
    
    # Wait for session to become active with manual polling and detailed status
    echo "Waiting for session to become active..."
    debug "Waiting for session $SESSION_ID to become ACTIVE..."
    
    MAX_ATTEMPTS=24  # 4 minutes with 10-second intervals
    ATTEMPT=0
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        set +e
        SESSION_STATUS=$(oci bastion session get \
            --session-id "$SESSION_ID" \
            --profile "$OCI_PROFILE" \
            --output json 2>/dev/null)
        GET_RESULT=$?
        set -e
        
        if [ $GET_RESULT -eq 0 ]; then
            CURRENT_STATE=$(echo "$SESSION_STATUS" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
            LIFECYCLE_DETAILS=$(echo "$SESSION_STATUS" | jq -r '.data."lifecycle-details" // "none"')
            
            debug "Attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS - Session state: $CURRENT_STATE"
            debug "Lifecycle details: $LIFECYCLE_DETAILS"
            
            echo "Session status check $((ATTEMPT + 1))/$MAX_ATTEMPTS: $CURRENT_STATE"
            
            if [ "$CURRENT_STATE" = "ACTIVE" ]; then
                echo -e "${GREEN}✓ Session is now active${NC}"
                debug "Session $SESSION_ID is now ACTIVE"
                break
            elif [ "$CURRENT_STATE" = "FAILED" ]; then
                echo -e "${RED}Error: Session failed to activate${NC}"
                echo "Failure details: $LIFECYCLE_DETAILS"
                debug "Full session status: $SESSION_STATUS"
                return 1
            elif [ "$CURRENT_STATE" = "TERMINATED" ]; then
                echo -e "${RED}Error: Session was terminated${NC}"
                echo "Termination details: $LIFECYCLE_DETAILS"
                debug "Full session status: $SESSION_STATUS"
                return 1
            fi
        else
            debug "Failed to get session status, attempt $((ATTEMPT + 1))"
            echo "Unable to check session status (attempt $((ATTEMPT + 1)))"
        fi
        
        ATTEMPT=$((ATTEMPT + 1))
        sleep 10
    done
    
    if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
        echo -e "${RED}Error: Session did not become active within timeout (4 minutes)${NC}"
        
        # Get final session status for debugging
        set +e
        FINAL_STATUS=$(oci bastion session get --session-id "$SESSION_ID" --profile "$OCI_PROFILE" --output json 2>/dev/null)
        if [ $? -eq 0 ]; then
            FINAL_STATE=$(echo "$FINAL_STATUS" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
            FINAL_DETAILS=$(echo "$FINAL_STATUS" | jq -r '.data."lifecycle-details" // "none"')
            echo "Final session state: $FINAL_STATE"
            echo "Final details: $FINAL_DETAILS"
            debug "Full final session status: $FINAL_STATUS"
        fi
        set -e
        
        return 1
    fi
    
    echo -e "${GREEN}✓ Bastion session to worker node is active${NC}"
    
    # Set up ports for kubectl tunnels (using same approach as working SSH function)
    SSH_PORT=2222    # Port for tunnel to worker node 
    LOCAL_PORT=6443  # Local port for kubectl to connect to
    
    # Step 1: Create PORT_FORWARDING tunnel to worker node (same as working SSH approach)
    echo "Creating tunnel to worker node..."
    SSH_BASTION_HOST="host.bastion.${REGION}.oci.oraclecloud.com"
    
    # Kill any existing tunnels
    debug "Killing any existing SSH tunnels on ports $SSH_PORT and $LOCAL_PORT..."
    pkill -f "ssh.*-L.*$SSH_PORT" 2>/dev/null || true
    pkill -f "ssh.*-L.*$LOCAL_PORT" 2>/dev/null || true
    sleep 2
    
    # Construct SSH command to worker node (same pattern as working SSH function)
    SSH_CMD="ssh -i \"$PRIVATE_KEY_PATH\" -L \"127.0.0.1:${SSH_PORT}:${NODE_IP}:22\" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -4 -N -p 22 \"${SESSION_ID}@${SSH_BASTION_HOST}\""
    
    debug "SSH tunnel to worker command: $SSH_CMD"
    debug "Local port: $SSH_PORT"
    debug "Target: $NODE_IP:22"
    debug "Bastion host: $SSH_BASTION_HOST"
    
    # Start SSH tunnel to worker node in background
    echo "Starting tunnel to worker node..."
    set +e
    eval "$SSH_CMD" &
    SSH_PID=$!
    set -e
    
    debug "SSH tunnel to worker process started with PID: $SSH_PID"
    
    # Wait for tunnel to worker to establish
    echo "Waiting for tunnel to worker to establish..."
    sleep 8
    
    # Check if process is still running
    if ! kill -0 $SSH_PID 2>/dev/null; then
        echo -e "${RED}Error: SSH tunnel to worker process died immediately${NC}"
        debug "SSH process $SSH_PID is no longer running"
        return 1
    fi
    
    # Test if tunnel to worker is actually working
    echo "Testing tunnel to worker node..."
    debug "Testing connection to 127.0.0.1:$SSH_PORT"
    
    set +e
    TEST_OUTPUT=$(ssh -i "$PRIVATE_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -p $SSH_PORT opc@127.0.0.1 \
        "echo 'Worker tunnel test successful'" 2>&1)
    TEST_RESULT=$?
    set -e
    
    debug "Worker tunnel test result: $TEST_RESULT"
    debug "Worker tunnel test output: $TEST_OUTPUT"
    
    if [ $TEST_RESULT -ne 0 ]; then
        echo -e "${RED}Error: Tunnel to worker node test failed${NC}"
        echo "Test output: $TEST_OUTPUT"
        return 1
    fi
    
    echo -e "${GREEN}✓ Tunnel to worker node established${NC}"
    
    # Step 2: Create tunnel through worker node to Kubernetes API
    echo "Creating tunnel to Kubernetes API through worker node..."
    debug "Creating kubectl tunnel: 127.0.0.1:$LOCAL_PORT -> $K8S_HOST:$K8S_PORT via worker"
    
    KUBECTL_SSH_CMD="ssh -i \"$PRIVATE_KEY_PATH\" -L \"127.0.0.1:${LOCAL_PORT}:${K8S_HOST}:${K8S_PORT}\" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -4 -N -p $SSH_PORT opc@127.0.0.1"
    
    debug "kubectl SSH tunnel command: $KUBECTL_SSH_CMD"
    
    set +e
    eval "$KUBECTL_SSH_CMD" &
    KUBECTL_SSH_PID=$!
    set -e
    
    debug "kubectl SSH tunnel PID: $KUBECTL_SSH_PID"
    sleep 5
    
    if ! kill -0 $KUBECTL_SSH_PID 2>/dev/null; then
        echo -e "${RED}Error: kubectl SSH tunnel failed${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ kubectl tunnel established (127.0.0.1:$LOCAL_PORT -> $K8S_HOST:$K8S_PORT)${NC}"
    
    # Configure kubectl
    echo "Configuring kubectl..."
    
    set +e
    oci ce cluster create-kubeconfig \
        --cluster-id "$CLUSTER_ID" \
        --file "$HOME/.kube/config" \
        --region "$REGION" \
        --token-version 2.0.0 \
        --profile "$OCI_PROFILE" 2>/dev/null
    set -e
    
    # Configure to use tunnel
    CLUSTER_NAME="cluster-${CLUSTER_ID}"
    USER_NAME="user-$(echo "$CLUSTER_ID" | cut -d'.' -f5)"
    
    kubectl config set-cluster "$CLUSTER_NAME" \
        --server="https://127.0.0.1:$LOCAL_PORT" \
        --insecure-skip-tls-verify=true 2>/dev/null
    
    kubectl config set-credentials "$USER_NAME" \
        --exec-command=oci \
        --exec-arg=ce \
        --exec-arg=cluster \
        --exec-arg=generate-token \
        --exec-arg=--cluster-id \
        --exec-arg="$CLUSTER_ID" \
        --exec-arg=--region \
        --exec-arg="$REGION" \
        --exec-arg=--profile \
        --exec-arg="$OCI_PROFILE" \
        --exec-api-version=client.authentication.k8s.io/v1beta1 2>/dev/null
    
    kubectl config set-context "$(kubectl config current-context)" \
        --cluster="$CLUSTER_NAME" \
        --user="$USER_NAME" 2>/dev/null
    
    echo -e "${GREEN}✓ kubectl configured for tunnel access${NC}"
    
    # Test kubectl connectivity
    echo "Testing kubectl connectivity..."
    set +e
    kubectl get nodes >/dev/null 2>&1
    TEST_RESULT=$?
    set -e
    
    if [ $TEST_RESULT -eq 0 ]; then
        echo -e "${GREEN}✓ kubectl connectivity test successful${NC}"
        return 0
    else
        echo -e "${RED}✗ kubectl connectivity test failed${NC}"
        return 1
    fi
}

# Function to setup direct kubectl connectivity (bastion -> k8s API endpoint)
setup_kubectl_direct_connectivity() {
    echo ""
    echo -e "${BLUE}Setting up direct kubectl connectivity to Kubernetes API...${NC}"
    
    # Get cluster endpoint details
    debug "Getting cluster endpoint details..."
    CLUSTER_DETAILS=$(terraform output -json cluster_endpoint_details 2>/dev/null || echo "{}")
    debug "Cluster details: $CLUSTER_DETAILS"
    
    K8S_ENDPOINT=$(echo "$CLUSTER_DETAILS" | jq -r '.private_endpoint // .kubernetes_endpoint // empty')
    debug "Kubernetes endpoint: $K8S_ENDPOINT"
    
    if [ -z "$K8S_ENDPOINT" ] || [ "$K8S_ENDPOINT" = "null" ]; then
        echo -e "${RED}Error: Could not get Kubernetes endpoint${NC}"
        return 1
    fi
    
    echo "Target Kubernetes API: $K8S_ENDPOINT"
    
    # Parse endpoint
    K8S_HOST=$(echo "$K8S_ENDPOINT" | cut -d':' -f1)
    K8S_PORT=$(echo "$K8S_ENDPOINT" | cut -d':' -f2)
    
    debug "K8s API host: $K8S_HOST"
    debug "K8s API port: $K8S_PORT"
    
    # Set up local port for direct kubectl tunnel
    LOCAL_PORT=6443
    
    echo "Creating direct bastion session to Kubernetes API endpoint..."
    SESSION_NAME="kubectl-direct-$(date +%Y%m%d-%H%M%S)"
    
    # Use the same SSH key content extraction logic
    if [ -z "$SSH_KEY_CONTENT" ]; then
        if [[ "$SSH_KEY_PATH" == *".pem" ]]; then
            OPENSSH_KEY_PATH="${SSH_KEY_PATH%.pem}.pub"
            if [ -f "$OPENSSH_KEY_PATH" ]; then
                SSH_KEY_CONTENT=$(cat "$OPENSSH_KEY_PATH")
            else
                # Try converting PEM to OpenSSH format using the private key
                if [ -f "$PRIVATE_KEY_PATH" ]; then
                    SSH_KEY_CONTENT=$(ssh-keygen -y -f "$PRIVATE_KEY_PATH" 2>/dev/null || echo "")
                fi
                
                # If that fails, try converting the public key PEM
                if [ -z "$SSH_KEY_CONTENT" ]; then
                    SSH_KEY_CONTENT=$(ssh-keygen -f "$SSH_KEY_PATH" -i -m PKCS8 2>/dev/null || ssh-keygen -f "$SSH_KEY_PATH" -i -m PEM 2>/dev/null || echo "")
                fi
            fi
        else
            SSH_KEY_CONTENT=$(cat "$SSH_KEY_PATH" 2>/dev/null || echo "")
        fi
        
        if [ -z "$SSH_KEY_CONTENT" ]; then
            echo -e "${RED}Error: Cannot extract OpenSSH format public key${NC}"
            return 1
        fi
        
        # Validate that we have a proper OpenSSH key format
        if ! echo "$SSH_KEY_CONTENT" | grep -qE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-)'; then
            echo -e "${RED}Error: Extracted key is not in valid OpenSSH format${NC}"
            return 1
        fi
    fi

    # Create PORT_FORWARDING session directly to Kubernetes API endpoint
    set +e
    # Create a temporary file with the OpenSSH key content
    TEMP_KEY_FILE=$(mktemp)
    echo "$SSH_KEY_CONTENT" > "$TEMP_KEY_FILE"
    
    SESSION_OUTPUT=$(oci bastion session create-port-forwarding \
        --bastion-id "$BASTION_SERVICE_ID" \
        --target-private-ip "$K8S_HOST" \
        --target-port "$K8S_PORT" \
        --ssh-public-key-file "$TEMP_KEY_FILE" \
        --session-ttl 3600 \
        --display-name "$SESSION_NAME" \
        --output json \
        --profile "$OCI_PROFILE" 2>/dev/null)
    CREATE_RESULT=$?
    
    # Clean up temporary file
    rm -f "$TEMP_KEY_FILE"
    set -e
    
    if [ $CREATE_RESULT -ne 0 ] || [ -z "$SESSION_OUTPUT" ]; then
        echo -e "${RED}Error: Failed to create bastion session to Kubernetes API endpoint${NC}"
        echo "This might mean:"
        echo "  - Security rules don't allow bastion → K8s API access"
        echo "  - Network connectivity issue between subnets"
        echo "  - Bastion target subnet cannot reach K8s API subnet"
        return 1
    fi
    
    SESSION_ID=$(echo "$SESSION_OUTPUT" | jq -r '.data.id')
    echo "Bastion session ID: $SESSION_ID"
    
    # Wait for session to become active with manual polling (same approach as working functions)
    echo "Waiting for session to become active..."
    debug "Waiting for session $SESSION_ID to become ACTIVE..."
    
    MAX_ATTEMPTS=24  # 4 minutes with 10-second intervals
    ATTEMPT=0
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        set +e
        SESSION_STATUS=$(oci bastion session get \
            --session-id "$SESSION_ID" \
            --profile "$OCI_PROFILE" \
            --output json 2>/dev/null)
        GET_RESULT=$?
        set -e
        
        if [ $GET_RESULT -eq 0 ]; then
            CURRENT_STATE=$(echo "$SESSION_STATUS" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
            LIFECYCLE_DETAILS=$(echo "$SESSION_STATUS" | jq -r '.data."lifecycle-details" // "none"')
            
            debug "Attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS - Session state: $CURRENT_STATE"
            debug "Lifecycle details: $LIFECYCLE_DETAILS"
            
            echo "Session status check $((ATTEMPT + 1))/$MAX_ATTEMPTS: $CURRENT_STATE"
            
            if [ "$CURRENT_STATE" = "ACTIVE" ]; then
                echo -e "${GREEN}✓ Session is now active${NC}"
                debug "Session $SESSION_ID is now ACTIVE"
                break
            elif [ "$CURRENT_STATE" = "FAILED" ]; then
                echo -e "${RED}Error: Session failed to activate${NC}"
                echo "Failure details: $LIFECYCLE_DETAILS"
                debug "Full session status: $SESSION_STATUS"
                return 1
            elif [ "$CURRENT_STATE" = "TERMINATED" ]; then
                echo -e "${RED}Error: Session was terminated${NC}"
                echo "Termination details: $LIFECYCLE_DETAILS"
                debug "Full session status: $SESSION_STATUS"
                return 1
            fi
        else
            debug "Failed to get session status, attempt $((ATTEMPT + 1))"
            echo "Unable to check session status (attempt $((ATTEMPT + 1)))"
        fi
        
        ATTEMPT=$((ATTEMPT + 1))
        sleep 10
    done
    
    if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
        echo -e "${RED}Error: Session did not become active within timeout (4 minutes)${NC}"
        
        # Get final session status for debugging
        set +e
        FINAL_STATUS=$(oci bastion session get --session-id "$SESSION_ID" --profile "$OCI_PROFILE" --output json 2>/dev/null)
        if [ $? -eq 0 ]; then
            FINAL_STATE=$(echo "$FINAL_STATUS" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
            FINAL_DETAILS=$(echo "$FINAL_STATUS" | jq -r '.data."lifecycle-details" // "none"')
            echo "Final session state: $FINAL_STATE"
            echo "Final details: $FINAL_DETAILS"
            debug "Full final session status: $FINAL_STATUS"
        fi
        set -e
        
        return 1
    fi
    
    echo -e "${GREEN}✓ Direct bastion session to Kubernetes API is active${NC}"
    
    # Create direct SSH tunnel to Kubernetes API using bastion-provided template
    echo "Creating direct tunnel to Kubernetes API..."
    SSH_BASTION_HOST="host.bastion.${REGION}.oci.oraclecloud.com"
    
    # Kill any existing tunnels
    debug "Killing any existing SSH tunnels on port $LOCAL_PORT..."
    pkill -f "ssh.*-L.*$LOCAL_PORT" 2>/dev/null || true
    sleep 2

    # Retrieve SSH command template from bastion session
    debug "Retrieving SSH command template for direct kubectl session..."
    set +e
    SSH_COMMAND_TEMPLATE=$(oci bastion session get --session-id "$SESSION_ID" --query 'data."ssh-metadata".command' --raw-output --profile "$OCI_PROFILE" 2>&1)
    GET_CMD_RESULT=$?
    set -e
    
    if [ $GET_CMD_RESULT -ne 0 ] || [ -z "$SSH_COMMAND_TEMPLATE" ] || [[ "$SSH_COMMAND_TEMPLATE" == *"ERROR"* ]] || [[ "$SSH_COMMAND_TEMPLATE" == *"null"* ]]; then
        echo -e "${RED}Error: Could not get SSH command for direct kubectl session${NC}"
        debug "Response: $SSH_COMMAND_TEMPLATE"
        return 1
    fi
    
    debug "Direct SSH Command Template: $SSH_COMMAND_TEMPLATE"

    # Replace placeholders and harden options
    KUBECTL_SSH_CMD=$(echo "$SSH_COMMAND_TEMPLATE" | \
        sed "s|<privateKey>|$PRIVATE_KEY_PATH|g" | \
        sed "s|<localPort>|$LOCAL_PORT|g")
    # Inject reliable options (identities only, disable agent, ed25519, known_hosts)
    KUBECTL_SSH_CMD=$(echo "$KUBECTL_SSH_CMD" | sed 's|-p |-o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAcceptedKeyTypes=+ssh-ed25519 -o HostKeyAlgorithms=+ssh-ed25519 -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=15 -o ExitOnForwardFailure=yes -p |')
    # Flatten template to a single line
    KUBECTL_SSH_CMD=$(printf '%s' "$KUBECTL_SSH_CMD" | tr '\r\n' ' ')

    debug "Direct kubectl SSH tunnel command: $KUBECTL_SSH_CMD"
    
    # Start direct SSH tunnel in background (via shell to preserve args)
    set +e
    # Create log directory if it doesn't exist
    mkdir -p /tmp/terraform-bastion-logs
    nohup bash -lc "$KUBECTL_SSH_CMD" >/tmp/terraform-bastion-logs/kubectl-tunnel.log 2>&1 &
    KUBECTL_SSH_PID=$!
    set -e
    
    debug "Direct kubectl SSH tunnel PID: $KUBECTL_SSH_PID"
    sleep 8
    
    # Check if tunnel process is still running
    if ! kill -0 $KUBECTL_SSH_PID 2>/dev/null; then
        echo -e "${RED}Error: Direct kubectl SSH tunnel failed${NC}"
        echo "This might indicate network connectivity issues between:"
        echo "  - Bastion service and Kubernetes API endpoint"
        echo "  - Security rules blocking TCP/$K8S_PORT traffic"
        return 1
    fi
    
    echo -e "${GREEN}✓ Direct kubectl tunnel established (127.0.0.1:$LOCAL_PORT -> $K8S_HOST:$K8S_PORT)${NC}"
    
    # Configure kubectl for direct access
    echo "Configuring kubectl for direct tunnel access..."
    
    set +e
    oci ce cluster create-kubeconfig \
        --cluster-id "$CLUSTER_ID" \
        --file "$HOME/.kube/config" \
        --region "$REGION" \
        --token-version 2.0.0 \
        --profile "$OCI_PROFILE" 2>/dev/null
    set -e
    
    # Configure to use direct tunnel
    CLUSTER_NAME="cluster-${CLUSTER_ID}"
    USER_NAME="user-$(echo "$CLUSTER_ID" | cut -d'.' -f5)"
    
    kubectl config set-cluster "$CLUSTER_NAME" \
        --server="https://127.0.0.1:$LOCAL_PORT" \
        --insecure-skip-tls-verify=true 2>/dev/null
    
    kubectl config set-credentials "$USER_NAME" \
        --exec-command=oci \
        --exec-arg=ce \
        --exec-arg=cluster \
        --exec-arg=generate-token \
        --exec-arg=--cluster-id \
        --exec-arg="$CLUSTER_ID" \
        --exec-arg=--region \
        --exec-arg="$REGION" \
        --exec-arg=--profile \
        --exec-arg="$OCI_PROFILE" \
        --exec-api-version=client.authentication.k8s.io/v1beta1 2>/dev/null
    
    kubectl config set-context "$(kubectl config current-context)" \
        --cluster="$CLUSTER_NAME" \
        --user="$USER_NAME" 2>/dev/null
    
    echo -e "${GREEN}✓ kubectl configured for direct tunnel access${NC}"
    
    # Test kubectl connectivity
    echo "Testing direct kubectl connectivity..."
    set +e
    kubectl get nodes >/dev/null 2>&1
    TEST_RESULT=$?
    set -e
    
    if [ $TEST_RESULT -eq 0 ]; then
        echo -e "${GREEN}✓ Direct kubectl connectivity test successful${NC}"
        return 0
    else
        echo -e "${RED}✗ Direct kubectl connectivity test failed${NC}"
        return 1
    fi
}

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Received exit signal, cleaning up...${NC}"
    
    debug "Killing SSH tunnels..."
    pkill -f "ssh.*-L.*$LOCAL_PORT" 2>/dev/null || true
    pkill -f "ssh.*-L.*$SSH_PORT" 2>/dev/null || true
    pkill -f "ssh.*-L.*6443" 2>/dev/null || true  # kubectl API tunnel
    
    # Clean up both sessions (SSH and kubectl) if they exist
    if [ -n "$SESSION_ID" ]; then
        debug "Deleting bastion session: $SESSION_ID"
        echo "Deleting bastion session: $SESSION_ID"
        oci bastion session delete --session-id "$SESSION_ID" --profile "$OCI_PROFILE" >/dev/null 2>&1 || true
    fi
    
    if [ -n "$SSH_SESSION_ID" ]; then
        debug "Deleting SSH bastion session: $SSH_SESSION_ID"
        echo "Deleting SSH bastion session: $SSH_SESSION_ID"
        oci bastion session delete --session-id "$SSH_SESSION_ID" --profile "$OCI_PROFILE" >/dev/null 2>&1 || true
    fi
    
    echo -e "${GREEN}Cleanup completed. Goodbye!${NC}"
    exit 0
}

trap cleanup EXIT INT TERM

# Main menu function
main_menu() {
    while true; do
        read -p "Select an option (1-4): " CHOICE
        
        case $CHOICE in
            1)
                echo ""
                echo -e "${BLUE}=== SSH ACCESS TO OKE WORKER NODES ===${NC}"
                ensure_ssh_config
                extract_config
                validate_bastion_service
                test_bastion_connectivity
                list_and_select_worker_node
                create_bastion_session
                establish_ssh_tunnel
                
                echo ""
                echo -e "${GREEN}🚀 SSH Access Ready!${NC}"
                echo -e "${GREEN}  Command: ssh -i $PRIVATE_KEY_PATH -p $SSH_PORT opc@127.0.0.1${NC}"
                echo ""
                echo "Press Ctrl+C to stop and cleanup..."
                
                # Keep running until interrupted (check every 5 seconds for responsiveness)
                while true; do
                    if ! pgrep -f "ssh.*-L.*$SSH_PORT" > /dev/null; then
                        echo -e "${RED}SSH tunnel died, exiting...${NC}"
                        exit 1
                    fi
                    sleep 5
                done
                ;;
            2)
                echo ""
                echo -e "${BLUE}=== KUBECTL CONNECTIVITY ===${NC}"
                ensure_ssh_config
                extract_config
                validate_bastion_service
                setup_kubectl_direct_connectivity
                
                echo ""
                echo -e "${GREEN}🚀 kubectl Access Ready!${NC}"
                echo -e "${GREEN}  Test: kubectl get nodes${NC}"
                echo -e "${GREEN}  Test: kubectl get pods --all-namespaces${NC}"
                echo -e "${GREEN}  Local K8s API: https://127.0.0.1:6443${NC}"
                echo -e "${GREEN}  Connection: laptop → bastion → k8s API (direct)${NC}"
                echo ""
                echo "Press Ctrl+C to stop and cleanup..."
                
                # Keep running until interrupted (check every 5 seconds for responsiveness)
                while true; do
                    if ! pgrep -f "ssh.*-L.*6443" > /dev/null; then
                        echo -e "${RED}kubectl tunnel died, exiting...${NC}"
                        exit 1
                    fi
                    sleep 5
                done
                ;;
            3)
                echo ""
                echo -e "${BLUE}=== FULL ACCESS (SSH + kubectl) ===${NC}"
                ensure_ssh_config
                extract_config
                validate_bastion_service
                
                # Set up SSH access to worker node
                echo -e "${BLUE}Setting up SSH access to worker node...${NC}"
                list_and_select_worker_node
                create_bastion_session
                establish_ssh_tunnel
                
                # Store SSH session details for display
                SSH_SESSION_ID="$SESSION_ID"
                SSH_NODE_IP="$NODE_IP"
                
                # Set up direct kubectl connectivity (separate session)
                echo ""
                echo -e "${BLUE}Setting up direct kubectl connectivity...${NC}"
                setup_kubectl_direct_connectivity
                
                echo ""
                echo -e "${GREEN}🚀 Full Access Ready!${NC}"
                echo "=================="
                echo ""
                echo -e "${BLUE}SSH Access:${NC}"
                echo -e "${GREEN}  Command: ssh -i $PRIVATE_KEY_PATH -p $SSH_PORT opc@127.0.0.1${NC}"
                echo ""
                echo -e "${BLUE}kubectl Access:${NC}"
                echo -e "${GREEN}  Test: kubectl get nodes${NC}"
                echo -e "${GREEN}  Test: kubectl get pods --all-namespaces${NC}"
                echo -e "${GREEN}  Local K8s API: https://127.0.0.1:6443${NC}"
                echo ""
                echo -e "${BLUE}Connection Details:${NC}"
                echo "  SSH Session ID: $SSH_SESSION_ID"
                echo "  kubectl Session ID: $SESSION_ID"
                echo "  SSH: laptop → bastion → worker node (127.0.0.1:$SSH_PORT)"
                echo "  kubectl: laptop → bastion → k8s API (127.0.0.1:6443)"
                echo ""
                echo "Press Ctrl+C to stop and cleanup..."
                
                # Keep running until interrupted (check every 5 seconds for responsiveness)
                while true; do
                    # Check SSH tunnel
                    if ! pgrep -f "ssh.*-L.*$SSH_PORT" > /dev/null; then
                        echo -e "${RED}SSH tunnel died, exiting...${NC}"
                        exit 1
                    fi
                    # Check kubectl tunnel
                    if ! pgrep -f "ssh.*-L.*6443" > /dev/null; then
                        echo -e "${RED}kubectl tunnel died, exiting...${NC}"
                        exit 1
                    fi
                    sleep 5
                done
                ;;
            4)
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please select 1-4.${NC}"
                ;;
        esac
    done
}

# Start main menu
main_menu
