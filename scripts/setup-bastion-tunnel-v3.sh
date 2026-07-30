#!/bin/bash
# OCI Bastion Service Tunnel Manager (v3)
#
# IMPROVEMENTS OVER v2:
# - Validates workspace consistency (bastion and K8s endpoint must be from same workspace)
# - Auto-detects current workspace and warns if mismatch with --workspace flag
# - Pre-flight validation of all configuration before attempting tunnel
# - Better error messages with actionable guidance
# - Automatic cleanup of stale bastion sessions on startup
# - Always deletes session on exit (Ctrl+C or script completion)
# - Validates network reachability before creating sessions
# - Cleaner logging with timestamps and levels
# - Graceful cleanup of stale sessions
# - Support for both primary and secondary clusters with clear naming
#
# Usage examples:
#   ./scripts/setup-bastion-tunnel-v3.sh --workspace primary kubectl
#   ./scripts/setup-bastion-tunnel-v3.sh --workspace secondary kubectl
#   LOCAL_PORT=16443 ./scripts/setup-bastion-tunnel-v3.sh --workspace primary kubectl
#   LOCAL_PORT=16444 ./scripts/setup-bastion-tunnel-v3.sh --workspace secondary kubectl

set -e

export SUPPRESS_LABEL_WARNING=True

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_VERSION="3.4.2"

# Lock directory for Terraform workspace operations
LOCK_DIR="${LOCK_DIR:-/tmp/bastion-tunnel-locks}"
mkdir -p "$LOCK_DIR"
TF_LOCK_FILE="$LOCK_DIR/terraform-workspace.lock"
TF_LOCK_TIMEOUT="${TF_LOCK_TIMEOUT:-120}"  # Max seconds to wait for lock

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration with sensible defaults
LOCAL_PORT="${LOCAL_PORT:-6443}"
SSH_PORT="${SSH_PORT:-2222}"
SESSION_DURATION="${SESSION_DURATION:-3600}"
REFRESH_MARGIN="${REFRESH_MARGIN:-300}"
WATCH_INTERVAL="${WATCH_INTERVAL:-30}"
INITIAL_RETRY_ATTEMPTS="${INITIAL_RETRY_ATTEMPTS:-3}"
INITIAL_RETRY_DELAY="${INITIAL_RETRY_DELAY:-10}"
DEBUG="${DEBUG:-0}"

# Logging - file logging disabled by default, enable with --log-file flag
LOG_TO_FILE="${LOG_TO_FILE:-0}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"
LOG_FILE=""

timestamp() {
    date "+%Y-%m-%dT%H:%M:%S%z"
}

log_raw() {
    local level="$1"; shift
    local msg="$*"
    local line
    line="$(timestamp) [$level] $msg"
    if [ "$LOG_TO_FILE" = "1" ] && [ -n "$LOG_FILE" ]; then
        echo -e "$line" | tee -a "$LOG_FILE" >&2
    else
        echo -e "$line" >&2
    fi
}

log_info()  { log_raw "INFO " "$@"; }
log_warn()  { log_raw "WARN " "$@"; }
log_error() { log_raw "ERROR" "$@"; }
log_debug() {
    if [ "$DEBUG" = "1" ]; then
        log_raw "DEBUG" "$@"
    fi
}

# Safe terraform output that filters out colored warnings
# Terraform outputs warnings to stdout with ANSI color codes containing
# box-drawing characters (│, ╷, ╵) that can be misinterpreted as commands
tf_output_raw() {
    local key="$1"
    # Use -no-color to prevent ANSI escape sequences, filter any remaining warnings
    terraform output -no-color -raw "$key" 2>/dev/null | grep -v "^Warning:\|^│\|^╷\|^╵\|No outputs found" | head -1 || echo ""
}

tf_output_json() {
    local key="$1"
    terraform output -no-color -json "$key" 2>/dev/null | grep -v "^Warning:\|^│\|^╷\|^╵\|No outputs found" || echo "{}"
}

# --------------------------------------------------------------------
# Terraform workspace locking - allows concurrent script execution
# --------------------------------------------------------------------
acquire_tf_lock() {
    local start_time=$(date +%s)
    local lock_acquired=false

    log_debug "Attempting to acquire Terraform workspace lock..."

    while [ "$lock_acquired" = "false" ]; do
        # Try to create lock file atomically
        if ( set -o noclobber; echo "$$:$WORKSPACE:$(date +%s)" > "$TF_LOCK_FILE" ) 2>/dev/null; then
            lock_acquired=true
            log_debug "Terraform lock acquired (PID: $$)"
        else
            # Lock exists - check if it's stale
            if [ -f "$TF_LOCK_FILE" ]; then
                local lock_info=$(cat "$TF_LOCK_FILE" 2>/dev/null || echo "")
                local lock_pid=$(echo "$lock_info" | cut -d: -f1)
                local lock_workspace=$(echo "$lock_info" | cut -d: -f2)
                local lock_time=$(echo "$lock_info" | cut -d: -f3)

                # Check if locking process is still alive
                if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
                    log_warn "Removing stale lock from dead process $lock_pid"
                    rm -f "$TF_LOCK_FILE"
                    continue
                fi

                # Check if lock is too old (stale)
                local now=$(date +%s)
                if [ -n "$lock_time" ] && [ $((now - lock_time)) -gt $TF_LOCK_TIMEOUT ]; then
                    log_warn "Removing stale lock (older than ${TF_LOCK_TIMEOUT}s)"
                    rm -f "$TF_LOCK_FILE"
                    continue
                fi

                log_debug "Lock held by PID $lock_pid for workspace '$lock_workspace', waiting..."
            fi

            # Check timeout
            local elapsed=$(($(date +%s) - start_time))
            if [ $elapsed -ge $TF_LOCK_TIMEOUT ]; then
                log_error "Timeout waiting for Terraform workspace lock after ${TF_LOCK_TIMEOUT}s"
                return 1
            fi

            sleep 1
        fi
    done

    return 0
}

release_tf_lock() {
    if [ -f "$TF_LOCK_FILE" ]; then
        local lock_pid=$(cut -d: -f1 "$TF_LOCK_FILE" 2>/dev/null || echo "")
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$TF_LOCK_FILE"
            log_debug "Terraform lock released"
        fi
    fi
}

print_header() {
    echo -e "${BLUE}${BOLD}"
    echo "=============================================="
    echo " OCI Bastion Service Tunnel Manager (v$SCRIPT_VERSION)"
    echo "=============================================="
    echo -e "${NC}"
}

print_usage() {
    echo "Usage: $0 [OPTIONS] <MODE>"
    echo ""
    echo "Modes:"
    echo "  ssh       SSH access to OKE worker node"
    echo "  kubectl   Direct kubectl access to Kubernetes API"
    echo "  both      SSH + kubectl"
    echo ""
    echo "Options:"
    echo "  --workspace <name>   Terraform workspace (primary|secondary)"
    echo "  --tfvars <file>      Path to tfvars file"
    echo "  --debug              Enable debug logging"
    echo "  --log-file           Save logs to file (default: logs to screen only)"
    echo "  --help               Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  LOCAL_PORT           Local port for K8s API tunnel (default: 6443)"
    echo "  SSH_PORT             Local port for SSH tunnel (default: 2222)"
    echo "  SESSION_DURATION     Bastion session TTL in seconds (default: 3600)"
    echo "  DEBUG                Enable debug logging (0|1)"
    echo "  LOG_TO_FILE          Save logs to file (0|1, default: 0)"
    echo "  LOG_DIR              Directory for log files (default: ./logs)"
    echo ""
    echo "Examples:"
    echo "  # Connect to primary cluster on port 16443"
    echo "  LOCAL_PORT=16443 $0 --workspace primary kubectl"
    echo ""
    echo "  # Connect to secondary cluster on port 16444"
    echo "  LOCAL_PORT=16444 $0 --workspace secondary kubectl"
    echo ""
    echo "  # Connect with debug logging saved to file"
    echo "  LOCAL_PORT=16443 $0 --workspace primary --debug --log-file kubectl"
    echo ""
}

# Kill existing SSH bastion tunnel processes
kill_existing_tunnels() {
    log_debug "Checking for existing SSH bastion tunnels to clean up..."

    local pids=""
    local pattern

    pattern="ssh .*127\.0\.0\.1:${SSH_PORT}:"
    pids+=" $(pgrep -f "$pattern" 2>/dev/null || true)"

    pattern="ssh .*127\.0\.0\.1:${LOCAL_PORT}:"
    pids+=" $(pgrep -f "$pattern" 2>/dev/null || true)"

    if [ -n "${REGION:-}" ]; then
        pattern="ssh .*host\.bastion\.${REGION}\.oci\.oraclecloud\.com"
        pids+=" $(pgrep -f "$pattern" 2>/dev/null || true)"
    fi

    # Also check for any process using our target ports via lsof
    pids+=" $(lsof -ti ":${LOCAL_PORT}" 2>/dev/null || true)"
    pids+=" $(lsof -ti ":${SSH_PORT}" 2>/dev/null || true)"

    pids=$(echo "$pids" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)

    if [ -n "$pids" ]; then
        log_warn "Killing existing SSH tunnel processes: $pids"
        echo "$pids" | xargs -r kill >/dev/null 2>&1 || true
        sleep 2  # Give processes time to release ports
    else
        log_debug "No existing SSH bastion tunnel processes found"
    fi
}

# --------------------------------------------------------------------
# Cleanup stale bastion sessions on startup
# This prevents QuotaExceeded errors from accumulated sessions
# --------------------------------------------------------------------
cleanup_stale_sessions() {
    local bastion_id="$1"
    local max_to_keep="${2:-1}"  # Keep at most 1 session by default

    if [ -z "$bastion_id" ]; then
        log_debug "No bastion ID provided, skipping session cleanup"
        return 0
    fi

    echo ""
    echo -e "${BLUE}Checking for stale bastion sessions...${NC}"

    # List all active sessions for this bastion
    local sessions_json
    sessions_json=$(oci_cmd bastion session list \
        --bastion-id "$bastion_id" \
        --session-lifecycle-state ACTIVE \
        --output json 2>/dev/null || echo '{"data":[]}')

    local session_count
    session_count=$(echo "$sessions_json" | jq -r '.data | length' 2>/dev/null)

    # Handle empty or invalid response - default to 0
    if [ -z "$session_count" ] || ! [[ "$session_count" =~ ^[0-9]+$ ]]; then
        log_debug "Could not parse session count from response, assuming 0"
        session_count=0
    fi

    if [ "$session_count" -eq 0 ]; then
        echo -e "${GREEN}No active sessions found${NC}"
        return 0
    fi

    echo -e "  Found ${YELLOW}$session_count${NC} active session(s)"

    # If we have more sessions than max_to_keep, delete the older ones
    if [ "$session_count" -gt "$max_to_keep" ]; then
        local sessions_to_delete=$((session_count - max_to_keep))
        echo -e "  Cleaning up ${YELLOW}$sessions_to_delete${NC} stale session(s)..."

        # Get session IDs sorted by creation time (oldest first), skip the newest ones
        local session_ids
        session_ids=$(echo "$sessions_json" | jq -r '.data | sort_by(.["time-created"]) | .[:-'"$max_to_keep"'] | .[].id')

        local deleted=0
        local failed=0
        for session_id in $session_ids; do
            log_debug "Deleting session: $session_id"
            if delete_bastion_session "$session_id"; then
                deleted=$((deleted + 1))
            else
                failed=$((failed + 1))
                log_debug "Failed to delete session: $session_id"
            fi
        done

        if [ "$deleted" -gt 0 ]; then
            echo -e "  ${GREEN}Deleted $deleted stale session(s)${NC}"
        fi
        if [ "$failed" -gt 0 ]; then
            echo -e "  ${YELLOW}Failed to delete $failed session(s) (may already be deleted)${NC}"
        fi
    else
        echo -e "  ${GREEN}Session count within limit ($session_count <= $max_to_keep)${NC}"
    fi
}

cd "$ROOT_DIR"

# --------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------
WORKSPACE=""
MODE=""
TFVARS_FILE="${TFVARS_FILE:-}"
SHOW_HELP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --workspace)
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: --workspace requires a value${NC}" >&2
                exit 1
            fi
            WORKSPACE="$2"
            shift 2
            ;;
        --workspace=*)
            WORKSPACE="${1#*=}"
            shift
            ;;
        --tfvars)
            if [ $# -lt 2 ]; then
                echo -e "${RED}Error: --tfvars requires a value${NC}" >&2
                exit 1
            fi
            TFVARS_FILE="$2"
            shift 2
            ;;
        --tfvars=*)
            TFVARS_FILE="${1#*=}"
            shift
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        --log-file)
            LOG_TO_FILE=1
            shift
            ;;
        --help|-h)
            SHOW_HELP=1
            shift
            ;;
        ssh|kubectl|both)
            MODE="$1"
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo -e "${RED}Error: Unknown option or mode: $1${NC}" >&2
            print_usage
            exit 1
            ;;
    esac
done

# Initialize log file if --log-file was specified
if [ "$LOG_TO_FILE" = "1" ]; then
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/bastion-tunnel-v3-$(date +%Y%m%d-%H%M%S).log"
    echo "Logging to file: $LOG_FILE"
fi

print_header

if [ "$SHOW_HELP" = "1" ]; then
    print_usage
    exit 0
fi

if [ -z "$MODE" ]; then
    MODE="kubectl"
    log_info "No mode specified, defaulting to: kubectl"
fi

# --------------------------------------------------------------------
# Workspace validation - validates workspace name only, does NOT switch
# Actual workspace switch happens in extract_config() under lock
# --------------------------------------------------------------------
validate_workspace_name() {
    local requested_workspace="$1"

    if [ -z "$requested_workspace" ]; then
        # No workspace specified - we'll use current workspace later
        echo -e "${YELLOW}Warning: No --workspace specified, will use current workspace${NC}"
        echo -e "${YELLOW}         For explicit control, use: --workspace primary OR --workspace secondary${NC}"
        echo ""
        # WORKSPACE remains empty, extract_config will detect current workspace under lock
    else
        WORKSPACE="$requested_workspace"
        # Note: Any valid Terraform workspace name is accepted
        # Common workspaces: primary, secondary, single, default
        echo -e "${GREEN}Using Terraform workspace: ${BOLD}$WORKSPACE${NC}"
    fi
}

validate_workspace_name "$WORKSPACE"

# Default tfvars file based on workspace
# Dynamically find tfvars file matching workspace name pattern
if [ -z "$TFVARS_FILE" ] && [ -n "$WORKSPACE" ]; then
    # Try workspace-specific tfvars file pattern: ${WORKSPACE}-*.tfvars
    TFVARS_FILE=$(ls -1 "${WORKSPACE}"-*.tfvars 2>/dev/null | head -1 || true)

    # Fallback to terraform.tfvars if no workspace-specific file found
    if [ -z "$TFVARS_FILE" ] && [ -f "terraform.tfvars" ]; then
        TFVARS_FILE="terraform.tfvars"
    fi

    if [ -n "$TFVARS_FILE" ]; then
        log_debug "Auto-detected tfvars file: $TFVARS_FILE"
    fi
fi

# --------------------------------------------------------------------
# Global context
# --------------------------------------------------------------------
COMPARTMENT_ID=""
REGION=""
OCI_PROFILE=""
SSH_KEY_PATH=""
PRIVATE_KEY_PATH=""
CLUSTER_ID=""
BASTION_SERVICE_ID=""

NODE_IP=""

K8S_ENDPOINT=""
K8S_HOST=""
K8S_PORT=""

SSH_SESSION_ID=""
SSH_SESSION_STARTED_AT=0
SSH_TUNNEL_PID=""

K8S_SESSION_ID=""
K8S_SESSION_STARTED_AT=0
K8S_TUNNEL_PID=""

OCI_AUTH_FLAG="--auth api_key"

# --------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------

# Wrapper for OCI CLI commands with common auth parameters
oci_cmd() {
    oci "$@" --profile "$OCI_PROFILE" $OCI_AUTH_FLAG
}

# Delete a single bastion session by ID
delete_bastion_session() {
    local session_id="$1"
    local quiet="${2:-false}"

    if [ -z "$session_id" ]; then
        return 1
    fi

    if [ "$quiet" = "true" ]; then
        oci_cmd bastion session delete --session-id "$session_id" --force >/dev/null 2>&1
    else
        oci_cmd bastion session delete --session-id "$session_id" --force 2>/dev/null
    fi
}

# Kill a process by PID with optional signal
kill_process() {
    local pid="$1"
    local signal="${2:-TERM}"

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -"$signal" "$pid" 2>/dev/null || true
        return 0
    fi
    return 1
}

# Kill processes using a specific port
kill_processes_on_port() {
    local port="$1"
    local pids
    pids=$(lsof -ti ":${port}" 2>/dev/null || true)

    if [ -n "$pids" ]; then
        log_warn "Killing process(es) using port ${port}: $pids"
        echo "$pids" | xargs -r kill 2>/dev/null || true
        sleep 2  # Wait for port to be released
        return 0
    fi
    return 1
}

# Check if required tools are available
check_required_tools() {
    local missing_tools=""

    for tool in jq terraform oci ssh curl nc lsof; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools="$missing_tools $tool"
        fi
    done

    if [ -n "$missing_tools" ]; then
        echo -e "${RED}Error: Required tools not found:${NC}$missing_tools"
        echo -e "${YELLOW}Please install the missing tools and try again.${NC}"
        exit 1
    fi
}

read_tfvar() {
    local key="$1"
    local file="$TFVARS_FILE"

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        return 0
    fi

    local line
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n1 || true)
    if [ -z "$line" ]; then
        return 0
    fi

    line="${line#*=}"
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    line="${line%\"}"
    line="${line#\"}"
    line="${line%\'}"
    line="${line#\'}"

    echo "$line"
}

ensure_ssh_config() {
    log_debug "Checking SSH client configuration..."

    local ssh_config_file="$HOME/.ssh/config"

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [ ! -f "$ssh_config_file" ] || ! grep -q "HostKeyAlgorithms.*ssh-rsa" "$ssh_config_file" 2>/dev/null; then
        log_debug "Adding OCI Bastion compatibility settings to SSH config"
        {
            echo ""
            echo "# OCI Bastion Service compatibility settings"
            echo "Host *.oci.oraclecloud.com"
            echo "    HostKeyAlgorithms +ssh-rsa"
            echo "    PubkeyAcceptedKeyTypes +ssh-rsa"
            echo "    ServerAliveInterval 30"
            echo "    ServerAliveCountMax 5"
            echo "    TCPKeepAlive yes"
            echo ""
        } >> "$ssh_config_file"

        chmod 600 "$ssh_config_file"
        echo -e "${GREEN}Updated SSH config for OCI Bastion compatibility${NC}"
    else
        log_debug "SSH config already has compatibility settings"
    fi
}

extract_config() {
    echo ""
    echo -e "${BLUE}Extracting configuration from Terraform state...${NC}"

    # Acquire lock to prevent concurrent workspace switches
    echo -e "  ${CYAN}Waiting for Terraform workspace lock...${NC}"
    if ! acquire_tf_lock; then
        echo -e "${RED}Error: Could not acquire Terraform workspace lock${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}Lock acquired${NC}"

    # Get current workspace while holding the lock
    local actual_workspace
    actual_workspace=$(terraform workspace show 2>/dev/null || echo "default")

    # If no workspace was specified via --workspace, use current
    if [ -z "$WORKSPACE" ]; then
        WORKSPACE="$actual_workspace"
        log_info "Using current Terraform workspace: $WORKSPACE"
    fi

    # Switch to the requested workspace if different
    if [ "$actual_workspace" != "$WORKSPACE" ]; then
        log_info "Switching Terraform workspace: $actual_workspace -> $WORKSPACE"
        if ! terraform workspace select "$WORKSPACE" >/dev/null 2>&1; then
            echo -e "${RED}Error: Failed to select Terraform workspace '$WORKSPACE'${NC}"
            echo -e "${YELLOW}Available workspaces:${NC}"
            terraform workspace list
            release_tf_lock
            exit 1
        fi
        # Verify switch succeeded
        actual_workspace=$(terraform workspace show 2>/dev/null)
        if [ "$actual_workspace" != "$WORKSPACE" ]; then
            echo -e "${RED}Error: Workspace switch failed. Expected '$WORKSPACE', got '$actual_workspace'${NC}"
            release_tf_lock
            exit 1
        fi
    fi
    log_debug "Workspace confirmed: $WORKSPACE"

    # Extract ALL Terraform outputs in one go while we hold the lock
    # Use tf_output_raw helper to filter Terraform's colored warnings
    BASTION_SERVICE_ID=$(tf_output_raw bastion_service_id)
    log_debug "Bastion Service ID: $BASTION_SERVICE_ID"

    if [ -z "$BASTION_SERVICE_ID" ] || [ "$BASTION_SERVICE_ID" = "null" ]; then
        echo -e "${RED}Error: No OCI Bastion Service found in Terraform state${NC}"
        echo -e "${YELLOW}Ensure provision_bastion = true in tfvars and infrastructure is deployed${NC}"
        release_tf_lock
        exit 1
    fi

    COMPARTMENT_ID=$(tf_output_raw compartment_ocid)
    REGION=$(tf_output_raw region)
    OCI_PROFILE=$(tf_output_raw oci_profile_used)
    SSH_KEY_PATH=$(tf_output_raw ssh_public_key_path)
    CLUSTER_ID=$(tf_output_raw cluster_id)

    # CRITICAL: Also extract K8s endpoint while we have the lock
    local cluster_details
    cluster_details=$(tf_output_json cluster_endpoint_details)
    K8S_ENDPOINT=$(echo "$cluster_details" | jq -r '.private_endpoint // .kubernetes_endpoint // empty')
    log_debug "K8s endpoint from Terraform: $K8S_ENDPOINT"

    # Release lock immediately after extracting all Terraform outputs
    # This allows other scripts for different workspaces to proceed
    release_tf_lock
    log_debug "Terraform lock released after config extraction"

    # Fallback to tfvars when outputs are missing
    if [ -z "$COMPARTMENT_ID" ] || [ "$COMPARTMENT_ID" = "null" ]; then
        COMPARTMENT_ID=$(read_tfvar compartment_ocid || true)
        if [ -z "$COMPARTMENT_ID" ]; then
            COMPARTMENT_ID=$(read_tfvar compartment_id || true)
        fi
    fi

    if [ -z "$REGION" ] || [ "$REGION" = "null" ]; then
        REGION=$(read_tfvar region || true)
    fi

    if [ -z "$OCI_PROFILE" ] || [ "$OCI_PROFILE" = "null" ]; then
        OCI_PROFILE=$(read_tfvar config_file_profile || true)
    fi

    if [ -z "$SSH_KEY_PATH" ] || [ "$SSH_KEY_PATH" = "null" ]; then
        SSH_KEY_PATH=$(read_tfvar ssh_public_key_path || true)
    fi

    if [ -z "$SSH_KEY_PATH" ]; then
        SSH_KEY_PATH="~/.ssh/id_ed25519.pub"
    fi

    SSH_KEY_PATH=$(eval echo "$SSH_KEY_PATH")

    # Derive private key path
    if [[ "$SSH_KEY_PATH" == *"_public.pem" ]]; then
        PRIVATE_KEY_PATH="${SSH_KEY_PATH/_public.pem/.pem}"
    elif [[ "$SSH_KEY_PATH" == *".pub" ]]; then
        PRIVATE_KEY_PATH="${SSH_KEY_PATH%.pub}"
    else
        PRIVATE_KEY_PATH="${SSH_KEY_PATH%.*}"
    fi

    if [ -z "$OCI_PROFILE" ]; then
        OCI_PROFILE="DEFAULT"
    fi

    log_debug "Compartment ID: ${COMPARTMENT_ID:-<unset>}"
    log_debug "Region: ${REGION:-<unset>}"
    log_debug "OCI Profile: ${OCI_PROFILE:-<unset>}"
    log_debug "SSH Public Key: $SSH_KEY_PATH"
    log_debug "SSH Private Key: $PRIVATE_KEY_PATH"
    log_debug "Cluster ID: $CLUSTER_ID"

    if [ ! -f "$SSH_KEY_PATH" ]; then
        echo -e "${RED}Error: SSH public key not found at: $SSH_KEY_PATH${NC}"
        exit 1
    fi
    if [ ! -f "$PRIVATE_KEY_PATH" ]; then
        echo -e "${RED}Error: SSH private key not found at: $PRIVATE_KEY_PATH${NC}"
        exit 1
    fi

    echo -e "${GREEN}Configuration loaded:${NC}"
    echo "  Workspace:         $WORKSPACE"
    echo "  Bastion Service:   ${BASTION_SERVICE_ID:0:50}..."
    echo "  Cluster ID:        ${CLUSTER_ID:0:50}..."
    echo "  K8s Endpoint:      $K8S_ENDPOINT"
    echo "  Region:            $REGION"
    echo "  OCI Profile:       $OCI_PROFILE"
    echo "  SSH Key:           $SSH_KEY_PATH"
}

# --------------------------------------------------------------------
# CRITICAL v3 FIX: Validate bastion can reach target
# --------------------------------------------------------------------
validate_bastion_network_access() {
    local target_ip="$1"

    echo ""
    echo -e "${BLUE}Validating bastion network access to $target_ip...${NC}"

    # Get bastion details including target subnet
    local bastion_details
    bastion_details=$(oci_cmd bastion bastion get \
        --bastion-id "$BASTION_SERVICE_ID" \
        --output json 2>/dev/null)

    if [ -z "$bastion_details" ]; then
        echo -e "${RED}Error: Cannot retrieve bastion service details${NC}"
        return 1
    fi

    local bastion_name bastion_state target_subnet_id
    bastion_name=$(echo "$bastion_details" | jq -r '.data.name // "unknown"')
    bastion_state=$(echo "$bastion_details" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
    target_subnet_id=$(echo "$bastion_details" | jq -r '.data."target-subnet-id" // "unknown"')

    log_debug "Bastion name: $bastion_name"
    log_debug "Bastion state: $bastion_state"
    log_debug "Target subnet ID: $target_subnet_id"

    if [ "$bastion_state" != "ACTIVE" ]; then
        echo -e "${RED}Error: Bastion service is not ACTIVE (state: $bastion_state)${NC}"
        return 1
    fi

    # Extract VCN CIDR from target IP to validate network alignment
    local target_network
    target_network=$(echo "$target_ip" | cut -d'.' -f1-2)

    # Get subnet details to find VCN
    local subnet_details vcn_id
    subnet_details=$(oci_cmd network subnet get \
        --subnet-id "$target_subnet_id" \
        --output json 2>/dev/null || echo "{}")

    vcn_id=$(echo "$subnet_details" | jq -r '.data."vcn-id" // "unknown"')
    local subnet_cidr
    subnet_cidr=$(echo "$subnet_details" | jq -r '.data."cidr-block" // "unknown"')

    log_debug "Bastion target subnet CIDR: $subnet_cidr"
    log_debug "Target IP network prefix: $target_network"

    # Check if target IP is in the bastion's reachable network
    local subnet_network
    subnet_network=$(echo "$subnet_cidr" | cut -d'.' -f1-2)

    if [ "$target_network" != "$subnet_network" ]; then
        echo -e "${RED}ERROR: Network mismatch detected!${NC}"
        echo ""
        echo -e "${RED}  Bastion '$bastion_name' is in network: ${subnet_network}.x.x${NC}"
        echo -e "${RED}  Target K8s API is in network: ${target_network}.x.x${NC}"
        echo ""
        echo -e "${YELLOW}This usually means you're using the wrong workspace.${NC}"
        echo ""
        echo -e "${YELLOW}Current workspace: ${BOLD}$WORKSPACE${NC}"
        echo ""
        echo -e "${CYAN}To fix this, use the correct workspace:${NC}"
        if [ "$target_network" = "10.0" ]; then
            echo -e "${GREEN}  LOCAL_PORT=$LOCAL_PORT $0 --workspace primary $MODE${NC}"
        elif [ "$target_network" = "10.1" ]; then
            echo -e "${GREEN}  LOCAL_PORT=$LOCAL_PORT $0 --workspace secondary $MODE${NC}"
        fi
        echo ""
        return 1
    fi

    echo -e "${GREEN}Network validation passed: Bastion can reach $target_ip${NC}"
    return 0
}

validate_bastion_service() {
    echo ""
    echo -e "${BLUE}Validating OCI Bastion Service...${NC}"

    echo "Checking current public IP address..."
    local current_ip
    current_ip=$(curl -s --connect-timeout 5 http://checkip.amazonaws.com/ || curl -s --connect-timeout 5 http://ipecho.net/plain || echo "unknown")
    log_debug "Current public IP: $current_ip"

    local bastion_details
    bastion_details=$(oci_cmd bastion bastion get \
        --bastion-id "$BASTION_SERVICE_ID" \
        --output json 2>/dev/null)

    if [ -z "$bastion_details" ]; then
        echo -e "${RED}Error: Cannot access bastion service${NC}"
        return 1
    fi

    local bastion_state bastion_name client_cidrs
    bastion_state=$(echo "$bastion_details" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
    bastion_name=$(echo "$bastion_details" | jq -r '.data."name" // "unknown"')
    client_cidrs=$(echo "$bastion_details" | jq -r '.data."client-cidr-block-allow-list" // []')

    log_debug "Bastion state: $bastion_state"
    log_debug "Bastion name: $bastion_name"

    echo "Bastion Service:"
    echo "  Name:      $bastion_name"
    echo "  State:     $bastion_state"
    echo "  Your IP:   $current_ip"

    # Check if current IP is in allow list
    local ip_allowed=false
    if echo "$client_cidrs" | grep -q "$current_ip"; then
        ip_allowed=true
    fi

    if [ "$ip_allowed" = "true" ]; then
        echo -e "  IP Access: ${GREEN}Allowed${NC}"
    else
        echo -e "  IP Access: ${YELLOW}Not in allow list (may fail)${NC}"
        echo -e "  ${YELLOW}Allow list: $client_cidrs${NC}"
    fi

    if [ "$bastion_state" != "ACTIVE" ]; then
        echo -e "${RED}Error: Bastion service is not ACTIVE (state: $bastion_state)${NC}"
        return 1
    fi

    return 0
}

test_bastion_connectivity() {
    echo ""
    echo -e "${BLUE}Testing network connectivity to bastion endpoint...${NC}"

    local bastion_host="host.bastion.${REGION}.oci.oraclecloud.com"
    log_debug "Testing connectivity to $bastion_host:22"

    set +e
    local nc_result
    timeout 10 nc -z "$bastion_host" 22 2>&1
    nc_result=$?
    set -e

    if [ $nc_result -eq 0 ]; then
        echo -e "${GREEN}Network connectivity to bastion endpoint: OK${NC}"
        return 0
    else
        echo -e "${YELLOW}Warning: Network connectivity test to $bastion_host:22 failed${NC}"
        echo -e "${YELLOW}This may be due to firewall rules. Continuing anyway...${NC}"
        return 0
    fi
}

derive_k8s_endpoint() {
    echo ""
    echo -e "${BLUE}Resolving Kubernetes API endpoint...${NC}"

    # v3.1.0: Use the K8S_ENDPOINT extracted in extract_config() while holding the lock
    # This avoids Terraform calls here, allowing concurrent script execution
    local endpoint="$K8S_ENDPOINT"

    if [ -z "$endpoint" ] || [ "$endpoint" = "null" ]; then
        echo -e "${RED}Error: K8S_ENDPOINT not set. Was extract_config() called?${NC}"
        return 1
    fi

    echo -e "${GREEN}Kubernetes API endpoint: $endpoint${NC}"

    K8S_HOST=$(echo "$endpoint" | cut -d':' -f1)
    K8S_PORT=$(echo "$endpoint" | cut -d':' -f2)

    log_debug "K8s API host: $K8S_HOST"
    log_debug "K8s API port: $K8S_PORT"

    # CRITICAL v3 FIX: Validate network access before proceeding
    if ! validate_bastion_network_access "$K8S_HOST"; then
        return 1
    fi
}

# --------------------------------------------------------------------
# Session management
# --------------------------------------------------------------------

create_port_forward_session() {
    local target_ip="$1"
    local target_port="$2"
    local display_name="$3"

    log_debug "Creating PORT_FORWARDING session to ${target_ip}:${target_port}"

    local ssh_key_content=""

    if [[ "$SSH_KEY_PATH" == *".pem" ]]; then
        local openssh_key_path="${SSH_KEY_PATH%.pem}.pub"
        if [ -f "$openssh_key_path" ]; then
            ssh_key_content=$(cat "$openssh_key_path" 2>/dev/null || echo "")
        elif [ -f "$PRIVATE_KEY_PATH" ]; then
            ssh_key_content=$(ssh-keygen -y -f "$PRIVATE_KEY_PATH" 2>/dev/null || echo "")
        fi

        if [ -z "$ssh_key_content" ]; then
            ssh_key_content=$(ssh-keygen -f "$SSH_KEY_PATH" -i -m PKCS8 2>/dev/null || ssh-keygen -f "$SSH_KEY_PATH" -i -m PEM 2>/dev/null || echo "")
        fi
    else
        ssh_key_content=$(cat "$SSH_KEY_PATH" 2>/dev/null || echo "")
    fi

    if [ -z "$ssh_key_content" ]; then
        echo -e "${RED}Error: Cannot extract OpenSSH format public key${NC}"
        return 1
    fi

    if ! echo "$ssh_key_content" | grep -qE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-)'; then
        echo -e "${RED}Error: Extracted key is not in valid OpenSSH format${NC}"
        return 1
    fi

    local temp_key_file
    temp_key_file=$(mktemp)
    echo "$ssh_key_content" > "$temp_key_file"

    set +e
    local session_output create_result
    session_output=$(oci_cmd bastion session create-port-forwarding \
        --bastion-id "$BASTION_SERVICE_ID" \
        --target-private-ip "$target_ip" \
        --target-port "$target_port" \
        --ssh-public-key-file "$temp_key_file" \
        --session-ttl "$SESSION_DURATION" \
        --display-name "$display_name" \
        --output json 2>&1)
    create_result=$?
    rm -f "$temp_key_file"
    set -e

    if [ $create_result -ne 0 ] || [ -z "$session_output" ]; then
        echo -e "${RED}Error: Failed to create bastion session${NC}"
        log_error "Session creation failed: $session_output"
        return 1
    fi

    # Check if it's an error response
    if echo "$session_output" | grep -q '"code"'; then
        local error_code error_message
        error_code=$(echo "$session_output" | jq -r '.code // "unknown"')
        error_message=$(echo "$session_output" | jq -r '.message // "unknown"')
        echo -e "${RED}Error: OCI API returned error: $error_code${NC}"
        echo -e "${RED}Message: $error_message${NC}"
        return 1
    fi

    local session_id
    session_id=$(echo "$session_output" | jq -r '.data.id')

    if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
        echo -e "${RED}Error: No session ID returned${NC}"
        log_error "Session output: $session_output"
        return 1
    fi

    log_info "Created new session: $session_id"
    echo "$session_id"
}

wait_for_session_active() {
    local session_id="$1"

    log_debug "Waiting for session $session_id to become ACTIVE..."

    local max_attempts=24
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        set +e
        local session_status get_result
        session_status=$(oci_cmd bastion session get \
            --session-id "$session_id" \
            --output json 2>/dev/null)
        get_result=$?
        set -e

        if [ $get_result -eq 0 ]; then
            local current_state
            current_state=$(echo "$session_status" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
            log_debug "Session state: $current_state (attempt $((attempt+1))/$max_attempts)"

            printf "\r  Session status: %-12s (check %d/%d)" "$current_state" "$((attempt+1))" "$max_attempts"

            if [ "$current_state" = "ACTIVE" ]; then
                printf "\n"
                echo -e "${GREEN}Session is now ACTIVE${NC}"
                return 0
            elif [ "$current_state" = "FAILED" ] || [ "$current_state" = "DELETED" ]; then
                printf "\n"
                echo -e "${RED}Error: Session entered terminal state: $current_state${NC}"
                return 1
            fi
        else
            log_debug "Unable to fetch session status (attempt $((attempt+1)))"
        fi

        attempt=$((attempt+1))
        sleep 10
    done

    printf "\n"
    echo -e "${RED}Error: Session did not become active within timeout${NC}"
    return 1
}

start_k8s_tunnel() {
    echo ""
    echo -e "${BLUE}Establishing SSH tunnel to Kubernetes API...${NC}"

    if [ -n "$K8S_TUNNEL_PID" ] && kill -0 "$K8S_TUNNEL_PID" 2>/dev/null; then
        log_debug "Killing existing K8s tunnel PID $K8S_TUNNEL_PID"
        kill "$K8S_TUNNEL_PID" 2>/dev/null || true
        K8S_TUNNEL_PID=""
    fi

    # Determine key type and set appropriate SSH options
    local key_type_options=""
    if [[ "$PRIVATE_KEY_PATH" == *"ed25519"* ]] || ssh-keygen -lf "$SSH_KEY_PATH" 2>/dev/null | grep -q "(ED25519)"; then
        log_debug "Using ED25519 key"
        key_type_options="-o HostKeyAlgorithms=+ssh-rsa,ssh-ed25519 -o PubkeyAcceptedKeyTypes=+ssh-rsa,ssh-ed25519"
    else
        log_debug "Using RSA key"
        key_type_options="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa"
    fi

    local bastion_host="host.bastion.${REGION}.oci.oraclecloud.com"
    local ssh_cmd
    ssh_cmd="ssh -i \"$PRIVATE_KEY_PATH\" -L \"127.0.0.1:${LOCAL_PORT}:${K8S_HOST}:${K8S_PORT}\" \
        -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=30 \
        -o ExitOnForwardFailure=yes $key_type_options \
        -o TCPKeepAlive=yes -o BatchMode=yes -o LogLevel=ERROR -o PasswordAuthentication=no \
        -o KbdInteractiveAuthentication=no -o PreferredAuthentications=publickey -4 -N -p 22 \
        \"${K8S_SESSION_ID}@${bastion_host}\""

    log_debug "SSH tunnel command: $ssh_cmd"

    echo "Starting SSH tunnel to K8s API..."
    echo "  Local:  127.0.0.1:$LOCAL_PORT"
    echo "  Remote: $K8S_HOST:$K8S_PORT"

    set +e
    eval "$ssh_cmd" &
    K8S_TUNNEL_PID=$!
    set -e

    log_debug "K8s tunnel PID: $K8S_TUNNEL_PID"

    sleep 5

    if ! kill -0 "$K8S_TUNNEL_PID" 2>/dev/null; then
        echo -e "${RED}Error: SSH tunnel process died immediately${NC}"
        echo -e "${YELLOW}This may be due to:${NC}"
        echo -e "${YELLOW}  - SSH key not matching the bastion session${NC}"
        echo -e "${YELLOW}  - Network connectivity issues${NC}"
        echo -e "${YELLOW}  - Bastion session not yet active${NC}"
        return 1
    fi

    echo -e "${GREEN}SSH tunnel established successfully${NC}"
    echo -e "${GREEN}  kubectl API available at: https://127.0.0.1:$LOCAL_PORT${NC}"
}

configure_kubectl_for_local_api() {
    echo ""
    echo -e "${BLUE}Configuring kubectl...${NC}"

    set +e
    oci_cmd ce cluster create-kubeconfig \
        --cluster-id "$CLUSTER_ID" \
        --file "$HOME/.kube/config" \
        --region "$REGION" \
        --token-version 2.0.0 2>/dev/null
    set -e

    local cluster_name="cluster-${CLUSTER_ID}"
    local user_name="user-$(echo "$CLUSTER_ID" | cut -d'.' -f5)"

    kubectl config set-cluster "$cluster_name" \
        --server="https://127.0.0.1:$LOCAL_PORT" \
        --insecure-skip-tls-verify=true 2>/dev/null

    kubectl config set-credentials "$user_name" \
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
        --exec-arg=--auth \
        --exec-arg=api_key \
        --exec-api-version=client.authentication.k8s.io/v1beta1 2>/dev/null

    kubectl config set-context "$(kubectl config current-context)" \
        --cluster="$cluster_name" \
        --user="$user_name" 2>/dev/null

    echo -e "${GREEN}kubectl configured for tunnel access${NC}"

    echo "Testing kubectl connectivity..."
    set +e
    local test_output
    test_output=$(kubectl get nodes 2>&1)
    local test_result=$?
    set -e

    if [ $test_result -eq 0 ]; then
        echo -e "${GREEN}kubectl connectivity test: SUCCESS${NC}"
        echo ""
        echo "Cluster nodes:"
        echo "$test_output" | head -5
    else
        echo -e "${YELLOW}kubectl connectivity test: FAILED${NC}"
        echo -e "${YELLOW}Output: $test_output${NC}"
        echo -e "${YELLOW}The tunnel is established but kubectl may need a moment to connect.${NC}"
    fi
}

restart_k8s_session_and_tunnel() {
    log_info "Setting up K8s API session and tunnel..."

    # Kill tracked tunnel PID if it exists
    kill_process "$K8S_TUNNEL_PID" && K8S_TUNNEL_PID=""

    # Also kill any process using the target port (handles orphaned tunnels)
    kill_processes_on_port "$LOCAL_PORT"

    # Delete existing session before creating new one
    if [ -n "$K8S_SESSION_ID" ]; then
        delete_bastion_session "$K8S_SESSION_ID" true
        K8S_SESSION_ID=""
    fi

    local new_session_id
    new_session_id=$(create_port_forward_session "$K8S_HOST" "$K8S_PORT" "${WORKSPACE}-kubectl-$(date +%Y%m%d-%H%M%S)")
    local create_result=$?

    # If session creation failed (possibly QuotaExceeded), try cleaning up stale sessions
    if [ $create_result -ne 0 ] || [ -z "$new_session_id" ]; then
        log_warn "Session creation failed, attempting to clean stale sessions..."
        cleanup_stale_sessions "$BASTION_SERVICE_ID" 0
        # Retry once after cleanup
        new_session_id=$(create_port_forward_session "$K8S_HOST" "$K8S_PORT" "${WORKSPACE}-kubectl-$(date +%Y%m%d-%H%M%S)") || return 1
    fi

    K8S_SESSION_ID="$new_session_id"
    K8S_SESSION_STARTED_AT=$(date +%s)

    if ! wait_for_session_active "$K8S_SESSION_ID"; then
        # Session failed to become active, clean it up
        delete_bastion_session "$K8S_SESSION_ID" true
        K8S_SESSION_ID=""
        return 1
    fi

    if ! start_k8s_tunnel; then
        # Tunnel failed, clean up the session to prevent quota exhaustion
        log_warn "Tunnel failed, cleaning up session to prevent quota exhaustion"
        delete_bastion_session "$K8S_SESSION_ID" true
        K8S_SESSION_ID=""
        return 1
    fi
}

watch_k8s_tunnel() {
    log_info "Starting tunnel watchdog (interval ${WATCH_INTERVAL}s)..."

    # Use a loop with shorter sleep intervals to be more responsive to signals
    local sleep_counter=0
    while true; do
        # Check tunnel health every WATCH_INTERVAL seconds
        if [ "$sleep_counter" -ge "$WATCH_INTERVAL" ]; then
            sleep_counter=0

            if [ -z "$K8S_TUNNEL_PID" ] || ! kill -0 "$K8S_TUNNEL_PID" 2>/dev/null; then
                log_warn "K8s tunnel process not running; attempting restart..."
                restart_k8s_session_and_tunnel || log_error "Failed to restart K8s session/tunnel"
            else
                local now elapsed
                now=$(date +%s)
                elapsed=$((now - K8S_SESSION_STARTED_AT))
                if [ "$elapsed" -ge "$((SESSION_DURATION - REFRESH_MARGIN))" ]; then
                    log_info "Bastion session nearing TTL; refreshing..."
                    restart_k8s_session_and_tunnel || log_error "Failed to refresh K8s session/tunnel"
                fi
            fi
        fi

        # Sleep in 1-second increments to respond quickly to Ctrl+C
        sleep 1
        sleep_counter=$((sleep_counter + 1))
    done
}

cleanup() {
    # Prevent multiple cleanup calls
    if [ "${CLEANUP_IN_PROGRESS:-0}" = "1" ]; then
        return
    fi
    CLEANUP_IN_PROGRESS=1

    echo ""
    echo -e "${YELLOW}┌─────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  Cleaning up (Ctrl+C received)...           │${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────┘${NC}"

    # Kill SSH tunnels immediately (these are local processes)
    if kill_process "$SSH_TUNNEL_PID" 9; then
        echo -e "  ${CYAN}Killing SSH worker tunnel${NC} (PID: $SSH_TUNNEL_PID)..."
        wait "$SSH_TUNNEL_PID" 2>/dev/null || true
        echo -e "  ${GREEN}✓ SSH tunnel terminated${NC}"
    fi

    if kill_process "$K8S_TUNNEL_PID" 9; then
        echo -e "  ${CYAN}Killing K8s API tunnel${NC} (PID: $K8S_TUNNEL_PID)..."
        wait "$K8S_TUNNEL_PID" 2>/dev/null || true
        echo -e "  ${GREEN}✓ K8s tunnel terminated${NC}"
    fi

    # Kill any orphaned SSH processes that might be lingering
    if [ -n "${REGION:-}" ]; then
        local orphan_pids
        orphan_pids=$(pgrep -f "ssh.*host\.bastion\.${REGION}\.oci\.oraclecloud\.com" 2>/dev/null || true)
        if [ -n "$orphan_pids" ]; then
            echo -e "  ${CYAN}Killing orphaned SSH processes${NC}: $orphan_pids"
            echo "$orphan_pids" | xargs -r kill -9 2>/dev/null || true
        fi
    fi

    # Handle bastion session cleanup - ALWAYS delete sessions on exit to prevent quota exhaustion
    for session_id in $SSH_SESSION_ID $K8S_SESSION_ID; do
        if [ -n "$session_id" ]; then
            echo -e "  ${CYAN}Deleting bastion session${NC}: ${session_id:0:40}..."
            if delete_bastion_session "$session_id"; then
                echo -e "  ${GREEN}✓ Session deleted${NC}"
            else
                echo -e "  ${YELLOW}⚠ Session deletion failed (may already be deleted)${NC}"
            fi
        fi
    done

    echo ""
    echo -e "${GREEN}┌─────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│  Cleanup completed. Goodbye!                │${NC}"
    echo -e "${GREEN}└─────────────────────────────────────────────┘${NC}"
    exit 0
}

# Trap signals for cleanup - including HUP for terminal disconnect
trap cleanup EXIT INT TERM HUP

# --------------------------------------------------------------------
# Mode handlers
# --------------------------------------------------------------------

run_kubectl_mode() {
    echo ""
    echo -e "${BLUE}=== KUBECTL CONNECTIVITY (v3) ===${NC}"

    # Check for required tools before proceeding
    check_required_tools

    kill_existing_tunnels
    ensure_ssh_config
    extract_config
    validate_bastion_service

    # Clean up stale sessions before creating new ones (prevents QuotaExceeded errors)
    cleanup_stale_sessions "$BASTION_SERVICE_ID" 0  # Delete ALL existing sessions

    test_bastion_connectivity
    derive_k8s_endpoint || exit 1

    local attempt=0
    while ! restart_k8s_session_and_tunnel; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$INITIAL_RETRY_ATTEMPTS" ]; then
            echo -e "${RED}Error: Unable to establish kubectl tunnel after ${INITIAL_RETRY_ATTEMPTS} attempts${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Setup failed, retrying in ${INITIAL_RETRY_DELAY}s (attempt ${attempt}/${INITIAL_RETRY_ATTEMPTS})...${NC}"
        sleep "$INITIAL_RETRY_DELAY"
    done

    configure_kubectl_for_local_api

    echo ""
    echo -e "${GREEN}${BOLD}=============================================="
    echo " kubectl Access Ready!"
    echo "==============================================${NC}"
    echo ""
    echo -e "  ${CYAN}Workspace:${NC}    $WORKSPACE"
    echo -e "  ${CYAN}Local API:${NC}    https://127.0.0.1:$LOCAL_PORT"
    echo -e "  ${CYAN}Remote API:${NC}   $K8S_HOST:$K8S_PORT"
    echo -e "  ${CYAN}Session ID:${NC}   ${K8S_SESSION_ID:0:40}..."
    echo ""
    echo -e "  ${CYAN}Test command:${NC} kubectl get nodes"
    echo ""
    echo "Press Ctrl+C to stop and cleanup..."

    watch_k8s_tunnel
}

# SSH mode implementation (simplified for brevity)
run_ssh_mode() {
    echo -e "${YELLOW}SSH mode not yet implemented in v3. Use kubectl mode.${NC}"
    exit 1
}

run_both_mode() {
    echo -e "${YELLOW}Both mode not yet implemented in v3. Use kubectl mode.${NC}"
    exit 1
}

# --------------------------------------------------------------------
# Main
# --------------------------------------------------------------------

case "$MODE" in
    ssh)
        run_ssh_mode
        ;;
    kubectl)
        run_kubectl_mode
        ;;
    both)
        run_both_mode
        ;;
    *)
        echo -e "${RED}Unknown mode: $MODE${NC}" >&2
        print_usage
        exit 1
        ;;
esac
