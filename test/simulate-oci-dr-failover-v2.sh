#!/usr/bin/env bash
#
# simulate-oci-dr-failover-v2.sh
#
# Comprehensive DR failover simulation for OCI LogScale clusters.
# This script establishes bastion tunnels to both clusters and runs DR simulations.
#
# Architecture:
#   - OCI LB health check monitors LogScale pods via healthCheckNodePort (HTTP 200/503)
#   - When primary LogScale pods go down, the LB returns unhealthy responses
#   - OCI Health Check fails → Monitoring Alarm triggers
#   - Monitoring Alarm → ONS Topic → OCI Function scales secondary humio-operator 0→1
#   - Secondary LogScale pod starts and recovers from primary Object Storage bucket
#
# Scenarios:
#   - primary-down : Scale PRIMARY humio-operator to 0 (simulates real pod failure)
#   - failover     : Disable OCI health check to trigger DR failover (non-invasive)
#   - region-down  : Disable PRIMARY health check (simulates monitoring/region outage -> absent metrics)
#   - failback     : Re-enable health check, reset secondary cluster state
#   - status       : Show current status of both clusters
#
# Requirements:
#   - OCI CLI configured with appropriate profile
#   - Terraform state available for both primary and secondary workspaces
#   - SSH keys for bastion access

set -euo pipefail

export SUPPRESS_LABEL_WARNING=True

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
PRIMARY_LOCAL_PORT="${PRIMARY_LOCAL_PORT:-6443}"
SECONDARY_LOCAL_PORT="${SECONDARY_LOCAL_PORT:-6444}"
SESSION_DURATION="${SESSION_DURATION:-3600}"
FAILOVER_TIMEOUT_SECONDS="${FAILOVER_TIMEOUT_SECONDS:-600}"
DEBUG="${DEBUG:-1}"
NAMESPACE="${NAMESPACE:-logging}"

# Default tfvars files - now configurable via --primary/--secondary
# Empty defaults allow auto-discovery (now the DEFAULT behavior) to take precedence
PRIMARY_TFVARS="${PRIMARY_TFVARS:-}"
SECONDARY_TFVARS="${SECONDARY_TFVARS:-}"
# Auto-discover is now the DEFAULT behavior - set to false to disable
AUTO_DISCOVER_CLUSTERS="${AUTO_DISCOVER_CLUSTERS:-true}"

# Workspace names - derived from tfvars or set explicitly
PRIMARY_WORKSPACE="${PRIMARY_WORKSPACE:-}"
SECONDARY_WORKSPACE="${SECONDARY_WORKSPACE:-}"

# Command-line arguments for cluster selection (can be workspace name or tfvars file)
PRIMARY_ARG=""
SECONDARY_ARG=""

# Logging
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/dr-simulation-$(date +%Y%m%d-%H%M%S).log}"

# Global state for tunnels
PRIMARY_BASTION_ID=""
PRIMARY_CLUSTER_ID=""
PRIMARY_K8S_HOST=""
PRIMARY_K8S_PORT=""
PRIMARY_SESSION_ID=""
PRIMARY_TUNNEL_PID=""
PRIMARY_TUNNEL_REUSED="false"
PRIMARY_REGION=""
PRIMARY_OCI_PROFILE=""
PRIMARY_PRIVATE_KEY_PATH=""
PRIMARY_SSH_KEY_PATH=""
PRIMARY_FQDN=""
PRIMARY_HEALTH_CHECK_OCID=""
DR_FAILOVER_PRIMARY_HEALTH_CHECK_OCID=""
EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID=""
DR_FAILOVER_ALARM_OCID=""
PRIMARY_HEALTH_CHECK_ORIGINAL_PATH="/api/v1/status"  # Default path, will be read from OCI
PRIMARY_LB_OCID=""
PRIMARY_COMPARTMENT_OCID=""
LB_BACKEND_SET_NAME="${LB_BACKEND_SET_NAME:-TCP-443}"

SECONDARY_BASTION_ID=""
SECONDARY_CLUSTER_ID=""
SECONDARY_K8S_HOST=""
SECONDARY_K8S_PORT=""
SECONDARY_SESSION_ID=""
SECONDARY_TUNNEL_PID=""
SECONDARY_TUNNEL_REUSED="false"
SECONDARY_REGION=""
SECONDARY_OCI_PROFILE=""
SECONDARY_PRIVATE_KEY_PATH=""
SECONDARY_SSH_KEY_PATH=""
SECONDARY_FQDN=""
SECONDARY_BUCKET_NAME=""

# DR monitoring mode: "lb_health" or "health_check" (auto-detected from Terraform state)
DR_MONITORING_MODE="${DR_MONITORING_MODE:-}"

OCI_AUTH_FLAG="--auth api_key"

# Kubeconfig contexts (allow override via env vars, or auto-detect from cluster OCID)
# Empty defaults trigger auto-detection when --skip-tunnel-setup is used
PRIMARY_KUBE_CONTEXT="${PRIMARY_KUBE_CONTEXT:-}"
SECONDARY_KUBE_CONTEXT="${SECONDARY_KUBE_CONTEXT:-}"

# DNS / routing info (best-effort; populated from tfvars/state when available)
GLOBAL_FQDN="${GLOBAL_FQDN:-}"
PRIMARY_INGEST_LB_IP="${PRIMARY_INGEST_LB_IP:-}"
SECONDARY_INGEST_LB_IP="${SECONDARY_INGEST_LB_IP:-}"

# ============================================================================
# jq Helper Functions (compatible with both bash and zsh)
# ============================================================================
# jq_parse: Execute jq in a portable way
# Usage: jq_parse <json_string> <jq_filter> [jq_args...]
# Note: JSON string is FIRST argument, filter is SECOND (allows passing extra jq args)
jq_parse() {
    local json="$1"
    shift
    local filter="$1"
    shift
    # Use printf | jq which works in both bash and zsh
    printf '%s' "$json" | jq -r "$@" "$filter" 2>/dev/null || echo ""
}

# jq_parse_compact: Execute jq with compact output (-c flag)
# Usage: jq_parse_compact <json_string> <jq_filter>
jq_parse_compact() {
    local json="$1"
    local filter="$2"
    printf '%s' "$json" | jq -c "$filter" 2>/dev/null || echo ""
}

# retry_command: Execute a command with retries on failure
# Usage: retry_command <max_retries> <delay_seconds> <command...>
# Returns: Command exit code (0 on success, last exit code on failure)
retry_command() {
    local max_retries="$1"
    local delay="$2"
    shift 2
    local attempt=1
    local result=""
    local exit_code=1

    while [ $attempt -le $max_retries ]; do
        set +e
        result=$("$@" 2>/dev/null)
        exit_code=$?
        set -e
        if [ $exit_code -eq 0 ] && [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
        if [ $attempt -lt $max_retries ]; then
            log_debug "Command failed (attempt $attempt/$max_retries), retrying in ${delay}s..."
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done

    # Return last result even on failure (may be partial data or error)
    echo "$result"
    return $exit_code
}

# Transient outage parameters
TRANSIENT_OUTAGE_DURATION_SECONDS="${TRANSIENT_OUTAGE_DURATION_SECONDS:-60}"
TRANSIENT_OBSERVATION_SECONDS="${TRANSIENT_OBSERVATION_SECONDS:-300}"

timestamp() {
    date "+%Y-%m-%dT%H:%M:%S%z"
}

log_raw() {
    local level="$1"; shift
    local msg="$*"
    echo -e "$(timestamp) [$level] $msg" | tee -a "$LOG_FILE" >&2
}

log_info()  { log_raw "INFO " "$@"; }
log_warn()  { log_raw "WARN " "$@"; }
log_error() { log_raw "ERROR" "$@"; }
log_debug() { [ "$DEBUG" = "1" ] && log_raw "DEBUG" "$@"; }

# Terminal width for right-aligned output (default 72 for readability)
TERM_WIDTH="${TERM_WIDTH:-72}"

# print_step_line: Print a line with optional right-aligned timing
# Usage: print_step_line "Message text" ["+123s"]
# If timing is provided, it will be right-aligned at TERM_WIDTH
print_step_line() {
    local msg="$1"
    local timing="${2:-}"

    if [ -n "$timing" ]; then
        # Calculate padding for right-alignment
        # Strip ANSI codes from msg for length calculation
        local msg_plain
        msg_plain=$(echo -e "$msg" | sed 's/\x1b\[[0-9;]*m//g')
        local msg_len=${#msg_plain}
        local timing_len=${#timing}
        local total_len=$((msg_len + timing_len + 1))  # +1 for space

        if [ "$total_len" -lt "$TERM_WIDTH" ]; then
            local padding=$((TERM_WIDTH - total_len))
            printf "%s%*s%s\n" "$msg" "$padding" "" "$timing"
        else
            # Line too long, just append timing
            echo -e "$msg $timing"
        fi
    else
        echo -e "$msg"
    fi
}

# print_timed: Echo with right-aligned timing - drop-in replacement for echo
# Usage: print_timed "  [+12s] Status message"
# Extracts timing like [+12s], (+12s), or just +12s and right-aligns it
print_timed() {
    local full_msg="$*"

    # Try to extract timing pattern from the message
    # Patterns: [+123s], (+123s), +123s at the start or after ] or )
    if [[ "$full_msg" =~ ^(.*[[:space:]]|)(\[?\+[0-9]+s\]?|\(\+[0-9]+s\))(.*)$ ]]; then
        # Found timing embedded in message - extract and right-align
        local prefix="${BASH_REMATCH[1]}"
        local timing="${BASH_REMATCH[2]}"
        local suffix="${BASH_REMATCH[3]}"

        # Reconstruct message without timing, then add timing right-aligned
        local msg="${prefix}${suffix}"
        # Clean up double spaces
        msg=$(echo -e "$msg" | sed 's/  */ /g')
        print_step_line "$msg" "$timing"
    else
        # No timing found, output as-is
        echo -e "$full_msg"
    fi
}

# print_step_header: Print a step header with right-aligned elapsed time
# Usage: print_step_header "Step N: Description" start_epoch
print_step_header() {
    local header="$1"
    local start_epoch="${2:-}"
    local timing=""

    if [ -n "$start_epoch" ]; then
        local now=$(date +%s)
        local delta=$((now - start_epoch))
        timing="[${delta}s elapsed]"
    fi

    echo "────────────────────────────────────────────────────────────────────"
    print_step_line "$header" "$timing"
    echo "────────────────────────────────────────────────────────────────────"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <scenario>

Establishes bastion tunnels to both OKE clusters and runs DR failover simulations.

Scenarios:
  === Operator/Health Check Manipulation ===
  primary-down        Scale PRIMARY humio-operator to 0 + scale nginx-ingress to 0
                      Makes LB backends unhealthy (LB-preserving, IP address preserved)
                      Most realistic - monitors LB backend health via OCI Monitoring
  failover            Trigger DR failover by changing health check path to invalid endpoint
                      Health check stays ENABLED but reports UNHEALTHY (recommended)
  region-down         Trigger DR failover by disabling PRIMARY health check (absent metrics test)
                      Slowest trigger (absent window + pending duration), but validates absent() path
  transient-outage    Disable health check briefly then re-enable (anti-flap test)
                      Validates that brief outages don't trigger failover
  failback            Re-enable health check, reset secondary cluster state
                      Restores nginx-ingress, restores traffic, cleans up secondary
  status              Show current status of both clusters

  === DNS Validation ===
  dns-failover-check  Show DNS steering status for global hostname (read-only)
                      Validates DNS resolution and steering policy

  === Ingestion Failure Simulations ===
  logscale-crash      Crash LogScale process on PRIMARY (fastest DR trigger ~3-4 min)
                      Monitors LB backend health via OCI Monitoring metrics
                      Modes: --mode=kill-process (default), block-health, oom
  storage-failure     Block Object Storage access (triggers queue backup ~7-12 min)
                      Applies NetworkPolicy to block OCI Object Storage endpoints

Options:
  --mode MODE               Crash mode for logscale-crash (kill-process|block-health|oom)
  --primary NAME            Primary cluster (workspace name like 'single' or tfvars file)
  --secondary NAME          Secondary cluster (workspace name like 'secondary' or tfvars file)
  --no-auto-discover        Disable auto-discovery (requires explicit --primary/--secondary)
  --tfvars-primary FILE     [DEPRECATED] Use --primary instead
  --tfvars-secondary FILE   [DEPRECATED] Use --secondary instead
  --skip-tunnel-setup       Skip bastion tunnel setup (use existing contexts)
  --debug                   Enable debug logging
  -h, --help                Show this help message

Cluster Selection:
  By default, the script auto-discovers DR cluster pairs by scanning *.tfvars files
  for dr="active" (primary) and dr="standby" (secondary). If multiple clusters have
  the same DR mode, a warning is displayed and the first one found is used.

  To use specific clusters, provide workspace names or tfvars files:
    --primary primary --secondary secondary          (workspace names)
    --primary primary-us-chicago-1.tfvars --secondary secondary-us-chicago-1.tfvars  (tfvars files)

Environment Variables:
  PRIMARY_TFVARS            Primary cluster tfvars file (alternative to --primary)
  SECONDARY_TFVARS          Secondary cluster tfvars file (alternative to --secondary)
  AUTO_DISCOVER_CLUSTERS    Set to "false" to disable auto-discovery (default: true)
  PRIMARY_WORKSPACE         Override primary workspace name (rarely needed)
  SECONDARY_WORKSPACE       Override secondary workspace name (rarely needed)
  PRIMARY_LOCAL_PORT        Local port for primary K8s API (default: 6443)
  SECONDARY_LOCAL_PORT      Local port for secondary K8s API (default: 6444)
  FAILOVER_TIMEOUT_SECONDS  Timeout for failover tracking (default: 600)
  NAMESPACE                 Kubernetes namespace (default: logging)
  PRIMARY_KUBE_CONTEXT      kubectl context name for primary (default: oci-primary)
  SECONDARY_KUBE_CONTEXT    kubectl context name for secondary (default: oci-secondary)
  GLOBAL_FQDN               Global LogScale hostname for DNS steering checks
  TRANSIENT_OUTAGE_DURATION_SECONDS   transient-outage disable duration (default: 60)
  TRANSIENT_OBSERVATION_SECONDS       transient-outage observation window (default: 300)
  LB_BACKEND_SET_NAME       OCI Load Balancer backend set name (default: TCP-443)
  DEBUG                     Enable debug logging (1 or 0)

Examples:
  # Simulate PRIMARY failure (auto-discovers clusters from tfvars)
  ./test/simulate-oci-dr-failover.sh primary-down

  # Skip tunnel setup (use existing kubectl contexts from kubeconfig-dr.yaml)
  ./test/simulate-oci-dr-failover.sh --skip-tunnel-setup primary-down

  # Trigger failover via health check manipulation (non-invasive)
  ./test/simulate-oci-dr-failover.sh failover

  # Test absent metrics path (disables health check entirely)
  ./test/simulate-oci-dr-failover.sh --skip-tunnel-setup region-down

  # Validate anti-flap behavior (brief outage should not trigger DR)
  ./test/simulate-oci-dr-failover.sh transient-outage

  # Check DNS steering status (read-only)
  ./test/simulate-oci-dr-failover.sh dns-failover-check

  # Crash LogScale process (fastest DR test)
  ./test/simulate-oci-dr-failover.sh logscale-crash

  # Crash with specific mode
  ./test/simulate-oci-dr-failover.sh --mode=block-health logscale-crash

  # Block Object Storage access
  ./test/simulate-oci-dr-failover.sh storage-failure

  # Check status only (quick check with existing tunnels)
  ./test/simulate-oci-dr-failover.sh --skip-tunnel-setup status

  # Restore after any failover test (handles all cleanup)
  ./test/simulate-oci-dr-failover.sh --skip-tunnel-setup failback

  # Use specific clusters by workspace name (recommended)
  ./test/simulate-oci-dr-failover.sh --primary primary --secondary secondary status

  # Use specific clusters by tfvars file
  ./test/simulate-oci-dr-failover.sh --primary primary-us-chicago-1.tfvars --secondary secondary-us-chicago-1.tfvars status

  # Use environment variables for cluster selection
  PRIMARY_TFVARS=primary-us-chicago-1.tfvars SECONDARY_TFVARS=secondary-us-chicago-1.tfvars ./test/simulate-oci-dr-failover.sh status

Notes:
  - By default, clusters are auto-discovered from *.tfvars files (dr="active" / dr="standby")
  - Use --skip-tunnel-setup when you already have bastion tunnels running
  - The script reads Terraform state to get health check and alarm OCIDs
  - Ensure KUBECONFIG points to kubeconfig-dr.yaml for existing contexts
EOF
}

# Parse arguments
SCENARIO=""
SKIP_TUNNEL_SETUP=false
CRASH_MODE="kill-process"  # Default crash mode for logscale-crash

while [ $# -gt 0 ]; do
    case "$1" in
        --primary)
            [ $# -lt 2 ] && { echo -e "${RED}Error: --primary requires a workspace name or tfvars file${NC}" >&2; exit 1; }
            PRIMARY_ARG="$2"; shift 2 ;;
        --primary=*)
            PRIMARY_ARG="${1#*=}"; shift ;;
        --secondary)
            [ $# -lt 2 ] && { echo -e "${RED}Error: --secondary requires a workspace name or tfvars file${NC}" >&2; exit 1; }
            SECONDARY_ARG="$2"; shift 2 ;;
        --secondary=*)
            SECONDARY_ARG="${1#*=}"; shift ;;
        --auto-discover)
            AUTO_DISCOVER_CLUSTERS=true; shift ;;
        --no-auto-discover)
            AUTO_DISCOVER_CLUSTERS=false; shift ;;
        --tfvars-primary)
            [ $# -lt 2 ] && { echo -e "${RED}Error: --tfvars-primary requires a value${NC}" >&2; exit 1; }
            PRIMARY_TFVARS="$2"; shift 2 ;;
        --tfvars-primary=*)
            PRIMARY_TFVARS="${1#*=}"; shift ;;
        --tfvars-secondary)
            [ $# -lt 2 ] && { echo -e "${RED}Error: --tfvars-secondary requires a value${NC}" >&2; exit 1; }
            SECONDARY_TFVARS="$2"; shift 2 ;;
        --tfvars-secondary=*)
            SECONDARY_TFVARS="${1#*=}"; shift ;;
        --mode)
            [ $# -lt 2 ] && { echo -e "${RED}Error: --mode requires a value${NC}" >&2; exit 1; }
            CRASH_MODE="$2"; shift 2 ;;
        --mode=*)
            CRASH_MODE="${1#*=}"; shift ;;
        --skip-tunnel-setup)
            SKIP_TUNNEL_SETUP=true; shift ;;
        --debug)
            DEBUG=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        primary-down|failover|region-down|transient-outage|dns-failover-check|failback|status|logscale-crash|storage-failure)
            SCENARIO="$1"; shift ;;
        *)
            echo -e "${RED}Error: Unknown option or scenario: $1${NC}" >&2
            usage; exit 1 ;;
    esac
done

[ -z "$SCENARIO" ] && { echo -e "${RED}Error: No scenario specified${NC}" >&2; usage; exit 1; }

cd "$ROOT_DIR"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           OCI DR FAILOVER SIMULATION                               ║${NC}"
echo -e "${BLUE}║           Scenario: $SCENARIO                                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Helper Functions
# ============================================================================

read_tfvar() {
    local key="$1" file="$2"
    [ -z "$file" ] || [ ! -f "$file" ] && return 0
    local line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n1 || true)
    [ -z "$line" ] && return 0
    line="${line#*=}"; line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    line="${line%\"}"; line="${line#\"}"; line="${line%\'}"; line="${line#\'}"
    echo "$line"
}

# ============================================================================
# Kubeconfig Context Discovery Functions
# ============================================================================

discover_kube_context_for_cluster() {
    # Discovers the kubectl context name for a given OCI cluster OCID.
    # Searches through all contexts in the current kubeconfig and matches by:
    #   1. Context name containing OCID suffix
    #   2. Cluster name containing OCID suffix
    #   3. User exec args containing the full cluster OCID
    #
    # Arguments:
    #   $1 - cluster_ocid: Full OCI cluster OCID
    #
    # Returns:
    #   Context name (stdout) if found, empty string if not found
    #   Exit code 0 on success, 1 on failure
    #
    # Example:
    #   cluster_ocid="ocid1.cluster.oc1.us-chicago-1.aaaaaaaexampleexampleexampleexampleexample"
    #   context=$(discover_kube_context_for_cluster "$cluster_ocid")
    #   # Returns: "context-cvwxa22lm2q" or "oci-single" (depending on kubeconfig)

    local cluster_ocid="$1"

    if [ -z "$cluster_ocid" ] || [ "$cluster_ocid" = "null" ]; then
        log_debug "discover_kube_context_for_cluster: No cluster OCID provided"
        return 1
    fi

    # Extract the unique suffix from the cluster OCID (after the last dot in the last segment)
    # OCID format: ocid1.cluster.oc1.<region>.<unique-id>
    # We want the last 11 characters which form the unique identifier used in context names
    local ocid_suffix="${cluster_ocid##*.}"  # Get everything after last dot
    ocid_suffix="${ocid_suffix: -11}"        # Take last 11 characters

    log_debug "Looking for kubectl context matching cluster OCID: $cluster_ocid (suffix: $ocid_suffix)"

    # Get all context names from kubeconfig
    local contexts
    contexts=$(kubectl config get-contexts -o name 2>/dev/null || echo "")

    if [ -z "$contexts" ]; then
        log_debug "No kubectl contexts found in kubeconfig"
        return 1
    fi

    # Search for a context that matches the cluster OCID
    local context_name
    while IFS= read -r context_name; do
        [ -z "$context_name" ] && continue

        # Method 1: Check if context name contains the OCID suffix
        if [[ "$context_name" == *"$ocid_suffix"* ]]; then
            log_debug "Found matching context by name: $context_name (matches suffix: $ocid_suffix)"
            echo "$context_name"
            return 0
        fi

        # Method 2: Check the cluster name in the context (for renamed contexts)
        local cluster_name
        cluster_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$context_name\")].context.cluster}" 2>/dev/null || echo "")
        if [ -n "$cluster_name" ] && [[ "$cluster_name" == *"$ocid_suffix"* ]]; then
            log_debug "Found matching context via cluster name: $context_name (cluster: $cluster_name)"
            echo "$context_name"
            return 0
        fi

        # Method 3: Check user exec args for the full cluster OCID
        # This handles kubeconfigs with user-friendly names (e.g., oci-single, oci-secondary)
        # where the OCID is in the exec command args: --cluster-id <ocid>
        local user_name
        user_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$context_name\")].context.user}" 2>/dev/null || echo "")
        if [ -n "$user_name" ]; then
            # Get all exec args for this user and check if any contains the cluster OCID
            local exec_args
            exec_args=$(kubectl config view -o jsonpath="{.users[?(@.name==\"$user_name\")].user.exec.args[*]}" 2>/dev/null || echo "")
            if [ -n "$exec_args" ] && [[ "$exec_args" == *"$cluster_ocid"* ]]; then
                log_debug "Found matching context via user exec args: $context_name (user: $user_name)"
                echo "$context_name"
                return 0
            fi
        fi
    done <<< "$contexts"

    log_debug "No kubectl context found matching cluster OCID: $cluster_ocid"
    return 1
}

# ============================================================================
# Cluster Discovery Functions
# ============================================================================

find_tfvars_for_workspace() {
    # Finds the tfvars file for a given workspace name
    # Searches all *.tfvars files for workspace_name = "<name>"
    local target_workspace="$1"
    local search_dir="${2:-$ROOT_DIR}"

    for tfvars_file in "$search_dir"/*.tfvars; do
        [ ! -f "$tfvars_file" ] && continue

        local workspace_name=$(grep -E "^[[:space:]]*workspace_name[[:space:]]*=" "$tfvars_file" 2>/dev/null | tail -n1 | sed 's/.*=//;s/[[:space:]]*//g;s/"//g')

        if [ "$workspace_name" = "$target_workspace" ]; then
            echo "$tfvars_file"
            return 0
        fi
    done

    return 1
}

get_workspace_from_tfvars() {
    # Extracts the workspace_name from a tfvars file
    # Falls back to inferring from filename if workspace_name not set
    local tfvars_file="$1"

    local workspace_name=$(read_tfvar "workspace_name" "$tfvars_file")
    workspace_name="${workspace_name//\"/}"  # Remove quotes

    if [ -z "$workspace_name" ]; then
        # Infer from filename: primary-us-chicago-1.tfvars -> primary
        workspace_name=$(basename "$tfvars_file" .tfvars | cut -d'-' -f1)
    fi

    echo "$workspace_name"
}

discover_dr_cluster_pair() {
    # Discovers primary (dr="active") and secondary (dr="standby") clusters
    # from tfvars files in the root directory.
    #
    # Sets global variables:
    #   DISCOVERED_PRIMARY_TFVARS
    #   DISCOVERED_SECONDARY_TFVARS
    #   DISCOVERED_PRIMARY_WORKSPACE
    #   DISCOVERED_SECONDARY_WORKSPACE
    #
    # Returns 0 on success, 1 if no valid pair found

    local search_dir="${1:-$ROOT_DIR}"
    local found_primary=""
    local found_secondary=""
    local found_primary_workspace=""
    local found_secondary_workspace=""
    local multiple_active=()
    local multiple_standby=()

    log_info "Auto-discovering DR cluster pair from tfvars files..."

    # Find all tfvars files
    for tfvars_file in "$search_dir"/*.tfvars; do
        [ ! -f "$tfvars_file" ] && continue

        local dr_mode=$(read_tfvar "dr" "$tfvars_file")
        local workspace_name=$(read_tfvar "workspace_name" "$tfvars_file")

        # Skip files without DR configuration
        [ -z "$dr_mode" ] && continue

        case "$dr_mode" in
            active|\"active\")
                if [ -n "$found_primary" ]; then
                    multiple_active+=("$tfvars_file")
                else
                    found_primary="$tfvars_file"
                    found_primary_workspace="${workspace_name//\"/}"
                    log_debug "Found primary (active): $tfvars_file (workspace: $found_primary_workspace)"
                fi
                ;;
            standby|\"standby\")
                if [ -n "$found_secondary" ]; then
                    multiple_standby+=("$tfvars_file")
                else
                    found_secondary="$tfvars_file"
                    found_secondary_workspace="${workspace_name//\"/}"
                    log_debug "Found secondary (standby): $tfvars_file (workspace: $found_secondary_workspace)"
                fi
                ;;
        esac
    done

    # Warn about multiple active clusters
    if [ ${#multiple_active[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  WARNING: Multiple clusters with dr=\"active\" found!               ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}"
        echo -e "${YELLOW}  Using:    $found_primary${NC}"
        for extra in "${multiple_active[@]}"; do
            echo -e "${YELLOW}  Also found: $extra${NC}"
        done
        echo ""
        echo -e "${YELLOW}  To use a specific cluster pair, specify explicitly:${NC}"
        echo -e "${CYAN}    ./test/simulate-oci-dr-failover-v2.sh --primary <file.tfvars> --secondary <file.tfvars> <scenario>${NC}"
        echo ""
    fi

    # Warn about multiple standby clusters
    if [ ${#multiple_standby[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  WARNING: Multiple clusters with dr=\"standby\" found!              ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}"
        echo -e "${YELLOW}  Using:    $found_secondary${NC}"
        for extra in "${multiple_standby[@]}"; do
            echo -e "${YELLOW}  Also found: $extra${NC}"
        done
        echo ""
        echo -e "${YELLOW}  To use a specific cluster pair, specify explicitly:${NC}"
        echo -e "${CYAN}    ./test/simulate-oci-dr-failover-v2.sh --primary <file.tfvars> --secondary <file.tfvars> <scenario>${NC}"
        echo ""
    fi

    # Validate we found a complete pair
    if [ -z "$found_primary" ]; then
        log_error "No primary cluster found (dr=\"active\" in tfvars)"
        return 1
    fi
    if [ -z "$found_secondary" ]; then
        log_error "No secondary cluster found (dr=\"standby\" in tfvars)"
        return 1
    fi

    # Export discovered values
    DISCOVERED_PRIMARY_TFVARS="$found_primary"
    DISCOVERED_SECONDARY_TFVARS="$found_secondary"
    DISCOVERED_PRIMARY_WORKSPACE="$found_primary_workspace"
    DISCOVERED_SECONDARY_WORKSPACE="$found_secondary_workspace"

    log_info "Discovered DR pair:"
    log_info "  Primary:   $found_primary (workspace: $found_primary_workspace)"
    log_info "  Secondary: $found_secondary (workspace: $found_secondary_workspace)"

    return 0
}

validate_dr_modes() {
    # Validates that primary is "active" and secondary is "standby"
    local primary_dr=$(read_tfvar "dr" "$PRIMARY_TFVARS")
    local secondary_dr=$(read_tfvar "dr" "$SECONDARY_TFVARS")

    # Remove quotes if present
    primary_dr="${primary_dr//\"/}"
    secondary_dr="${secondary_dr//\"/}"

    local valid=true

    if [ "$primary_dr" != "active" ]; then
        log_warn "Primary cluster ($PRIMARY_TFVARS) has dr=\"$primary_dr\" (expected \"active\")"
        valid=false
    fi

    if [ "$secondary_dr" != "standby" ]; then
        log_warn "Secondary cluster ($SECONDARY_TFVARS) has dr=\"$secondary_dr\" (expected \"standby\")"
        valid=false
    fi

    if [ "$valid" = "false" ]; then
        echo -e "${YELLOW}WARNING: DR mode mismatch detected. Simulation may not work as expected.${NC}"
        echo -e "${YELLOW}         Ensure primary has dr=\"active\" and secondary has dr=\"standby\"${NC}"
        echo ""
        # Don't fail - just warn (user may know what they're doing)
    fi

    return 0
}

resolve_cluster_pair() {
    # Resolves PRIMARY_TFVARS, SECONDARY_TFVARS, PRIMARY_WORKSPACE, SECONDARY_WORKSPACE
    # Priority: 1) Explicit params (workspace name or tfvars file), 2) Auto-discover (DEFAULT)

    # Helper function to resolve argument to tfvars file
    resolve_arg_to_tfvars() {
        local arg="$1"
        local role="$2"  # "primary" or "secondary"

        # If arg ends with .tfvars, treat as file path
        if [[ "$arg" == *.tfvars ]]; then
            if [ -f "$arg" ]; then
                echo "$arg"
                return 0
            else
                log_error "$role tfvars file not found: $arg"
                return 1
            fi
        fi

        # Otherwise, treat as workspace name - find matching tfvars
        local tfvars_file
        tfvars_file=$(find_tfvars_for_workspace "$arg" "$ROOT_DIR")
        if [ -n "$tfvars_file" ]; then
            log_debug "Resolved workspace '$arg' to tfvars: $tfvars_file"
            echo "$tfvars_file"
            return 0
        else
            log_error "No tfvars file found for workspace: $arg"
            echo -e "${YELLOW}Available workspaces:${NC}" >&2
            for f in "$ROOT_DIR"/*.tfvars; do
                [ -f "$f" ] || continue
                local ws=$(grep -E "^[[:space:]]*workspace_name[[:space:]]*=" "$f" 2>/dev/null | tail -n1 | sed 's/.*=//;s/[[:space:]]*//g;s/"//g')
                [ -n "$ws" ] && echo "  $ws ($(basename "$f"))" >&2
            done
            return 1
        fi
    }

    # Mode 1: Explicit parameters provided (via --primary/--secondary args)
    if [ -n "${PRIMARY_ARG:-}" ] && [ -n "${SECONDARY_ARG:-}" ]; then
        log_info "Using explicitly specified cluster pair"

        # Resolve primary
        PRIMARY_TFVARS=$(resolve_arg_to_tfvars "$PRIMARY_ARG" "Primary") || return 1
        PRIMARY_WORKSPACE=$(get_workspace_from_tfvars "$PRIMARY_TFVARS")

        # Resolve secondary
        SECONDARY_TFVARS=$(resolve_arg_to_tfvars "$SECONDARY_ARG" "Secondary") || return 1
        SECONDARY_WORKSPACE=$(get_workspace_from_tfvars "$SECONDARY_TFVARS")

        # Validate DR modes
        validate_dr_modes

        return 0
    fi

    # Check if only one was provided (error case)
    if [ -n "${PRIMARY_ARG:-}" ] || [ -n "${SECONDARY_ARG:-}" ]; then
        log_error "Both --primary and --secondary must be specified together"
        return 1
    fi

    # Mode 2: Auto-discovery (DEFAULT behavior)
    # Auto-discover looks for dr="active" and dr="standby" in tfvars files
    if [ "$AUTO_DISCOVER_CLUSTERS" = "true" ]; then
        if discover_dr_cluster_pair "$ROOT_DIR"; then
            PRIMARY_TFVARS="$DISCOVERED_PRIMARY_TFVARS"
            SECONDARY_TFVARS="$DISCOVERED_SECONDARY_TFVARS"
            PRIMARY_WORKSPACE="$DISCOVERED_PRIMARY_WORKSPACE"
            SECONDARY_WORKSPACE="$DISCOVERED_SECONDARY_WORKSPACE"
            return 0
        else
            log_error "Auto-discovery failed. Use --primary and --secondary to specify clusters explicitly."
            echo ""
            echo -e "${YELLOW}Example (using workspace names):${NC}"
            echo -e "${CYAN}  ./test/simulate-oci-dr-failover-v2.sh --primary primary --secondary secondary status${NC}"
            echo ""
            echo -e "${YELLOW}Example (using tfvars files):${NC}"
            echo -e "${CYAN}  ./test/simulate-oci-dr-failover-v2.sh --primary primary-us-chicago-1.tfvars --secondary secondary-us-chicago-1.tfvars status${NC}"
            return 1
        fi
    fi

    # Auto-discover is disabled - require explicit parameters
    log_error "No cluster pair specified and auto-discovery is disabled."
    echo -e "${YELLOW}Use --primary and --secondary to specify clusters, or set AUTO_DISCOVER_CLUSTERS=true${NC}"
    return 1
}

epoch_to_iso() {
    local epoch="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$epoch"
    else
        date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$epoch"
    fi
}

ensure_ssh_config() {
    local ssh_config_file="$HOME/.ssh/config"
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    if [ ! -f "$ssh_config_file" ] || ! grep -q "HostKeyAlgorithms.*ssh-rsa" "$ssh_config_file" 2>/dev/null; then
        log_debug "Adding OCI Bastion compatibility settings to SSH config"
        cat >> "$ssh_config_file" <<EOF

# OCI Bastion Service compatibility settings
Host *.oci.oraclecloud.com
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedKeyTypes +ssh-rsa
    ServerAliveInterval 30
    ServerAliveCountMax 5
    TCPKeepAlive yes

EOF
        chmod 600 "$ssh_config_file"
    fi
}

# ============================================================================
# Bastion Tunnel Functions
# ============================================================================

extract_cluster_config() {
    local workspace="$1" tfvars_file="$2" prefix="$3"
    log_info "Extracting configuration for $prefix cluster (workspace: $workspace)..."

    terraform workspace select "$workspace" >/dev/null 2>&1 || {
        echo -e "${RED}Error: Failed to select Terraform workspace '$workspace'${NC}" >&2; return 1
    }

    local bastion_id=$(terraform output -raw bastion_service_id 2>/dev/null || echo "")
    [ -z "$bastion_id" ] || [ "$bastion_id" = "null" ] && {
        echo -e "${RED}Error: No bastion_service_id found for $prefix cluster${NC}" >&2; return 1
    }

    local cluster_id=$(terraform output -raw cluster_id 2>/dev/null || echo "")
    local region=$(terraform output -raw region 2>/dev/null || read_tfvar region "$tfvars_file")
    local oci_profile=$(terraform output -raw oci_profile_used 2>/dev/null || read_tfvar config_file_profile "$tfvars_file")
    local ssh_key_path=$(terraform output -raw ssh_public_key_path 2>/dev/null || read_tfvar ssh_public_key_path "$tfvars_file")
    local cluster_details=$(terraform output -json cluster_endpoint_details 2>/dev/null || echo "{}")
    local endpoint=$(echo "$cluster_details" | jq -r '.private_endpoint // .kubernetes_endpoint // empty')

    [ -z "$oci_profile" ] && oci_profile="DEFAULT"
    [ -z "$ssh_key_path" ] && ssh_key_path="~/.ssh/id_ed25519.pub"
    ssh_key_path=$(eval echo "$ssh_key_path")

    # Derive private key path from public key path
    local private_key_path
    if [[ "$ssh_key_path" == *"_public.pem" ]]; then
        private_key_path="${ssh_key_path/_public.pem/.pem}"
    elif [[ "$ssh_key_path" == *".pub" ]]; then
        private_key_path="${ssh_key_path%.pub}"
    else
        private_key_path="${ssh_key_path%.*}"
    fi

    # Verify keys exist and match
    if [ ! -f "$ssh_key_path" ]; then
        echo -e "${YELLOW}Warning: SSH public key not found: $ssh_key_path${NC}"
    fi
    if [ ! -f "$private_key_path" ]; then
        echo -e "${YELLOW}Warning: SSH private key not found: $private_key_path${NC}"
    fi

    # Debug: show key fingerprints to verify they match
    log_debug "SSH public key path: $ssh_key_path"
    log_debug "SSH private key path: $private_key_path"
    if [ -f "$ssh_key_path" ] && [ -f "$private_key_path" ]; then
        local pub_fp=$(ssh-keygen -lf "$ssh_key_path" 2>/dev/null | awk '{print $2}')
        local priv_fp=$(ssh-keygen -lf "$private_key_path" 2>/dev/null | awk '{print $2}')
        log_debug "Public key fingerprint: $pub_fp"
        log_debug "Private key fingerprint: $priv_fp"
        if [ "$pub_fp" != "$priv_fp" ]; then
            echo -e "${RED}Error: SSH key pair mismatch! Public and private keys do not match.${NC}" >&2
            echo -e "${RED}  Public key ($ssh_key_path): $pub_fp${NC}" >&2
            echo -e "${RED}  Private key ($private_key_path): $priv_fp${NC}" >&2
            return 1
        fi
    fi

    [ -z "$endpoint" ] || [ "$endpoint" = "null" ] && {
        echo -e "${RED}Error: Could not get Kubernetes endpoint for $prefix cluster${NC}" >&2; return 1
    }

    local k8s_host=$(echo "$endpoint" | cut -d':' -f1)
    local k8s_port=$(echo "$endpoint" | cut -d':' -f2)

    # Get additional info for simulation
    local fqdn=$(read_tfvar "logscale_public_fqdn" "$tfvars_file" || echo "")

    if [ "$prefix" = "PRIMARY" ]; then
        PRIMARY_BASTION_ID="$bastion_id"; PRIMARY_CLUSTER_ID="$cluster_id"
        PRIMARY_REGION="$region"; PRIMARY_OCI_PROFILE="$oci_profile"
        PRIMARY_SSH_KEY_PATH="$ssh_key_path"; PRIMARY_PRIVATE_KEY_PATH="$private_key_path"
        PRIMARY_K8S_HOST="$k8s_host"; PRIMARY_K8S_PORT="$k8s_port"
        PRIMARY_FQDN="$fqdn"
        PRIMARY_HEALTH_CHECK_OCID=$(terraform output -raw primary_health_check_id 2>/dev/null || echo "")
        PRIMARY_LB_OCID=$(terraform output -raw primary_ingest_lb_ocid 2>/dev/null || echo "")
        PRIMARY_COMPARTMENT_OCID=$(terraform output -raw compartment_ocid 2>/dev/null || echo "")
    else
        SECONDARY_BASTION_ID="$bastion_id"; SECONDARY_CLUSTER_ID="$cluster_id"
        SECONDARY_REGION="$region"; SECONDARY_OCI_PROFILE="$oci_profile"
        SECONDARY_SSH_KEY_PATH="$ssh_key_path"; SECONDARY_PRIVATE_KEY_PATH="$private_key_path"
        SECONDARY_K8S_HOST="$k8s_host"; SECONDARY_K8S_PORT="$k8s_port"
        SECONDARY_FQDN="$fqdn"
        SECONDARY_BUCKET_NAME=$(terraform output -raw storage_bucket_name 2>/dev/null || echo "")
        DR_FAILOVER_PRIMARY_HEALTH_CHECK_OCID=$(terraform output -raw dr_failover_primary_health_check_id 2>/dev/null || echo "")
        DR_MONITORING_MODE=$(terraform output -raw dr_monitoring_mode 2>/dev/null || echo "")
    fi

    echo -e "${GREEN}$prefix cluster configuration loaded:${NC}"
    echo "  Bastion ID: $bastion_id"
    echo "  Cluster ID: $cluster_id"
    echo "  Region: $region"
    echo "  K8s API: $k8s_host:$k8s_port"
    echo "  SSH Key: $private_key_path"
}

create_port_forward_session() {
    local bastion_id="$1" target_ip="$2" target_port="$3" display_name="$4"
    local oci_profile="$5" ssh_key_path="$6" private_key_path="$7"

    log_debug "Creating PORT_FORWARDING session to ${target_ip}:${target_port}"
    log_debug "SSH public key path: $ssh_key_path"
    log_debug "SSH private key path: $private_key_path"

    # Get the public key - prefer reading from .pub file since keys have no passphrase
    local ssh_key_content=""

    # First try reading the public key file directly (most reliable for no-passphrase keys)
    if [ -f "$ssh_key_path" ]; then
        ssh_key_content=$(cat "$ssh_key_path" 2>/dev/null || echo "")
        log_debug "Read public key from file: $ssh_key_path"
    fi

    # Fallback: derive from private key if public key file doesn't exist
    if [ -z "$ssh_key_content" ] && [ -f "$private_key_path" ]; then
        ssh_key_content=$(ssh-keygen -y -f "$private_key_path" 2>/dev/null || echo "")
        log_debug "Derived public key from private key"
    fi

    [ -z "$ssh_key_content" ] && { echo -e "${RED}Error: Cannot extract OpenSSH format public key${NC}" >&2; return 1; }
    echo "$ssh_key_content" | grep -qE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-)' || {
        echo -e "${RED}Error: Extracted key is not in valid OpenSSH format${NC}" >&2; return 1
    }

    log_debug "Public key to upload: ${ssh_key_content:0:50}..."

    local temp_key_file=$(mktemp)
    echo "$ssh_key_content" > "$temp_key_file"

    set +e
    local session_output=$(oci bastion session create-port-forwarding \
        --bastion-id "$bastion_id" --target-private-ip "$target_ip" --target-port "$target_port" \
        --ssh-public-key-file "$temp_key_file" --session-ttl "$SESSION_DURATION" \
        --display-name "$display_name" --output json --profile "$oci_profile" $OCI_AUTH_FLAG 2>/dev/null)
    local create_result=$?
    rm -f "$temp_key_file"
    set -e

    [ $create_result -ne 0 ] || [ -z "$session_output" ] && {
        echo -e "${RED}Error: Failed to create bastion session${NC}" >&2; return 1
    }
    echo "$session_output" | jq -r '.data.id'
}

wait_for_session_active() {
    local session_id="$1" oci_profile="$2"
    local max_attempts=24 attempt=0
    while [ $attempt -lt $max_attempts ]; do
        set +e
        local session_status=$(oci bastion session get --session-id "$session_id" \
            --profile "$oci_profile" $OCI_AUTH_FLAG --output json 2>/dev/null)
        set -e
        local current_state=$(echo "$session_status" | jq -r '.data."lifecycle-state" // "UNKNOWN"')
        echo "  Session status check $((attempt+1))/$max_attempts: $current_state"
        [ "$current_state" = "ACTIVE" ] && { echo -e "${GREEN}  Session is now active${NC}"; return 0; }
        [ "$current_state" = "FAILED" ] || [ "$current_state" = "TERMINATED" ] && {
            echo -e "${RED}  Error: Session entered terminal state: $current_state${NC}" >&2; return 1
        }
        attempt=$((attempt+1)); sleep 10
    done
    echo -e "${RED}Error: Session did not become active within timeout${NC}" >&2; return 1
}

start_tunnel() {
    local session_id="$1" region="$2" private_key_path="$3" local_port="$4"
    local target_host="$5" target_port="$6" ssh_key_path="$7" tunnel_name="$8"

    echo -e "${BLUE}Starting $tunnel_name tunnel (127.0.0.1:$local_port -> $target_host:$target_port)...${NC}" >&2

    # Check if port is already in use
    local existing_pid=$(lsof -ti "tcp:${local_port}" 2>/dev/null | head -1)
    if [ -n "$existing_pid" ]; then
        # Check if it's an existing SSH tunnel to the same target
        local existing_cmd=$(ps -p "$existing_pid" -o args= 2>/dev/null || echo "")
        local expected_forward_with_addr="127.0.0.1:${local_port}:${target_host}:${target_port}"
        local expected_forward_no_addr="${local_port}:${target_host}:${target_port}"
        if echo "$existing_cmd" | grep -q "ssh" && \
           { echo "$existing_cmd" | grep -qF "$expected_forward_with_addr" || echo "$existing_cmd" | grep -qF "$expected_forward_no_addr"; }; then
            echo -e "${YELLOW}  Port $local_port already in use by existing SSH tunnel (PID: $existing_pid)${NC}" >&2
            echo -e "${GREEN}  Reusing existing tunnel (matches ${target_host}:${target_port} on local port $local_port)${NC}" >&2
            case "$tunnel_name" in
                PRIMARY) PRIMARY_TUNNEL_REUSED="true" ;;
                SECONDARY) SECONDARY_TUNNEL_REUSED="true" ;;
            esac
            echo "$existing_pid"
            return 0
        else
            echo -e "${RED}Error: Port $local_port already in use by another process (PID: $existing_pid)${NC}" >&2
            echo -e "${RED}  Process: $existing_cmd${NC}" >&2
            echo -e "${YELLOW}  Expected SSH tunnel forward: $expected_forward_with_addr (or $expected_forward_no_addr)${NC}" >&2
            echo -e "${YELLOW}  Kill it with: kill $existing_pid${NC}" >&2
            return 1
        fi
    fi

    case "$tunnel_name" in
        PRIMARY) PRIMARY_TUNNEL_REUSED="false" ;;
        SECONDARY) SECONDARY_TUNNEL_REUSED="false" ;;
    esac

    local key_type_options=(
        -o HostKeyAlgorithms=+ssh-rsa
        -o PubkeyAcceptedKeyTypes=+ssh-rsa
    )
    if [[ "$private_key_path" == *"ed25519"* ]]; then
        key_type_options=(
            -o HostKeyAlgorithms=+ssh-rsa,ssh-ed25519
            -o PubkeyAcceptedKeyTypes=+ssh-rsa,ssh-ed25519
        )
    fi

    local bastion_host="host.bastion.${region}.oci.oraclecloud.com"

    # Use -f to fork to background after authentication, -N for no remote command
    # IdentitiesOnly=yes and IdentityAgent=none ensure ONLY the specified key is used
    local ssh_args=(
        -f
        -i "$private_key_path"
        -L "127.0.0.1:${local_port}:${target_host}:${target_port}"
        -o IdentitiesOnly=yes
        -o IdentityAgent=none
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=5
        -o ConnectTimeout=15
        -o ExitOnForwardFailure=yes
        "${key_type_options[@]}"
        -o TCPKeepAlive=yes
        -o BatchMode=yes
        -o LogLevel=ERROR
        -o PasswordAuthentication=no
        -o KbdInteractiveAuthentication=no
        -o PreferredAuthentications=publickey
        -4
        -N
        -p 22
        "${session_id}@${bastion_host}"
    )

    if [ "$DEBUG" = "1" ]; then
        local ssh_cmd_preview
        ssh_cmd_preview=$(printf '%q ' ssh "${ssh_args[@]}")
        log_debug "SSH command: $ssh_cmd_preview"
    fi

    # Retry SSH connection up to 3 times with delay
    local max_retries=3
    local retry_delay=5
    local attempt=1
    local ssh_result=1
    local ssh_output=""

    while [ $attempt -le $max_retries ]; do
        if [ $attempt -gt 1 ]; then
            echo -e "${YELLOW}  Retry $attempt/$max_retries after ${retry_delay}s delay...${NC}" >&2
            sleep "$retry_delay"
        fi

        ssh_output=""
        set +e
        ssh_output=$(ssh "${ssh_args[@]}" 2>&1)
        ssh_result=$?
        set -e

        if [ $ssh_result -eq 0 ]; then
            break
        fi

        log_debug "SSH attempt $attempt failed with exit code $ssh_result"
        [ -n "$ssh_output" ] && log_debug "SSH error output: ${ssh_output:0:200}"
        attempt=$((attempt + 1))
    done

    if [ $ssh_result -ne 0 ]; then
        echo -e "${RED}Error: $tunnel_name tunnel failed to start after $max_retries attempts (exit code: $ssh_result)${NC}" >&2
        [ -n "$ssh_output" ] && echo "$ssh_output" >&2
        return 1
    fi

    # Find the backgrounded SSH process by matching the local port
    sleep 2
    local tunnel_pid=""
    tunnel_pid=$(lsof -ti "tcp:${local_port}" 2>/dev/null | head -1 || true)
    if [ -z "$tunnel_pid" ]; then
        tunnel_pid=$(pgrep -f "ssh.*-L.*127.0.0.1:${local_port}:" 2>/dev/null | head -1 || true)
    fi

    if [ -z "$tunnel_pid" ]; then
        echo -e "${RED}Error: $tunnel_name tunnel process not found${NC}" >&2
        return 1
    fi

    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
        echo -e "${RED}Error: $tunnel_name tunnel process died immediately${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}$tunnel_name tunnel established (PID: $tunnel_pid, background)${NC}" >&2
    echo "$tunnel_pid"
}

configure_kubeconfig_context() {
    local context_name="$1" cluster_id="$2" local_port="$3" region="$4" oci_profile="$5"
    echo -e "${BLUE}Configuring kubeconfig context: $context_name${NC}"

    set +e
    oci ce cluster create-kubeconfig --cluster-id "$cluster_id" --file "$HOME/.kube/config" \
        --region "$region" --token-version 2.0.0 --profile "$oci_profile" $OCI_AUTH_FLAG 2>/dev/null
    set -e

    kubectl config set-cluster "$context_name" --server="https://127.0.0.1:$local_port" --insecure-skip-tls-verify=true 2>/dev/null
    kubectl config set-credentials "$context_name-user" --exec-command=oci \
        --exec-arg=ce --exec-arg=cluster --exec-arg=generate-token --exec-arg=--cluster-id --exec-arg="$cluster_id" \
        --exec-arg=--region --exec-arg="$region" --exec-arg=--profile --exec-arg="$oci_profile" \
        --exec-arg=--auth --exec-arg=api_key --exec-api-version=client.authentication.k8s.io/v1beta1 2>/dev/null
    kubectl config set-context "$context_name" --cluster="$context_name" --user="$context_name-user" 2>/dev/null
    echo -e "${GREEN}Context '$context_name' configured${NC}"
}

setup_cluster_tunnel() {
    local prefix="$1" workspace="$2" tfvars_file="$3" local_port="$4" context_name="$5"

    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Setting up $prefix cluster tunnel${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    extract_cluster_config "$workspace" "$tfvars_file" "$prefix"

    local bastion_id cluster_id region oci_profile ssh_key_path private_key_path k8s_host k8s_port
    if [ "$prefix" = "PRIMARY" ]; then
        bastion_id="$PRIMARY_BASTION_ID"; cluster_id="$PRIMARY_CLUSTER_ID"; region="$PRIMARY_REGION"
        oci_profile="$PRIMARY_OCI_PROFILE"; ssh_key_path="$PRIMARY_SSH_KEY_PATH"
        private_key_path="$PRIMARY_PRIVATE_KEY_PATH"; k8s_host="$PRIMARY_K8S_HOST"; k8s_port="$PRIMARY_K8S_PORT"
    else
        bastion_id="$SECONDARY_BASTION_ID"; cluster_id="$SECONDARY_CLUSTER_ID"; region="$SECONDARY_REGION"
        oci_profile="$SECONDARY_OCI_PROFILE"; ssh_key_path="$SECONDARY_SSH_KEY_PATH"
        private_key_path="$SECONDARY_PRIVATE_KEY_PATH"; k8s_host="$SECONDARY_K8S_HOST"; k8s_port="$SECONDARY_K8S_PORT"
    fi

    [ ! -f "$private_key_path" ] && { echo -e "${RED}Error: SSH private key not found: $private_key_path${NC}" >&2; return 1; }
    [ ! -f "$ssh_key_path" ] && echo -e "${YELLOW}Warning: SSH public key not found (will derive from private key if possible): $ssh_key_path${NC}" >&2

    echo "Creating bastion session for $prefix cluster..."
    local session_id=""
    if ! session_id=$(create_port_forward_session "$bastion_id" "$k8s_host" "$k8s_port" \
        "dr-$prefix-kubectl-$(date +%Y%m%d-%H%M%S)" "$oci_profile" "$ssh_key_path" "$private_key_path"); then
        echo -e "${RED}Error: Failed to create bastion session for $prefix cluster${NC}" >&2
        return 1
    fi
    [ -z "$session_id" ] && { echo -e "${RED}Error: Failed to create bastion session for $prefix cluster${NC}" >&2; return 1; }

    wait_for_session_active "$session_id" "$oci_profile" || return 1

    local tunnel_pid=""
    set +e
    tunnel_pid=$(start_tunnel "$session_id" "$region" "$private_key_path" \
        "$local_port" "$k8s_host" "$k8s_port" "$ssh_key_path" "$prefix")
    local tunnel_exit_code=$?
    set -e

    if [ $tunnel_exit_code -ne 0 ] || [ -z "$tunnel_pid" ]; then
        echo -e "${RED}Error: Failed to start tunnel for $prefix cluster${NC}" >&2
        return 1
    fi

    if [ "$prefix" = "PRIMARY" ]; then
        PRIMARY_SESSION_ID="$session_id"; PRIMARY_TUNNEL_PID="$tunnel_pid"
    else
        SECONDARY_SESSION_ID="$session_id"; SECONDARY_TUNNEL_PID="$tunnel_pid"
    fi

    configure_kubeconfig_context "$context_name" "$cluster_id" "$local_port" "$region" "$oci_profile"

    echo -n "  Testing kubectl connectivity for $context_name... "
    set +e; local result=$(kubectl --context "$context_name" get nodes --no-headers 2>&1); local exit_code=$?; set -e
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}OK ($(echo "$result" | wc -l | tr -d ' ') nodes)${NC}"
    else
        echo -e "${YELLOW}FAILED${NC}"
    fi
}

cleanup_tunnels() {
    echo -e "${YELLOW}Cleaning up tunnels and bastion sessions...${NC}"
    if [ -n "$PRIMARY_TUNNEL_PID" ] && [ "${PRIMARY_TUNNEL_REUSED:-false}" != "true" ]; then
        kill -0 "$PRIMARY_TUNNEL_PID" 2>/dev/null && kill "$PRIMARY_TUNNEL_PID" 2>/dev/null || true
    fi
    if [ -n "$SECONDARY_TUNNEL_PID" ] && [ "${SECONDARY_TUNNEL_REUSED:-false}" != "true" ]; then
        kill -0 "$SECONDARY_TUNNEL_PID" 2>/dev/null && kill "$SECONDARY_TUNNEL_PID" 2>/dev/null || true
    fi
    [ -n "$PRIMARY_SESSION_ID" ] && oci bastion session delete --session-id "$PRIMARY_SESSION_ID" \
        --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG --force >/dev/null 2>&1 || true
    [ -n "$SECONDARY_SESSION_ID" ] && oci bastion session delete --session-id "$SECONDARY_SESSION_ID" \
        --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG --force >/dev/null 2>&1 || true
    echo -e "${GREEN}Cleanup completed.${NC}"
}

# ============================================================================
# DR Simulation Functions
# ============================================================================

get_operator_replicas() {
    kubectl --context "$1" -n "$NAMESPACE" get deployment humio-operator -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0"
}

get_logscale_pods() {
    kubectl --context "$1" -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" --no-headers 2>/dev/null || true
}

scale_operator() {
    echo "Scaling humio-operator to $2 on $3..."
    kubectl --context "$1" -n "$NAMESPACE" scale deployment humio-operator --replicas="$2"
    echo "  Done."
}

check_endpoint_health() {
    curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 "https://${1}/api/v1/status" 2>/dev/null || echo "000"
}

wait_for_pods_deleted() {
    local context="$1" label="$2" timeout="${3:-120}"
    local deadline=$(($(date +%s) + timeout))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local count
        count=$(kubectl --context "$context" -n "$NAMESPACE" get pods -l "$label" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
        [ "${count:-0}" -eq 0 ] && { echo "  All pods terminated."; return 0; }
        echo "  Waiting for $count pod(s)..."
        sleep 5
    done
    echo "  WARN: Pods did not terminate within ${timeout}s"
    return 1
}

wait_for_endpoint_healthy() {
    # Waits for an endpoint to return HTTP 200.
    # If snapshot_confirmed is true, uses an extended timeout since we know
    # LogScale is recovering and just needs more time to initialize.
    #
    # Arguments:
    #   $1 - fqdn: The hostname to check
    #   $2 - start_time: Epoch timestamp when overall failover started (used for logging)
    #   $3 - snapshot_confirmed: "true" if Step 6 confirmed snapshot was fetched (optional)
    #
    # When snapshot is confirmed, we:
    # 1. Wait a minimum of 300s (5 min) before accepting HTTP 200 as truly healthy
    # 2. Extend the timeout by 300s to allow LogScale to fully initialize
    #
    # This prevents false positives where LogScale returns 200 during startup
    # but is not yet fully ready to serve requests.
    local fqdn="$1"
    local start_time="$2"
    local snapshot_confirmed="${3:-false}"
    local extra_timeout=0
    local min_wait=0

    if [ "$snapshot_confirmed" = "true" ]; then
        extra_timeout=300  # 5 minutes extra timeout when snapshot is confirmed
        min_wait=300       # 5 minutes minimum wait before accepting HTTP 200
        echo "  Snapshot confirmed - waiting minimum ${min_wait}s before accepting healthy status" >&2
        echo "  Extended timeout by ${extra_timeout}s for LogScale initialization" >&2
    fi

    # Use current time for deadline, not $start_time which is from scenario start
    local step_start=$(date +%s)
    local min_ready_time=$((step_start + min_wait))
    local deadline=$((step_start + FAILOVER_TIMEOUT_SECONDS + extra_timeout))
    local last_status="000"
    local first_healthy_time=""

    while [ "$(date +%s)" -lt "$deadline" ]; do
        local status=$(check_endpoint_health "$fqdn")
        last_status="$status"
        local now=$(date +%s)
        local delta=$((now - step_start))

        if [ "$status" = "200" ]; then
            # Record when we first saw HTTP 200
            if [ -z "$first_healthy_time" ]; then
                first_healthy_time=$now
                print_timed "  ${GREEN}Endpoint $fqdn: HTTP 200 detected${NC} (+${delta}s)" >&2
            fi

            # Check if we've waited the minimum time
            if [ "$now" -ge "$min_ready_time" ]; then
                local wait_time=$((now - step_start))
                print_timed "  ${GREEN}Endpoint confirmed healthy after ${wait_time}s minimum wait${NC} (+${delta}s)" >&2
                echo "$now"
                return 0
            else
                local remaining=$((min_ready_time - now))
                print_timed "  Endpoint $fqdn: HTTP 200, waiting ${remaining}s more for stability... (+${delta}s)" >&2
            fi
        else
            # Reset first_healthy_time if endpoint goes unhealthy again
            first_healthy_time=""
            print_timed "  Endpoint $fqdn: HTTP $status, waiting... (+${delta}s)" >&2
        fi
        sleep 10
    done

    # Detailed failure diagnostics
    echo "" >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
    echo "               DR FAILOVER HEALTH CHECK FAILED" >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
    echo "Endpoint: https://${fqdn}/api/v1/status | Last Status: HTTP $last_status" >&2
    echo "" >&2
    echo "Diagnostic Information:" >&2
    echo "1. Humio Operator:" >&2
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" get deployment humio-operator 2>&1 | sed 's/^/   /' >&2
    echo "2. LogScale Pods:" >&2
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=humio" 2>&1 | sed 's/^/   /' >&2
    echo "3. Recent Operator Logs:" >&2
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" logs deployment/humio-operator --tail=10 2>&1 | sed 's/^/   /' >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
    return 1
}

# wait_for_lb_backends_healthy - Wait for OCI Load Balancer backends to become healthy
# Uses OCI Monitoring metrics (oci_lbaas namespace, UnHealthyBackendServers metric)
# This is more reliable than HTTP endpoint checks when public_lb_cidrs restricts access
#
# Arguments:
#   $1 - lb_ocid: Load Balancer OCID to monitor
#   $2 - compartment_ocid: Compartment OCID for monitoring query
#   $3 - start_time: Start time epoch for timeout calculation
#   $4 - oci_profile: OCI CLI profile to use
#   $5 - backend_set_name: Backend set name (default: TCP-443)
#
# Returns:
#   epoch when healthy (stdout), 0 on success, 1 on timeout
wait_for_lb_backends_healthy() {
    local lb_ocid="$1"
    local compartment_ocid="$2"
    local start_time="$3"
    local oci_profile="${4:-${PRIMARY_OCI_PROFILE:-DEFAULT}}"
    local backend_set_name="${5:-TCP-443}"
    local deadline=$((start_time + FAILOVER_TIMEOUT_SECONDS))
    local last_unhealthy_count="unknown"

    # Validate required parameters
    if [ -z "$lb_ocid" ] || [ "$lb_ocid" = "null" ]; then
        echo "  ERROR: PRIMARY_LB_OCID not set. Cannot check LB backend health." >&2
        return 1
    fi
    if [ -z "$compartment_ocid" ] || [ "$compartment_ocid" = "null" ]; then
        echo "  ERROR: PRIMARY_COMPARTMENT_OCID not set. Cannot check LB backend health." >&2
        return 1
    fi

    echo "  Monitoring LB backend health via OCI Monitoring metrics..." >&2
    echo "    LB OCID: ${lb_ocid:0:50}..." >&2
    echo "    Backend Set: $backend_set_name" >&2

    while [ "$(date +%s)" -lt "$deadline" ]; do
        local now=$(date +%s)
        local delta=$((now - start_time))

        # Query OCI Monitoring for UnHealthyBackendServers metric
        # A value of 0 means all backends are healthy
        local query_result
        query_result=$(OCI_CLI_PROFILE="$oci_profile" oci monitoring metric-data summarize-metrics-data \
            --compartment-id "$compartment_ocid" \
            --namespace "oci_lbaas" \
            --query-text "UnHealthyBackendServers[1m]{resourceId = \"${lb_ocid}\", backendSetName = \"${backend_set_name}\"}.sum()" \
            $OCI_AUTH_FLAG --output json 2>/dev/null || echo "{}")

        # Extract the latest datapoint value
        local unhealthy_count
        unhealthy_count=$(jq_parse "$query_result" '.data[0]["aggregated-datapoints"][-1].value // -1')

        # Handle case where metric has no data (LB may still be starting)
        if [ "$unhealthy_count" = "-1" ] || [ -z "$unhealthy_count" ]; then
            echo "  [+${delta}s] LB metrics not available yet (LB may be initializing)..." >&2
            last_unhealthy_count="no-data"
            sleep 15
            continue
        fi

        last_unhealthy_count="$unhealthy_count"

        # Check if backends are healthy.
        # With node-label-selector filtering, only LogScale nodes are backends.
        # Normal state = 0 unhealthy. Consider recovered when unhealthy = 0.
        local unhealthy_int="${unhealthy_count%%.*}"  # Strip decimal part
        if [ "${unhealthy_int:-0}" -eq 0 ]; then
            echo -e "  ${GREEN}[+${delta}s] All LB backends healthy (UnHealthyBackendServers=0)${NC}" >&2
            echo "$now"
            return 0
        fi

        echo "  [+${delta}s] LB has unhealthy backends: UnHealthyBackendServers=${unhealthy_count}, waiting..." >&2
        sleep 15
    done

    # Timeout - provide diagnostic information
    echo "" >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
    echo "           LB BACKEND HEALTH CHECK TIMEOUT" >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
    echo "LB OCID: $lb_ocid" >&2
    echo "Backend Set: $backend_set_name" >&2
    echo "Last UnHealthyBackendServers: $last_unhealthy_count" >&2
    echo "" >&2
    echo "Diagnostic Information:" >&2
    echo "1. Humio Operator on PRIMARY:" >&2
    kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" get deployment humio-operator 2>&1 | sed 's/^/   /' >&2
    echo "2. LogScale Pods on PRIMARY:" >&2
    kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=humio" 2>&1 | sed 's/^/   /' >&2
    echo "3. nginx-ingress Pods on PRIMARY:" >&2
    kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "${NAMESPACE}-ingress" get pods 2>&1 | sed 's/^/   /' >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
    return 1
}

# wait_for_lb_backends_unhealthy - Wait for OCI Load Balancer backends to become unhealthy
# Uses a two-phase approach:
#   1. Direct LB Backend Health API (oci lb backend-set-health get) - real-time, no delay
#   2. OCI Monitoring metrics as secondary confirmation
#
# The direct API check provides immediate detection when backends fail health checks,
# while OCI Monitoring metrics have a 1-2 minute aggregation delay.
#
# Arguments:
#   $1 - lb_ocid: Load Balancer OCID to monitor
#   $2 - compartment_ocid: Compartment OCID for monitoring query
#   $3 - start_time: Start time epoch for timeout calculation
#   $4 - oci_profile: OCI CLI profile to use
#   $5 - backend_set_name: Backend set name (default: TCP-443)
#
# Returns:
#   epoch when unhealthy (stdout), 0 on success, 1 on timeout
wait_for_lb_backends_unhealthy() {
    local lb_ocid="$1"
    local compartment_ocid="$2"
    local start_time="$3"
    local oci_profile="${4:-${PRIMARY_OCI_PROFILE:-DEFAULT}}"
    local backend_set_name="${5:-TCP-443}"
    local deadline=$((start_time + FAILOVER_TIMEOUT_SECONDS))

    # Validate required parameters
    if [ -z "$lb_ocid" ] || [ "$lb_ocid" = "null" ]; then
        echo "  ERROR: LB OCID not set. Cannot check LB backend health." >&2
        return 1
    fi
    if [ -z "$compartment_ocid" ] || [ "$compartment_ocid" = "null" ]; then
        echo "  ERROR: Compartment OCID not set. Cannot check LB backend health." >&2
        return 1
    fi

    echo "  Monitoring LB backend health via dual-check approach:" >&2
    echo "    1. Direct LB Backend Health API (real-time)" >&2
    echo "    2. OCI Monitoring metrics (delayed, for confirmation)" >&2
    echo "    LB OCID: ${lb_ocid:0:50}..." >&2
    echo "    Backend Set: $backend_set_name" >&2
    echo "" >&2

    local api_detected_unhealthy=false
    local api_detection_time=""
    local polling_interval=5  # Check every 5 seconds for faster detection

    while [ "$(date +%s)" -lt "$deadline" ]; do
        local now=$(date +%s)
        local delta=$((now - start_time))

        # === Phase 1: Direct LB Backend Health API (FAST - real-time) ===
        # This API returns current health status without aggregation delay
        local api_result
        api_result=$(OCI_CLI_PROFILE="$oci_profile" oci lb backend-set-health get \
            --load-balancer-id "$lb_ocid" \
            --backend-set-name "$backend_set_name" \
            $OCI_AUTH_FLAG --output json 2>/dev/null || echo "{}")

        # Check if API call succeeded
        local api_status
        api_status=$(jq_parse "$api_result" '.data.status // "UNKNOWN"')

        if [ "$api_status" != "UNKNOWN" ]; then
            local critical_count warning_count total_count
            critical_count=$(jq_parse "$api_result" '.data."critical-state-backend-names" | length // 0')
            warning_count=$(jq_parse "$api_result" '.data."warning-state-backend-names" | length // 0')
            total_count=$(jq_parse "$api_result" '.data."total-backend-count" // 0')

            # Status can be: OK, WARNING, CRITICAL, UNKNOWN
            if [ "$api_status" = "CRITICAL" ] || [ "${critical_count:-0}" -gt 0 ]; then
                if [ "$api_detected_unhealthy" = false ]; then
                    api_detected_unhealthy=true
                    api_detection_time=$now
                    print_timed "  ${GREEN}[+${delta}s] API: LB backends CRITICAL (status=${api_status}, critical=${critical_count}/${total_count})${NC}" >&2
                    echo "    Detection via direct API (real-time)" >&2
                fi
            elif [ "$api_status" = "WARNING" ] || [ "${warning_count:-0}" -gt 0 ]; then
                print_timed "  [+${delta}s] API: LB backends WARNING (status=${api_status}, warning=${warning_count}/${total_count})" >&2
            else
                print_timed "  [+${delta}s] API: LB backends healthy (status=${api_status}, backends=${total_count})" >&2
            fi
        else
            print_timed "  [+${delta}s] API: Unable to query backend health (OCID may be incorrect)" >&2
        fi

        # === Phase 2: OCI Monitoring Metrics (DELAYED - for confirmation) ===
        # Query every 15 seconds to avoid excessive API calls (metrics have 1-minute delay anyway)
        local check_metrics=false
        if [ $((delta % 15)) -lt "$polling_interval" ] || [ "$api_detected_unhealthy" = true ]; then
            check_metrics=true
        fi

        if [ "$check_metrics" = true ]; then
            local query_result
            query_result=$(OCI_CLI_PROFILE="$oci_profile" oci monitoring metric-data summarize-metrics-data \
                --compartment-id "$compartment_ocid" \
                --namespace "oci_lbaas" \
                --query-text "UnHealthyBackendServers[1m]{resourceId = \"${lb_ocid}\", backendSetName = \"${backend_set_name}\"}.sum()" \
                $OCI_AUTH_FLAG --output json 2>/dev/null || echo "{}")

            local unhealthy_count
            unhealthy_count=$(jq_parse "$query_result" '.data[0]["aggregated-datapoints"][-1].value // -1')

            # Handle both integer and floating point values from OCI API
            local unhealthy_int="${unhealthy_count%%.*}"

            if [ "$unhealthy_count" != "-1" ] && [ -n "$unhealthy_count" ]; then
                if [ "${unhealthy_int:-0}" -gt 0 ]; then
                    print_timed "  ${GREEN}[+${delta}s] Metrics: UnHealthyBackendServers=${unhealthy_count} (confirmed unhealthy)${NC}" >&2

                    # Return the first detection time (API is faster)
                    if [ -n "$api_detection_time" ]; then
                        echo "$api_detection_time"
                    else
                        echo "$now"
                    fi
                    return 0
                else
                    print_timed "  [+${delta}s] Metrics: UnHealthyBackendServers=${unhealthy_count} (waiting for metrics to catch up...)" >&2
                fi
            fi
        fi

        # If API detected unhealthy, wait a bit longer for metrics to confirm before giving up
        # This handles the case where API shows unhealthy but metrics haven't caught up yet
        if [ "$api_detected_unhealthy" = true ]; then
            local api_wait=$((now - api_detection_time))
            if [ "$api_wait" -ge 120 ]; then
                # API confirmed unhealthy 2+ minutes ago, metrics should have caught up
                # Return API detection time even without metrics confirmation
                print_timed "  ${YELLOW}[+${delta}s] Metrics did not confirm within 2 minutes, proceeding with API detection${NC}" >&2
                echo "$api_detection_time"
                return 0
            fi
            # Continue waiting with faster polling
            sleep 3
        else
            sleep "$polling_interval"
        fi
    done

    echo -e "  ${YELLOW}WARN: LB backends did not become unhealthy within timeout${NC}" >&2
    if [ "$api_detected_unhealthy" = true ]; then
        echo "  Note: API detected unhealthy at +$((api_detection_time - start_time))s but metrics never confirmed" >&2
        # Return API detection time even on timeout if it was detected
        echo "$api_detection_time"
        return 0
    fi
    return 1
}

track_operator_scaling() {
    local context="$1"
    local start_time="$2"
    # Use current time for deadline, not $start_time which is from scenario start
    local step_start=$(date +%s)
    local deadline=$((step_start + FAILOVER_TIMEOUT_SECONDS))
    echo "Tracking secondary humio-operator scaling from 0→1 replicas..." >&2
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local replicas=$(get_operator_replicas "$context")
        local now=$(date +%s)
        local delta=$((now - step_start))
        if [ "${replicas:-0}" -ge 1 ]; then
            print_timed "${GREEN}  humio-operator scaled to $replicas at $(epoch_to_iso "$now") (+${delta}s)${NC}" >&2
            echo "$now"; return 0
        fi
        print_timed "  humio-operator replicas: ${replicas:-0}, waiting... (+${delta}s)" >&2
        sleep 5
    done
    echo -e "${YELLOW}  WARN: humio-operator did not scale within timeout${NC}" >&2
    return 1
}

track_logscale_pod_ready() {
    local context="$1"
    local start_time="$2"
    # Use current time for deadline, not $start_time which is from scenario start
    local step_start=$(date +%s)
    local deadline=$((step_start + FAILOVER_TIMEOUT_SECONDS))
    echo "Tracking secondary LogScale pod readiness..." >&2
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local ready
        ready=$(kubectl --context "$context" -n "$NAMESPACE" get pods \
            -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
            -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" 2>/dev/null || true)
        ready=$(echo "$ready" | tr -d '[:space:]')
        local total
        total=$(kubectl --context "$context" -n "$NAMESPACE" get pods \
            -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
            --no-headers 2>/dev/null | wc -l 2>/dev/null || true)
        total=$(echo "$total" | tr -d '[:space:]')
        local now=$(date +%s)
        local delta=$((now - step_start))
        if [ "${ready:-0}" -ge 1 ]; then
            print_timed "${GREEN}  LogScale pod Ready at $(epoch_to_iso "$now") (+${delta}s)${NC}" >&2
            echo "$now"; return 0
        fi
        print_timed "  LogScale pods: ${ready:-0}/${total:-0} Ready, waiting... (+${delta}s)" >&2
        sleep 5
    done
    echo -e "${YELLOW}  WARN: LogScale pod did not become Ready within timeout${NC}" >&2
    return 1
}

track_snapshot_fetch() {
    # Tracks when LogScale successfully fetches the global snapshot from the primary bucket
    # during DR recovery. Monitors the DataSnapshotLoader log messages sequence.
    #
    # Expected log sequence during DR recovery (from DataSnapshotLoader class):
    # These messages appear in the pod logs with format:
    #   <timestamp> [main] INFO c.h.e.f.DataSnapshotLoader <N> - <message>
    #
    # The grep pattern looks for "c.h.e.f.DataSnapshotLoader" in the Step 6.
    #
    # Key log messages to track:
    #   - "Checking bucket storage localAndHttpWereEmpty=true"
    #   - "Fetching global snapshot from bucket storage s3 found no snapshot to fetch"
    #   - "Trying to fetch a global snapshot as recovery source from bucket storage in s3"
    #   - "Fetched global snapshot from bucket storage s3 found snapshot"
    #   - "updateSnapshotForDisasterRecovery: Patching"
    #   - "updateSnapshotForDisasterRecovery: setting readOnly=true"
    #
    # See DR_OPERATIONS_GUIDE.md section "Verify DR Recovery Succeeded" for details.
    local context="$1"
    local start_time="$2"
    local timeout="${3:-300}"
    # IMPORTANT: Use current time for deadline, not $start_time which is from scenario start
    # By the time Step 6 runs, significant time may have elapsed from Steps 1-5
    local step_start=$(date +%s)
    local deadline=$((step_start + timeout))

    echo "Tracking global snapshot fetch from primary bucket..." >&2
    echo "  Monitoring DataSnapshotLoader logs for DR recovery sequence" >&2

    local pod_name=""
    local pod_start_time=""

    while [ "$(date +%s)" -lt "$deadline" ]; do
        local now=$(date +%s)
        local delta=$((now - step_start))

        # Get LogScale pod name if not yet found
        if [ -z "$pod_name" ]; then
            pod_name=$(kubectl --context "$context" -n "$NAMESPACE" get pods \
                -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

            if [ -z "$pod_name" ]; then
                print_timed "  Waiting for LogScale pod to exist... (+${delta}s)" >&2
                sleep 5
                continue
            fi
            echo "  Found LogScale pod: $pod_name" >&2
        fi

        # Check if pod is running (container must be started to have logs)
        local pod_phase=$(kubectl --context "$context" -n "$NAMESPACE" get pod "$pod_name" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [ "$pod_phase" != "Running" ]; then
            print_timed "  Pod phase: ${pod_phase:-Unknown}, waiting for Running... (+${delta}s)" >&2
            sleep 5
            continue
        fi

        # Get all logs from the humio container (no --since flag to get startup logs)
        # The DataSnapshotLoader messages appear at startup during DR recovery
        local log_output
        log_output=$(kubectl --context "$context" -n "$NAMESPACE" logs "$pod_name" -c humio 2>/dev/null || echo "")

        # Debug: show if we got any logs at all
        if [ -z "$log_output" ]; then
            print_timed "  No logs available yet from humio container... (+${delta}s)" >&2
            sleep 5
            continue
        fi

        # Filter for DataSnapshotLoader messages (c.h.e.f.DataSnapshotLoader)
        local snapshot_logs
        snapshot_logs=$(echo "$log_output" | grep "c.h.e.f.DataSnapshotLoader" || echo "")

        # Check for the final success indicator: "setting readOnly=true"
        # This confirms the global snapshot was fetched and patched successfully
        if echo "$snapshot_logs" | grep -q "setting readOnly=true"; then
            print_timed "${GREEN}  DR Recovery Complete at $(epoch_to_iso "$now") (+${delta}s)${NC}" >&2
            echo -e "${GREEN}  Global snapshot fetched and patched successfully${NC}" >&2

            # Show the key log messages found
            echo "" >&2
            echo "  DataSnapshotLoader log messages found:" >&2

            # Show bucket patching details
            local bucket_patch
            bucket_patch=$(echo "$snapshot_logs" | grep "Patching bucket using from=" | tail -1)
            if [ -n "$bucket_patch" ]; then
                echo "    - $bucket_patch" >&2
            fi

            local readonly_msg
            readonly_msg=$(echo "$snapshot_logs" | grep "setting readOnly=true" | tail -1)
            if [ -n "$readonly_msg" ]; then
                echo "    - $readonly_msg" >&2
            fi

            echo "$now"
            return 0
        fi

        # Report progress based on which log messages have been found
        local found_any=false

        # Check for each stage and report the highest stage found
        if echo "$snapshot_logs" | grep -q "Patching"; then
            print_timed "  [7/8] Patching snapshot for DR... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "Selecting snapshot from source=s3"; then
            print_timed "  [6/8] Selecting snapshot for recovery... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "Fetched a global snapshot as recovery source"; then
            print_timed "  [5/8] Recovery snapshot fetched, now patching... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "Fetched global snapshot from bucket storage s3 found snapshot"; then
            print_timed "  [4/8] Found snapshot in primary bucket... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "Trying to fetch a global snapshot as recovery source"; then
            print_timed "  [3/8] Attempting recovery from primary bucket... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "found no snapshot to fetch"; then
            print_timed "  [2/8] Secondary bucket empty, will fetch from primary... (+${delta}s)" >&2
            found_any=true
        elif echo "$snapshot_logs" | grep -q "Checking bucket storage"; then
            print_timed "  [1/8] Checking bucket storage... (+${delta}s)" >&2
            found_any=true
        fi

        # If no DataSnapshotLoader messages found yet
        if [ "$found_any" = false ]; then
            # Check if there are any DataSnapshotLoader logs at all
            local log_count
            log_count=$(echo "$snapshot_logs" | wc -l | tr -d '[:space:]')
            if [ "${log_count:-0}" -gt 0 ]; then
                print_timed "  Found $log_count DataSnapshotLoader log entries, analyzing... (+${delta}s)" >&2
            else
                print_timed "  Waiting for DataSnapshotLoader to start... (+${delta}s)" >&2
            fi
        fi

        sleep 5
    done

    echo -e "${YELLOW}  WARN: Global snapshot fetch not detected within timeout${NC}" >&2
    echo -e "${YELLOW}  This may indicate DR recovery did not complete successfully${NC}" >&2
    echo "" >&2
    echo "  Troubleshooting:" >&2
    echo "    1. Check LogScale pod logs:" >&2
    if [ -n "$pod_name" ]; then
        echo "       kubectl --context $context -n $NAMESPACE logs $pod_name -c humio | grep c.h.e.f.DataSnapshotLoader" >&2
    else
        echo "       # First find the pod name:" >&2
        echo "       kubectl --context $context -n $NAMESPACE get pods -l 'app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator'" >&2
        echo "       # Then check logs:" >&2
        echo "       kubectl --context $context -n $NAMESPACE logs <POD_NAME> -c humio | grep c.h.e.f.DataSnapshotLoader" >&2
    fi
    echo "    2. Query in LogScale UI:" >&2
    echo "       c.h.e.f.DataSnapshotLoader" >&2
    echo "    3. See DR_OPERATIONS_GUIDE.md section 'Verify DR Recovery Succeeded'" >&2
    return 1
}

wait_for_primary_unhealthy() {
    local start_time="$1"
    local deadline=$((start_time + FAILOVER_TIMEOUT_SECONDS))
    echo "Waiting for primary endpoint to become unhealthy..." >&2
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local status=$(check_endpoint_health "$PRIMARY_FQDN")
        local now=$(date +%s)
        local delta=$((now - start_time))
        if [ "$status" != "200" ]; then
            echo -e "${GREEN}  Primary endpoint unhealthy (HTTP $status) at $(epoch_to_iso "$now") (+${delta}s)${NC}" >&2
            echo "$now"; return 0
        fi
        echo "  Primary endpoint: HTTP $status, waiting... (+${delta}s)" >&2
        sleep 5
    done
    echo -e "${YELLOW}  WARN: Primary endpoint did not become unhealthy within timeout${NC}" >&2
    return 1
}

get_health_check_status() {
    [ -z "$1" ] && { echo "Unknown"; return 0; }
    local result
    if ! result=$(oci health-checks http-monitor get --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG --monitor-id "$1" \
        --query 'data."is-enabled"' --raw-output 2>&1); then
        log_debug "Health check query failed: $result"
        echo "NotFound"
        return 0
    fi
    echo "$result"
}

get_health_check_display_name() {
    # Returns the display name of a health check
    [ -z "$1" ] && { echo "Unknown"; return 0; }
    local result
    if ! result=$(oci health-checks http-monitor get --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG --monitor-id "$1" \
        --query 'data."display-name"' --raw-output 2>&1); then
        log_debug "Health check display name query failed: $result"
        echo "Unknown"
        return 0
    fi
    echo "$result"
}

get_alarm_display_name() {
    # Returns the display name of an alarm
    [ -z "$1" ] && { echo "Unknown"; return 0; }
    local result
    if ! result=$(oci monitoring alarm get --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG --alarm-id "$1" \
        --query 'data."display-name"' --raw-output 2>&1); then
        log_debug "Alarm display name query failed: $result"
        echo "Unknown"
        return 0
    fi
    echo "$result"
}

show_infrastructure_details() {
    # Display infrastructure information for DR operations
    # Fetches live data from OCI APIs for accuracy
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  INFRASTRUCTURE DETAILS${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}  Terraform Workspaces:${NC}"
    echo "    PRIMARY Workspace:    ${PRIMARY_WORKSPACE:-primary}"
    echo "    SECONDARY Workspace:  ${SECONDARY_WORKSPACE:-secondary}"
    echo ""
    echo -e "${CYAN}  Tfvars Files:${NC}"
    echo "    PRIMARY Tfvars:       ${PRIMARY_TFVARS:-primary-us-chicago-1.tfvars}"
    echo "    SECONDARY Tfvars:     ${SECONDARY_TFVARS:-secondary-us-chicago-1.tfvars}"
    echo ""

    # Fetch OKE cluster names from OCI
    local primary_cluster_name="Not available"
    local secondary_cluster_name="Not available"
    if [ -n "${PRIMARY_CLUSTER_ID:-}" ] && [ "$PRIMARY_CLUSTER_ID" != "null" ]; then
        primary_cluster_name=$(oci ce cluster get --cluster-id "$PRIMARY_CLUSTER_ID" \
            --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG \
            --query 'data.name' --raw-output 2>/dev/null || echo "Unknown")
    fi
    if [ -n "${SECONDARY_CLUSTER_ID:-}" ] && [ "$SECONDARY_CLUSTER_ID" != "null" ]; then
        secondary_cluster_name=$(oci ce cluster get --cluster-id "$SECONDARY_CLUSTER_ID" \
            --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG \
            --query 'data.name' --raw-output 2>/dev/null || echo "Unknown")
    fi

    echo -e "${CYAN}  OKE Cluster Information:${NC}"
    echo "    PRIMARY Cluster Name: $primary_cluster_name"
    echo "    PRIMARY Cluster ID:   ${PRIMARY_CLUSTER_ID:-Not loaded}"
    echo "    PRIMARY Region:       ${PRIMARY_REGION:-Not loaded}"
    echo ""
    echo "    SECONDARY Cluster Name: $secondary_cluster_name"
    echo "    SECONDARY Cluster ID:   ${SECONDARY_CLUSTER_ID:-Not loaded}"
    echo "    SECONDARY Region:       ${SECONDARY_REGION:-Not loaded}"
    echo ""

    # Fetch health check details
    echo -e "${CYAN}  DR Health Check:${NC}"
    echo "    Monitoring Mode:      ${DR_MONITORING_MODE:-auto-detect}"
    local hc_ocid="${EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID:-$PRIMARY_HEALTH_CHECK_OCID}"
    local hc_name="Not available"
    local hc_status="Unknown"
    if [ -n "$hc_ocid" ] && [ "$hc_ocid" != "null" ]; then
        hc_name=$(get_health_check_display_name "$hc_ocid" 2>/dev/null || echo "Unknown")
        hc_status=$(get_health_check_status "$hc_ocid" 2>/dev/null || echo "Unknown")
    fi
    echo "    Health Check Name:    $hc_name"
    echo "    Health Check OCID:    ${hc_ocid:-Not configured}"
    echo "    Health Check Enabled: $hc_status"
    echo ""

    # Fetch alarm details
    echo -e "${CYAN}  DR Failover Alarm:${NC}"
    local alarm_name="Not available"
    local alarm_status="Unknown"
    if [ -n "${DR_FAILOVER_ALARM_OCID:-}" ] && [ "$DR_FAILOVER_ALARM_OCID" != "null" ]; then
        alarm_name=$(get_alarm_display_name "$DR_FAILOVER_ALARM_OCID" 2>/dev/null || echo "Unknown")
        alarm_status=$(get_alarm_status "$DR_FAILOVER_ALARM_OCID" 2>/dev/null || echo "Unknown")
    fi
    echo "    Alarm Name:           $alarm_name"
    echo "    Alarm OCID:           ${DR_FAILOVER_ALARM_OCID:-Not configured}"
    echo "    Alarm Enabled:        $alarm_status"
    echo ""

    # Display Object Storage bucket information (used in failback)
    echo -e "${CYAN}  Object Storage (SECONDARY):${NC}"
    echo "    Bucket Name:          ${SECONDARY_BUCKET_NAME:-Not configured}"
    if [ -n "${SECONDARY_BUCKET_NAME:-}" ] && [ "$SECONDARY_BUCKET_NAME" != "null" ]; then
        # Get the namespace for the bucket
        local os_namespace
        os_namespace=$(oci os ns get --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG \
            --query 'data' --raw-output 2>/dev/null || echo "Unknown")
        echo "    Namespace:            $os_namespace"
    fi
    echo ""

    echo -e "${CYAN}  Kubernetes Contexts:${NC}"
    echo "    PRIMARY Context:      $PRIMARY_KUBE_CONTEXT"
    echo "    SECONDARY Context:    $SECONDARY_KUBE_CONTEXT"
    echo "    Namespace:            $NAMESPACE"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

set_health_check_enabled() {
    local monitor_id="$1"
    local enabled="$2"
    echo "  Updating health check: is-enabled=$enabled"
    local result
    if ! result=$(oci health-checks http-monitor update --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG --monitor-id "$monitor_id" \
        --is-enabled "$enabled" --force 2>&1); then
        log_debug "Health check update failed: $result"
        echo "  ERROR: Failed to update health check"
        return 1
    fi
    echo "  Done."
}

get_health_check_path() {
    # Gets the current path from the health check configuration
    [ -z "$1" ] && { echo ""; return 0; }
    local result
    if ! result=$(oci health-checks http-monitor get --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG --monitor-id "$1" \
        --query 'data.path' --raw-output 2>&1); then
        log_debug "Health check path query failed: $result"
        echo ""
        return 0
    fi
    echo "$result"
}

set_health_check_path() {
    # Sets the health check path to a new value
    local monitor_id="$1"
    local new_path="$2"
    echo "  Updating health check path to: $new_path"
    local result
    if ! result=$(oci health-checks http-monitor update --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG --monitor-id "$monitor_id" \
        --path "$new_path" --force 2>&1); then
        log_debug "Health check path update failed: $result"
        echo "  ERROR: Failed to update health check path"
        return 1
    fi
    echo "  Done."
}

# ============================================================================
# Alarm Management Functions
# ============================================================================

get_alarm_status() {
    # Returns the alarm is-enabled status (true/false)
    [ -z "$1" ] && { echo "Unknown"; return 0; }
    local result
    if ! result=$(oci monitoring alarm get --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG --alarm-id "$1" \
        --query 'data."is-enabled"' --raw-output 2>&1); then
        log_debug "Alarm query failed: $result"
        echo "NotFound"
        return 0
    fi
    echo "$result"
}

get_alarm_firing_state() {
    # Returns the alarm's current firing state (OK, FIRING, SUSPENDED)
    # This is different from get_alarm_status which returns whether alarm is enabled
    # Uses the alarm-status API to get the actual current state
    local alarm_id="$1"
    local compartment_id="${2:-$PRIMARY_COMPARTMENT_OCID}"
    local oci_profile="${3:-$SECONDARY_OCI_PROFILE}"

    [ -z "$alarm_id" ] && { echo "Unknown"; return 0; }
    [ -z "$compartment_id" ] && { echo "Unknown"; return 0; }

    local result
    result=$(oci monitoring alarm-status list-alarms-status \
        --profile "$oci_profile" $OCI_AUTH_FLAG \
        --compartment-id "$compartment_id" \
        --output json 2>/dev/null || echo "{}")

    # Find the specific alarm by ID and extract its status
    local status
    status=$(jq_parse "$result" '.data[] | select(.id == $id) | .status' --arg id "$alarm_id")

    if [ -z "$status" ] || [ "$status" = "null" ]; then
        echo "Unknown"
    else
        echo "$status"
    fi
}

wait_for_alarm_firing() {
    # Waits for an OCI Monitoring alarm to reach FIRING state
    # This indicates the alarm condition has been met and the alarm has triggered
    #
    # Arguments:
    #   $1 - alarm_id: OCI alarm OCID
    #   $2 - compartment_id: Compartment OCID for the alarm
    #   $3 - start_time: Epoch timestamp when the wait started (for timeout calculation)
    #   $4 - oci_profile: OCI CLI profile (optional, defaults to SECONDARY_OCI_PROFILE)
    #
    # Returns:
    #   epoch when alarm fired (stdout), 0 on success, 1 on timeout

    local alarm_id="$1"
    local compartment_id="$2"
    local start_time="$3"
    local oci_profile="${4:-$SECONDARY_OCI_PROFILE}"
    local deadline=$((start_time + FAILOVER_TIMEOUT_SECONDS))
    local polling_interval=10  # Check every 10 seconds

    # Validate required parameters
    if [ -z "$alarm_id" ] || [ "$alarm_id" = "null" ]; then
        echo "  ERROR: Alarm OCID not set. Cannot check alarm firing state." >&2
        return 1
    fi
    if [ -z "$compartment_id" ] || [ "$compartment_id" = "null" ]; then
        echo "  ERROR: Compartment OCID not set. Cannot check alarm firing state." >&2
        return 1
    fi

    echo "  Monitoring alarm state..." >&2
    echo "    Alarm OCID: ${alarm_id:0:60}..." >&2
    echo "    Expected transition: OK → FIRING" >&2
    echo "" >&2

    while [ "$(date +%s)" -lt "$deadline" ]; do
        local now=$(date +%s)
        local delta=$((now - start_time))

        local current_state
        current_state=$(get_alarm_firing_state "$alarm_id" "$compartment_id" "$oci_profile")

        if [ "$current_state" = "FIRING" ]; then
            print_timed "  ${GREEN}[+${delta}s] Alarm is FIRING - DR failover triggered!${NC}" >&2
            echo "$now"
            return 0
        elif [ "$current_state" = "OK" ]; then
            print_timed "  [+${delta}s] Alarm state: OK (waiting for FIRING...)" >&2
        elif [ "$current_state" = "SUSPENDED" ]; then
            print_timed "  ${YELLOW}[+${delta}s] Alarm state: SUSPENDED (suppressed)${NC}" >&2
        else
            print_timed "  [+${delta}s] Alarm state: $current_state" >&2
        fi

        sleep "$polling_interval"
    done

    echo -e "  ${YELLOW}WARN: Alarm did not reach FIRING state within timeout${NC}" >&2
    return 1
}

set_alarm_enabled() {
    # Enables or disables the alarm
    local alarm_id="$1"
    local enabled="$2"
    echo "  Updating alarm: is-enabled=$enabled"
    local result
    if ! result=$(oci monitoring alarm update --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG --alarm-id "$alarm_id" \
        --is-enabled "$enabled" --force 2>&1); then
        log_debug "Alarm update failed: $result"
        echo "  ERROR: Failed to update alarm"
        return 1
    fi
    echo "  Done."
}

suppress_alarm() {
    # Suppresses the alarm for a specified duration
    local alarm_id="$1"
    local duration_minutes="${2:-30}"  # Default 30 minutes

    local start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # macOS date command for adding minutes
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local end_time=$(date -u -v+${duration_minutes}M +"%Y-%m-%dT%H:%M:%SZ")
    else
        local end_time=$(date -u -d "+${duration_minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ")
    fi

    echo "  Suppressing alarm for ${duration_minutes} minutes..."
    echo "  Suppression window: $start_time to $end_time"

    local result
    if ! result=$(oci monitoring suppression create \
        --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG \
        --alarm-id "$alarm_id" \
        --time-suppress-from "$start_time" \
        --time-suppress-until "$end_time" \
        --description "Failback operation - temporary suppression during restoration" 2>&1); then
        log_debug "Alarm suppression failed: $result"
        echo "  WARN: Could not create suppression (alarm may still fire)"
        return 1
    fi
    echo "  Done."
}

remove_alarm_suppression() {
    # Removes any active suppression on the alarm
    local alarm_id="$1"
    echo "  Checking for active alarm suppression..."

    # Get alarm details to check for suppression
    local alarm_data
    alarm_data=$(oci monitoring alarm get --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG --alarm-id "$alarm_id" \
        --output json 2>/dev/null || echo "{}")

    local suppression_id
    suppression_id=$(echo "$alarm_data" | jq -r '.data.suppression.id // empty' 2>/dev/null)

    if [ -n "$suppression_id" ]; then
        echo "  Found active suppression: $suppression_id"
        echo "  Removing suppression..."
        local result
        if ! result=$(oci monitoring suppression delete \
            --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG \
            --suppression-id "$suppression_id" --force 2>&1); then
            log_debug "Suppression deletion failed: $result"
            echo "  WARN: Could not remove suppression"
            return 1
        fi
        echo "  Suppression removed."
    else
        echo "  No active suppression found."
    fi
}

reset_dns_steering_policy() {
    # Reset the DNS steering policy answers to enable primary and keep secondary enabled.
    # This reverses the failover action where the DR function disables the primary answer.
    #
    # The steering policy has FILTER → PRIORITY → LIMIT rules:
    # - FILTER passes answers where is_disabled != true
    # - PRIORITY returns the lowest value (primary=1 wins over secondary=99)
    # - LIMIT returns only 1 answer
    #
    # After reset: both answers enabled, primary wins via PRIORITY rule.

    local steering_policy_id="${1:-$STEERING_POLICY_ID}"
    local primary_ip="${2:-$PRIMARY_LB_IP}"

    if [ -z "$steering_policy_id" ] || [ "$steering_policy_id" = "null" ]; then
        echo "  WARN: No steering policy ID configured. Skipping DNS reset."
        echo "        Run 'terraform apply' on the primary workspace to reset DNS."
        return 1
    fi

    echo "  Steering Policy ID: $steering_policy_id"

    # Get current steering policy state
    local policy_json
    policy_json=$(oci dns steering-policy get \
        --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG \
        --steering-policy-id "$steering_policy_id" \
        --output json 2>/dev/null)

    if [ -z "$policy_json" ] || [ "$policy_json" = "{}" ]; then
        echo "  ERROR: Could not retrieve steering policy."
        return 1
    fi

    # Check if primary answer is disabled
    local primary_disabled
    primary_disabled=$(echo "$policy_json" | jq -r '.data.answers[] | select(.pool == "primary") | ."is-disabled"' 2>/dev/null)

    if [ "$primary_disabled" = "false" ]; then
        echo "  Primary answer is already enabled. No DNS reset needed."
        return 0
    fi

    echo "  Primary answer is disabled (is_disabled=$primary_disabled). Re-enabling..."

    # Build the updated answers array - enable both primary and secondary
    local updated_answers
    updated_answers=$(echo "$policy_json" | jq '
        .data.answers | map(
            if .pool == "primary" then
                . + {"is-disabled": false}
            else
                . + {"is-disabled": false}
            end
        )
    ' 2>/dev/null)

    if [ -z "$updated_answers" ] || [ "$updated_answers" = "null" ]; then
        echo "  ERROR: Could not build updated answers array."
        return 1
    fi

    # Update the steering policy
    echo "  Updating steering policy..."
    local update_result
    if ! update_result=$(oci dns steering-policy update \
        --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG \
        --steering-policy-id "$steering_policy_id" \
        --answers "$updated_answers" \
        --force 2>&1); then
        log_debug "Steering policy update failed: $update_result"
        echo "  ERROR: Failed to update steering policy."
        echo "         Run 'terraform apply' on the primary workspace to reset DNS."
        return 1
    fi

    echo -e "  ${GREEN}DNS steering policy reset. Primary answer re-enabled.${NC}"

    # Verify the change
    local verify_json
    verify_json=$(oci dns steering-policy get \
        --profile "$PRIMARY_OCI_PROFILE" $OCI_AUTH_FLAG \
        --steering-policy-id "$steering_policy_id" \
        --output json 2>/dev/null)

    local new_primary_disabled
    new_primary_disabled=$(echo "$verify_json" | jq -r '.data.answers[] | select(.pool == "primary") | ."is-disabled"' 2>/dev/null)

    if [ "$new_primary_disabled" = "false" ]; then
        echo "  Verified: Primary answer is now enabled (is_disabled=false)."
    else
        echo "  WARN: Verification failed. Primary answer state: is_disabled=$new_primary_disabled"
    fi

    return 0
}

print_timing_summary() {
    local start="$1" down="${2:-}" alarm="${3:-}" op="${4:-}" pod="${5:-}" snapshot="${6:-}" healthy="${7:-}"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "               DR FAILOVER TIMING SUMMARY"
    echo "════════════════════════════════════════════════════════════════════"
    printf "%-45s %s\n" "Event" "Timestamp (+delta)"
    echo "────────────────────────────────────────────────────────────────────"
    printf "%-45s %s\n" "1. Failover initiated" "$(epoch_to_iso "$start") (+0s)"
    [ -n "$down" ] && printf "%-45s %s\n" "2. Primary LB backends unhealthy" "$(epoch_to_iso "$down") (+$((down - start))s)"
    [ -n "$alarm" ] && printf "%-45s %s\n" "3. OCI Monitoring Alarm FIRING" "$(epoch_to_iso "$alarm") (+$((alarm - start))s)"
    [ -n "$op" ] && printf "%-45s %s\n" "4. Secondary operator scaled 0→1" "$(epoch_to_iso "$op") (+$((op - start))s)"
    [ -n "$pod" ] && printf "%-45s %s\n" "5. Secondary LogScale pod Ready" "$(epoch_to_iso "$pod") (+$((pod - start))s)"
    [ -n "$snapshot" ] && printf "%-45s %s\n" "6. Global snapshot fetched from primary" "$(epoch_to_iso "$snapshot") (+$((snapshot - start))s)"
    [ -n "$healthy" ] && printf "%-45s %s\n" "7. Secondary endpoint healthy (DR complete)" "$(epoch_to_iso "$healthy") (+$((healthy - start))s)"
    echo "────────────────────────────────────────────────────────────────────"

    local total=0
    [ -n "$healthy" ] && total=$((healthy - start)) || { [ -n "$snapshot" ] && total=$((snapshot - start)); } || { [ -n "$pod" ] && total=$((pod - start)); }
    [ "$total" -gt 0 ] && echo "TOTAL FAILOVER TIME: ${total}s (~$((total/60))m $((total%60))s)"

    # Show snapshot recovery time if available
    if [ -n "$pod" ] && [ -n "$snapshot" ]; then
        local snapshot_time=$((snapshot - pod))
        echo "SNAPSHOT RECOVERY TIME: ${snapshot_time}s (from pod ready to snapshot fetched)"
    fi

    # Show alarm trigger latency if both down and alarm are available
    if [ -n "$down" ] && [ -n "$alarm" ]; then
        local alarm_latency=$((alarm - down))
        echo "ALARM TRIGGER LATENCY: ${alarm_latency}s (from LB unhealthy to alarm FIRING)"
    fi

    echo "════════════════════════════════════════════════════════════════════"
}

show_status() {
    echo "=== Cluster Status ==="
    echo ""
    echo "PRIMARY ($PRIMARY_KUBE_CONTEXT):"
    echo "  humio-operator: $(get_operator_replicas "$PRIMARY_KUBE_CONTEXT") replicas"
    get_logscale_pods "$PRIMARY_KUBE_CONTEXT" | sed 's/^/  /' || echo "  (no pods)"
    [ -n "$PRIMARY_FQDN" ] && echo "  Endpoint: HTTP $(check_endpoint_health "$PRIMARY_FQDN")"
    echo ""
    echo "SECONDARY ($SECONDARY_KUBE_CONTEXT):"
    echo "  humio-operator: $(get_operator_replicas "$SECONDARY_KUBE_CONTEXT") replicas"
    get_logscale_pods "$SECONDARY_KUBE_CONTEXT" | sed 's/^/  /' || echo "  (no pods)"
    [ -n "$SECONDARY_FQDN" ] && echo "  Endpoint: HTTP $(check_endpoint_health "$SECONDARY_FQDN")"
    echo ""
    # Health check status
    if [ -n "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" ]; then
        local hc_status=$(get_health_check_status "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID")
        if [ "$hc_status" = "NotFound" ]; then
            echo -e "${YELLOW}Health Check: NOT DEPLOYED (OCID in state but resource doesn't exist)${NC}"
            echo -e "${YELLOW}  Run: terraform apply -var-file=secondary-us-chicago-1.tfvars${NC}"
        else
            echo "Health Check: enabled=$hc_status"
        fi
    elif [ -n "$PRIMARY_HEALTH_CHECK_OCID" ]; then
        local hc_status=$(get_health_check_status "$PRIMARY_HEALTH_CHECK_OCID")
        if [ "$hc_status" = "NotFound" ]; then
            echo -e "${YELLOW}Health Check: NOT DEPLOYED (OCID in state but resource doesn't exist)${NC}"
            echo -e "${YELLOW}  Run: terraform apply -var-file=primary-us-chicago-1.tfvars${NC}"
        else
            echo "Health Check: enabled=$hc_status"
        fi
    else
        echo -e "${YELLOW}Health Check: NOT CONFIGURED (no OCID in Terraform state)${NC}"
    fi
    # DR failover alarm status
    if [ -n "$DR_FAILOVER_ALARM_OCID" ]; then
        local alarm_status=$(get_alarm_status "$DR_FAILOVER_ALARM_OCID")
        if [ "$alarm_status" = "NotFound" ]; then
            echo -e "${YELLOW}DR Alarm: NOT DEPLOYED (OCID in state but resource doesn't exist)${NC}"
        else
            echo "DR Alarm: enabled=$alarm_status"
        fi
    else
        echo -e "${YELLOW}DR Alarm: NOT CONFIGURED (no OCID in Terraform state)${NC}"
    fi
    # Check if nginx-ingress is scaled to 0 (test artifact from primary-down)
    local ingress_scaled_down
    ingress_scaled_down=$(check_nginx_ingress_scaled_down "$PRIMARY_KUBE_CONTEXT" 2>/dev/null || echo "0")
    if [ "${ingress_scaled_down:-0}" -eq 1 ]; then
        echo ""
        echo -e "${YELLOW}Active Test Artifact: nginx-ingress scaled to 0 (run 'failback' to restore)${NC}"
    fi
}

# ============================================================================
# DNS Resolution Functions
# ============================================================================

resolve_a_records() {
    local name="$1"
    [ -z "$name" ] && return 0

    if command -v dig >/dev/null 2>&1; then
        dig +short A "$name" 2>/dev/null | awk 'NF' | sort -u
        return 0
    fi

    if command -v nslookup >/dev/null 2>&1; then
        # nslookup output differs by platform; filter address lines and strip any resolver suffix
        nslookup "$name" 2>/dev/null | awk '/^Address: / {print $2}' | sed 's/#.*//' | awk 'NF' | tail -n +2 | sort -u
        return 0
    fi

    if command -v host >/dev/null 2>&1; then
        host -t A "$name" 2>/dev/null | awk '/ has address /{print $NF}' | awk 'NF' | sort -u
        return 0
    fi

    echo ""
    return 0
}

infer_global_dns_target() {
    local resolved_ip="$1"
    if [ -n "${PRIMARY_INGEST_LB_IP:-}" ] && [ "$resolved_ip" = "$PRIMARY_INGEST_LB_IP" ]; then
        echo "PRIMARY"
        return 0
    fi
    if [ -n "${SECONDARY_INGEST_LB_IP:-}" ] && [ "$resolved_ip" = "$SECONDARY_INGEST_LB_IP" ]; then
        echo "SECONDARY"
        return 0
    fi
    echo "UNKNOWN"
}

show_dns_status() {
    echo "=== DNS Failover Check ==="
    echo ""
    echo "Global hostname:    ${GLOBAL_FQDN:-<unset>}"
    echo "Primary hostname:   ${PRIMARY_FQDN:-<unset>}"
    echo "Secondary hostname: ${SECONDARY_FQDN:-<unset>}"
    echo ""

    if [ -z "${GLOBAL_FQDN:-}" ]; then
        echo -e "${YELLOW}WARN: GLOBAL_FQDN not set (and could not be derived from tfvars).${NC}"
        echo "      Set GLOBAL_FQDN in env or ensure tfvars include global_logscale_hostname + dns_zone_name."
        echo ""
        return 1
    fi

    local global_ips primary_ips secondary_ips
    global_ips=$(resolve_a_records "$GLOBAL_FQDN" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    primary_ips=$(resolve_a_records "$PRIMARY_FQDN" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    secondary_ips=$(resolve_a_records "$SECONDARY_FQDN" | tr '\n' ' ' | sed 's/[[:space:]]*$//')

    echo "Resolved A records:"
    echo "  $GLOBAL_FQDN    -> ${global_ips:-<no A records>}"
    [ -n "${PRIMARY_FQDN:-}" ] && echo "  $PRIMARY_FQDN   -> ${primary_ips:-<no A records>}"
    [ -n "${SECONDARY_FQDN:-}" ] && echo "  $SECONDARY_FQDN -> ${secondary_ips:-<no A records>}"
    echo ""

    echo "Known LB IPs (from Terraform state, best-effort):"
    echo "  PRIMARY_INGEST_LB_IP:   ${PRIMARY_INGEST_LB_IP:-<unknown>}"
    echo "  SECONDARY_INGEST_LB_IP: ${SECONDARY_INGEST_LB_IP:-<unknown>}"
    echo ""

    local first_ip=""
    first_ip=$(resolve_a_records "$GLOBAL_FQDN" | head -n 1 || true)
    local target
    target=$(infer_global_dns_target "$first_ip")

    echo "Global DNS appears to target: $target"
    echo ""
    echo "HTTP status:"
    echo "  https://${GLOBAL_FQDN}/api/v1/status -> $(check_endpoint_health "$GLOBAL_FQDN")"
    return 0
}

# ============================================================================
# LB Health Checker Manipulation (OCI-native, no nginx-ingress required)
# ============================================================================
# These functions modify the OCI Classic LB backend set health checker to
# trigger or resolve unhealthy backend state. This approach:
#   1. Does NOT require nginx-ingress or any specific ingress controller
#   2. Works directly with OCI LB API (same as AWS NLB/ALB health check manipulation)
#   3. Is fully reversible by restoring the original health checker config
#   4. Immediately causes backends to be marked unhealthy/healthy

# Global state for LB health checker restoration
LB_HC_ORIGINAL_PROTOCOL=""
LB_HC_ORIGINAL_PORT=""
LB_HC_ORIGINAL_URL_PATH=""
LB_HC_ORIGINAL_RETURN_CODE=""
LB_HC_ORIGINAL_INTERVAL_MS=""
LB_HC_ORIGINAL_TIMEOUT_MS=""
LB_HC_ORIGINAL_RETRIES=""

modify_lb_health_checker_invalid() {
    # Changes the LB backend set health checker to probe an invalid port,
    # causing all backends to be marked unhealthy.
    local lb_ocid="$1"
    local backend_set_name="${2:-$LB_BACKEND_SET_NAME}"
    local oci_profile="${3:-${PRIMARY_OCI_PROFILE:-DEFAULT}}"

    echo "  Retrieving current LB health checker configuration..."
    local hc_json
    hc_json=$(oci lb health-checker get \
        --load-balancer-id "$lb_ocid" \
        --backend-set-name "$backend_set_name" \
        --profile "$oci_profile" $OCI_AUTH_FLAG 2>/dev/null || echo "")

    if [ -z "$hc_json" ]; then
        echo -e "  ${RED}ERROR: Could not retrieve health checker config${NC}"
        return 1
    fi

    # Save original config for restoration
    LB_HC_ORIGINAL_PROTOCOL=$(jq_parse "$hc_json" '.data.protocol')
    LB_HC_ORIGINAL_PORT=$(jq_parse "$hc_json" '.data.port')
    LB_HC_ORIGINAL_URL_PATH=$(jq_parse "$hc_json" '.data."url-path"')
    LB_HC_ORIGINAL_RETURN_CODE=$(jq_parse "$hc_json" '.data."return-code"')
    LB_HC_ORIGINAL_INTERVAL_MS=$(jq_parse "$hc_json" '.data."interval-in-millis"')
    LB_HC_ORIGINAL_TIMEOUT_MS=$(jq_parse "$hc_json" '.data."timeout-in-millis"')
    LB_HC_ORIGINAL_RETRIES=$(jq_parse "$hc_json" '.data.retries')

    echo "  Original health checker: protocol=${LB_HC_ORIGINAL_PROTOCOL}, port=${LB_HC_ORIGINAL_PORT}"
    echo "  Saved for failback restoration."

    # Change health checker to probe an invalid port (port 1 — nothing listens there)
    # Use shortest interval and timeout for fastest detection
    # --is-force-plain-text true is required because backend SSL is enabled on the LB;
    # without it, health checks attempt a TLS handshake which produces different failure behavior
    echo "  Modifying health checker to invalid port (port 1)..."
    if ! oci lb health-checker update \
        --load-balancer-id "$lb_ocid" \
        --backend-set-name "$backend_set_name" \
        --protocol "TCP" \
        --port 1 \
        --interval-in-millis 10000 \
        --timeout-in-millis 3000 \
        --retries 1 \
        --return-code 200 \
        --response-body-regex ".*" \
        --url-path "/" \
        --is-force-plain-text true \
        --profile "$oci_profile" $OCI_AUTH_FLAG 2>/dev/null; then
        echo -e "  ${RED}ERROR: Failed to update health checker${NC}"
        return 1
    fi

    echo -e "  ${GREEN}Health checker modified → port 1 (invalid). Backends will become CRITICAL.${NC}"
    export LB_HC_MODIFIED="true"
}

restore_lb_health_checker() {
    # Restores the LB backend set health checker to its original configuration.
    local lb_ocid="$1"
    local backend_set_name="${2:-$LB_BACKEND_SET_NAME}"
    local oci_profile="${3:-${PRIMARY_OCI_PROFILE:-DEFAULT}}"

    if [ -z "${LB_HC_ORIGINAL_PROTOCOL:-}" ]; then
        echo "  No saved health checker config. Discovering from Kubernetes service..."
        # Dynamically discover the correct healthCheckNodePort from the LB service
        local hc_node_port
        hc_node_port=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "${NAMESPACE:-logging}" \
            get svc "${PRIMARY_CLUSTER_NAME:-dr-primary}-lb" \
            -o jsonpath='{.spec.healthCheckNodePort}' 2>/dev/null || echo "")
        LB_HC_ORIGINAL_PROTOCOL="HTTP"
        LB_HC_ORIGINAL_PORT="${hc_node_port:-30579}"
        LB_HC_ORIGINAL_INTERVAL_MS="10000"
        LB_HC_ORIGINAL_TIMEOUT_MS="3000"
        LB_HC_ORIGINAL_RETRIES="3"
        echo "  Discovered healthCheckNodePort: ${LB_HC_ORIGINAL_PORT}"
    fi

    echo "  Restoring health checker: protocol=${LB_HC_ORIGINAL_PROTOCOL}, port=${LB_HC_ORIGINAL_PORT}..."

    local update_args=(
        --load-balancer-id "$lb_ocid"
        --backend-set-name "$backend_set_name"
        --protocol "$LB_HC_ORIGINAL_PROTOCOL"
        --port "$LB_HC_ORIGINAL_PORT"
        --interval-in-millis "${LB_HC_ORIGINAL_INTERVAL_MS:-10000}"
        --timeout-in-millis "${LB_HC_ORIGINAL_TIMEOUT_MS:-3000}"
        --retries "${LB_HC_ORIGINAL_RETRIES:-3}"
        --return-code "${LB_HC_ORIGINAL_RETURN_CODE:-200}"
        --response-body-regex ".*"
        --url-path "${LB_HC_ORIGINAL_URL_PATH:-/}"
        --is-force-plain-text true
        --profile "$oci_profile" $OCI_AUTH_FLAG
    )

    if ! oci lb health-checker update "${update_args[@]}" 2>/dev/null; then
        echo -e "  ${RED}ERROR: Failed to restore health checker${NC}"
        return 1
    fi

    echo -e "  ${GREEN}Health checker restored. Backends will recover.${NC}"
    unset LB_HC_MODIFIED
}

# ============================================================================
# V2 Helper Functions: nginx-ingress Scaling (LB-preserving)
# ============================================================================
# These functions scale nginx-ingress deployment to 0 replicas to cause OCI LB
# backend health checks to fail. This approach:
#   1. Keeps the OCI Classic LB intact (no deletion/recreation)
#   2. Preserves the LB IP address and TLS certificates
#   3. Immediately causes LB health checks to fail (backends go CRITICAL)
#   4. Is fully reversible by scaling nginx-ingress back up

scale_nginx_ingress_to_zero() {
    # Scales nginx-ingress to 0 replicas to cause OCI LB backend health checks to fail.
    # The OCI Classic load balancer is NOT deleted - it remains intact with the same IP.
    local context="$1"
    local ingress_ns="${INGRESS_NAMESPACE:-logging-ingress}"

    echo "  Scaling nginx-ingress to 0 replicas to fail LB health checks..."
    echo "  Target namespace: $ingress_ns"

    # Find nginx-ingress deployment
    local ingress_deploy
    ingress_deploy=$(kubectl --context "$context" -n "$ingress_ns" get deployments \
        -l "app.kubernetes.io/name=ingress-nginx" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$ingress_deploy" ]; then
        echo -e "  ${RED}ERROR: nginx-ingress deployment not found in namespace $ingress_ns${NC}"
        return 1
    fi

    # Save current replica count for restoration
    local current_replicas
    current_replicas=$(kubectl --context "$context" -n "$ingress_ns" get deployment "$ingress_deploy" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "2")

    # Export for failback restoration
    export PRIMARY_NGINX_INGRESS_DEPLOY="$ingress_deploy"
    export PRIMARY_NGINX_INGRESS_NS="$ingress_ns"
    export PRIMARY_NGINX_INGRESS_ORIGINAL_REPLICAS="${current_replicas}"

    echo "  Deployment: $ingress_deploy"
    echo "  Current replicas: $current_replicas (saved for failback)"

    # Scale to 0
    kubectl --context "$context" -n "$ingress_ns" scale deployment "$ingress_deploy" --replicas=0

    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo -e "  ${GREEN}nginx-ingress scaled to 0. LB backends will become CRITICAL.${NC}"
        echo "  OCI LB remains intact - IP address preserved."
    else
        echo -e "  ${RED}ERROR: Failed to scale nginx-ingress (exit code: $exit_code)${NC}"
        return 1
    fi
}

restore_nginx_ingress() {
    # Restores nginx-ingress by scaling it back up to original replica count.
    local context="$1"
    local ingress_ns="${INGRESS_NAMESPACE:-logging-ingress}"

    # Scale nginx-ingress back up
    local deploy="${PRIMARY_NGINX_INGRESS_DEPLOY:-}"
    local original_replicas="${PRIMARY_NGINX_INGRESS_ORIGINAL_REPLICAS:-2}"

    if [ -z "$deploy" ]; then
        # Try to find deployment if not exported
        deploy=$(kubectl --context "$context" -n "$ingress_ns" get deployments \
            -l "app.kubernetes.io/name=ingress-nginx" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi

    if [ -n "$deploy" ]; then
        echo "  Scaling nginx-ingress back to $original_replicas replicas..."
        kubectl --context "$context" -n "$ingress_ns" scale deployment "$deploy" --replicas="$original_replicas"
        echo -e "  ${GREEN}nginx-ingress restored to $original_replicas replicas.${NC}"
    else
        echo -e "  ${YELLOW}WARN: Could not find nginx-ingress deployment to restore.${NC}"
    fi
    echo "  Done."
}

check_nginx_ingress_scaled_down() {
    # Checks if nginx-ingress is scaled to 0.
    # Returns "1" if scaled to 0, "0" otherwise.
    local context="$1"
    local ingress_ns="${INGRESS_NAMESPACE:-logging-ingress}"

    local current_replicas
    current_replicas=$(kubectl --context "$context" -n "$ingress_ns" get deployments \
        -l "app.kubernetes.io/name=ingress-nginx" -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo "1")

    if [ "${current_replicas:-1}" -eq 0 ]; then
        echo "1"
    else
        echo "0"
    fi
}

# Legacy function names for backward compatibility
apply_ingress_block_policy() {
    scale_nginx_ingress_to_zero "$@"
}

remove_ingress_block_policy() {
    restore_nginx_ingress "$@"
}

check_ingress_block_active() {
    check_nginx_ingress_scaled_down "$@"
}

delete_ingress_pods_for_faster_detection() {
    # No longer needed - nginx-ingress is scaled to 0, so no pods exist
    echo "  Note: Pod deletion not needed (nginx-ingress scaled to 0)."
}

# ============================================================================
# V2 Helper Functions: LogScale Crash Scenario
# ============================================================================

get_logscale_pod_name() {
    # Returns the name of the first LogScale pod
    local context="$1"
    kubectl --context "$context" -n "$NAMESPACE" get pods \
        -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

crash_logscale_process() {
    # Crashes LogScale using the specified mode
    local context="$1"
    local mode="$2"
    local pod=$(get_logscale_pod_name "$context")

    if [ -z "$pod" ]; then
        echo -e "${RED}ERROR: No LogScale pod found${NC}" >&2
        return 1
    fi

    echo "  Target pod: $pod"
    echo "  Crash mode: $mode"

    case "$mode" in
        kill-process)
            echo "  Killing main process (PID 1)..."
            kubectl --context "$context" -n "$NAMESPACE" exec "$pod" -- kill -9 1 2>/dev/null || true
            ;;
        block-health)
            echo "  Blocking health endpoint (port 8080) with iptables..."
            kubectl --context "$context" -n "$NAMESPACE" exec "$pod" -- \
                iptables -A INPUT -p tcp --dport 8080 -j DROP 2>/dev/null || {
                echo -e "${YELLOW}  WARN: iptables may not be available, trying alternative...${NC}"
                # Alternative: block via environment manipulation
                kubectl --context "$context" -n "$NAMESPACE" exec "$pod" -- \
                    bash -c 'echo "127.0.0.1 localhost" > /etc/hosts' 2>/dev/null || true
            }
            ;;
        oom)
            echo "  Triggering OutOfMemory condition..."
            echo -e "${YELLOW}  WARNING: This will cause the container to be OOM-killed${NC}"
            kubectl --context "$context" -n "$NAMESPACE" exec "$pod" -- \
                bash -c 'arr=(); while true; do arr+=("$(head -c 10M /dev/zero)"); done' 2>/dev/null &
            ;;
        *)
            echo -e "${RED}ERROR: Unknown crash mode: $mode${NC}" >&2
            echo "  Valid modes: kill-process, block-health, oom"
            return 1
            ;;
    esac
    return 0
}

restore_logscale_health_endpoint() {
    # Restores health endpoint if it was blocked
    local context="$1"
    local pod=$(get_logscale_pod_name "$context")

    if [ -z "$pod" ]; then
        echo "  No LogScale pod found (may have been restarted)"
        return 0
    fi

    echo "  Attempting to restore health endpoint on $pod..."
    # Remove iptables rule if it exists
    kubectl --context "$context" -n "$NAMESPACE" exec "$pod" -- \
        iptables -D INPUT -p tcp --dport 8080 -j DROP 2>/dev/null || true
    echo "  Done (rule removed if existed)."
}

# ============================================================================
# V2 Helper Functions: Storage Failure Scenario
# ============================================================================

apply_storage_block_policy() {
    # Applies NetworkPolicy to block Object Storage access
    local context="$1"
    local policy_file="$SCRIPT_DIR/network-policies/block-object-storage.yaml"

    if [ ! -f "$policy_file" ]; then
        echo "  Creating NetworkPolicy inline (template not found)..."
        kubectl --context "$context" -n "$NAMESPACE" apply -f - <<'NETPOL_EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-object-storage
  labels:
    dr-test: "true"
    scenario: "storage-failure"
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: humio
  policyTypes:
  - Egress
  egress:
  # Allow DNS
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # Allow Kafka (internal cluster communication)
  - to:
    - podSelector:
        matchLabels:
          strimzi.io/kind: Kafka
  # Allow Kubernetes API
  - to:
    - ipBlock:
        cidr: 10.0.0.0/8
  # Block OCI Object Storage by allowing everything else EXCEPT storage endpoints
  # OCI Object Storage uses objectstorage.<region>.oraclecloud.com
  # Since we can't easily enumerate all IPs, we block by NOT including storage in allow rules
NETPOL_EOF
    else
        kubectl --context "$context" -n "$NAMESPACE" apply -f "$policy_file"
    fi
}

remove_storage_block_policy() {
    # Removes the storage blocking NetworkPolicy
    local context="$1"
    echo "  Removing NetworkPolicy: block-object-storage..."
    kubectl --context "$context" -n "$NAMESPACE" delete networkpolicy block-object-storage --ignore-not-found=true
}

check_storage_block_active() {
    # Checks if storage block NetworkPolicy is active
    local context="$1"
    kubectl --context "$context" -n "$NAMESPACE" get networkpolicy block-object-storage --no-headers 2>/dev/null | wc -l | tr -d ' ' || true
}

cleanup_test_artifacts() {
    # Cleans up all test artifacts from DR simulations
    local context="$1"
    echo "  Cleaning up test artifacts on $context..."

    # Restore nginx-ingress if scaled to 0
    local ingress_scaled_down
    ingress_scaled_down=$(check_nginx_ingress_scaled_down "$context" 2>/dev/null || echo "0")
    if [ "${ingress_scaled_down:-0}" -eq 1 ]; then
        echo "  Restoring nginx-ingress..."
        restore_nginx_ingress "$context"
    fi

    # Restore health endpoint if blocked
    restore_logscale_health_endpoint "$context" 2>/dev/null || true

    echo "  Test artifacts cleaned up."
}

# ============================================================================
# V2 Scenario: LogScale Crash
# ============================================================================

simulate_logscale_crash() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: LOGSCALE-CRASH (Catastrophic failure - all pods)${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will:"
    echo "  1. Scale PRIMARY humio-operator to 0 (prevent pod restart)"
    echo "  2. Delete ALL LogScale pods (simulate catastrophic crash)"
    echo "  3. HTTP health check on healthCheckNodePort detects missing pods (503)"
    echo "  4. OCI Monitoring Alarm triggers → ONS → Function invoked"
    echo "  5. Track DR failover milestones (operator scaling, pod ready, snapshot fetch)"
    echo ""
    echo -e "${YELLOW}NOTE: With HTTP HC on healthCheckNodePort, all 15 backends will${NC}"
    echo -e "${YELLOW}      return 503 once pods are gone, triggering the alarm naturally.${NC}"
    echo ""

    show_status

    # Verify LogScale pods exist before crashing
    local pod_count
    pod_count=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" get pods \
        -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${pod_count:-0}" -eq 0 ]; then
        echo -e "${RED}ERROR: No LogScale pods found on PRIMARY cluster${NC}"
        echo "Ensure LogScale is running before testing crash scenarios."
        return 1
    fi
    echo ""
    echo "  LogScale pods on PRIMARY: $pod_count"

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  INITIATING LOGSCALE-CRASH SIMULATION${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local start=$(date +%s)

    # Step 1: Scale operator to 0 (prevent pod restart after crash)
    print_step_header "Step 1: Scaling PRIMARY humio-operator to 0 (prevent restart)..." "$start"
    scale_operator "$PRIMARY_KUBE_CONTEXT" 0 "PRIMARY"
    print_step_line "${GREEN}  Done.${NC}" "+$(($(date +%s) - start))s"

    # Step 1b: Delete ALL LogScale pods (catastrophic crash simulation)
    echo ""
    print_step_header "Step 1b: Deleting ALL PRIMARY LogScale pods..." "$start"
    print_step_line "  Simulating catastrophic crash - all $pod_count pods terminated."
    kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
        -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
        --force --grace-period=0 2>/dev/null || \
    kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
        -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator"
    print_step_line "${GREEN}  All LogScale pods deleted.${NC}" "+$(($(date +%s) - start))s"

    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "               TRACKING DR FAILOVER MILESTONES"
    echo "════════════════════════════════════════════════════════════════════"
    echo "Timeout: ${FAILOVER_TIMEOUT_SECONDS}s"
    echo ""

    local primary_down_epoch="" op="" pod_ready="" snapshot="" healthy=""

    # Step 2: Wait for PRIMARY LB backends to become unhealthy (natural HTTP HC detection)
    print_step_header "Step 2: Waiting for PRIMARY LB backends to become unhealthy..." "$start"
    print_step_line "  HTTP HC on healthCheckNodePort will detect missing pods (503 on all nodes)."
    if [ -n "$PRIMARY_LB_OCID" ] && [ "$PRIMARY_LB_OCID" != "null" ] && \
       [ -n "$PRIMARY_COMPARTMENT_OCID" ] && [ "$PRIMARY_COMPARTMENT_OCID" != "null" ]; then
        primary_down_epoch=$(wait_for_lb_backends_unhealthy \
            "$PRIMARY_LB_OCID" \
            "$PRIMARY_COMPARTMENT_OCID" \
            "$start" \
            "${PRIMARY_OCI_PROFILE:-DEFAULT}" \
            "$LB_BACKEND_SET_NAME") || primary_down_epoch=""
    else
        print_step_line "  ${YELLOW}Skipped (PRIMARY_LB_OCID or PRIMARY_COMPARTMENT_OCID not configured).${NC}"
    fi

    # Step 3: Wait for secondary operator to scale
    echo ""
    print_step_header "Step 3: Waiting for SECONDARY humio-operator to scale 0→1..." "$start"
    print_step_line "  (OCI Monitoring Alarm + Function invocation)"
    op=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start") || op=""

    # Step 4: Wait for secondary pod to be ready
    echo ""
    print_step_header "Step 4: Waiting for SECONDARY LogScale pod to become Ready..." "$start"
    pod_ready=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start") || pod_ready=""

    # Step 5: Track snapshot fetch from primary bucket
    echo ""
    print_step_header "Step 5: Tracking global snapshot fetch from primary bucket..." "$start"
    snapshot=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start") || snapshot=""

    # Step 6: Wait for secondary LB backends to be healthy
    echo ""
    print_step_header "Step 6: Waiting for SECONDARY endpoint to become healthy..." "$start"
    local snapshot_confirmed="false"
    [ -n "$snapshot" ] && snapshot_confirmed="true"
    if [ -n "$SECONDARY_FQDN" ]; then
        healthy=$(wait_for_endpoint_healthy "$SECONDARY_FQDN" "$start" "$snapshot_confirmed") || healthy=""
    fi

    print_timing_summary "$start" "$primary_down_epoch" "" "$op" "$pod_ready" "$snapshot" "$healthy"

    echo ""
    echo -e "${YELLOW}NOTE: Primary operator is scaled to 0. Pods will NOT auto-restart.${NC}"
    echo -e "${YELLOW}      Run 'failback' to restore primary operation.${NC}"
    echo ""
    show_status
}

# ============================================================================
# V2 Scenario: Storage Failure
# ============================================================================

simulate_storage_failure() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: STORAGE-FAILURE (Block Object Storage)${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will:"
    echo "  1. Apply NetworkPolicy blocking OCI Object Storage access"
    echo "  2. LogScale cannot persist segments to Object Storage"
    echo "  3. Ingest queue backs up → latency increases"
    echo "  4. Wait for health degradation (may take 5-10 minutes)"
    echo "  5. Track DR failover milestones"
    echo ""
    echo -e "${YELLOW}WARNING: This applies a NetworkPolicy to PRIMARY cluster!${NC}"
    echo -e "${YELLOW}         Use 'failback' to remove the policy and restore access.${NC}"
    echo ""
    echo -e "${CYAN}Expected timeline: 7-12 minutes to DR trigger${NC}"
    echo ""

    show_status

    # Check if policy already exists
    local existing=$(check_storage_block_active "$PRIMARY_KUBE_CONTEXT")
    if [ "${existing:-0}" -gt 0 ]; then
        echo -e "${YELLOW}WARNING: Storage block NetworkPolicy already active!${NC}"
        echo "Remove it with 'failback' before re-running this scenario."
        return 1
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  INITIATING STORAGE-FAILURE SIMULATION${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local start=$(date +%s)

    # Step 1: Apply NetworkPolicy
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 1: Applying NetworkPolicy to block Object Storage..."
    echo "────────────────────────────────────────────────────────────────────"
    apply_storage_block_policy "$PRIMARY_KUBE_CONTEXT"
    echo -e "${GREEN}  NetworkPolicy applied.${NC}"

    # Step 2: Monitor for storage errors
    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 2: Monitoring LogScale logs for storage errors..."
    echo "────────────────────────────────────────────────────────────────────"
    echo "  (Storage errors should appear within 30-120 seconds)"

    local pod=$(get_logscale_pod_name "$PRIMARY_KUBE_CONTEXT")
    local storage_error_seen=""
    local error_check_deadline=$((start + 180))  # 3 minute check for storage errors

    while [ "$(date +%s)" -lt "$error_check_deadline" ]; do
        local now=$(date +%s)
        local delta=$((now - start))
        local errors=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" \
            logs "$pod" --tail=100 --since=60s 2>/dev/null | grep -ciE "storage|s3|bucket|object.*storage|timeout.*upload" || true)
        if [ "${errors:-0}" -gt 0 ]; then
            echo -e "${GREEN}  Storage errors detected in logs (+${delta}s)${NC}"
            storage_error_seen=$(date +%s)
            break
        fi
        echo "  Checking logs for storage errors... (+${delta}s)"
        sleep 15
    done

    if [ -z "$storage_error_seen" ]; then
        echo -e "${YELLOW}  WARN: No explicit storage errors seen in logs, continuing...${NC}"
        echo "  (LogScale may still fail due to blocked storage)"
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "               TRACKING DR FAILOVER MILESTONES"
    echo "════════════════════════════════════════════════════════════════════"
    echo "Timeout: ${FAILOVER_TIMEOUT_SECONDS}s (storage failure may take longer)"
    echo ""

    local primary_down_epoch="" op="" pod_ready="" snapshot="" healthy=""

    # Step 3: Trigger DR via LB health checker manipulation
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 3: Storage failure confirmed. Modifying LB HC to trigger DR..."
    echo "────────────────────────────────────────────────────────────────────"
    echo "  Note: Storage failure doesn't crash pods, so HTTP HC still passes."
    echo "  Manually triggering DR by setting HC to invalid port."
    if [ -n "$PRIMARY_LB_OCID" ] && [ "$PRIMARY_LB_OCID" != "null" ]; then
        if ! modify_lb_health_checker_invalid "$PRIMARY_LB_OCID" "$LB_BACKEND_SET_NAME" "${PRIMARY_OCI_PROFILE:-DEFAULT}"; then
            echo -e "${YELLOW}WARN: Failed to modify LB health checker. Continuing...${NC}"
        fi
    else
        echo -e "${YELLOW}WARN: PRIMARY_LB_OCID not set. Skipping.${NC}"
    fi

    # Step 3b: Wait for backends to become unhealthy
    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 3b: Waiting for PRIMARY LB backends to become unhealthy..."
    echo "────────────────────────────────────────────────────────────────────"
    if [ -n "$PRIMARY_LB_OCID" ] && [ "$PRIMARY_LB_OCID" != "null" ] && \
       [ -n "$PRIMARY_COMPARTMENT_OCID" ] && [ "$PRIMARY_COMPARTMENT_OCID" != "null" ]; then
        primary_down_epoch=$(wait_for_lb_backends_unhealthy \
            "$PRIMARY_LB_OCID" \
            "$PRIMARY_COMPARTMENT_OCID" \
            "$start" \
            "${PRIMARY_OCI_PROFILE:-DEFAULT}" \
            "$LB_BACKEND_SET_NAME") || primary_down_epoch=""
    else
        echo -e "  ${YELLOW}Skipped (OCIDs not configured).${NC}"
    fi

    # Step 4: Wait for secondary operator to scale
    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 4: Waiting for SECONDARY humio-operator to scale 0→1..."
    echo "────────────────────────────────────────────────────────────────────"
    op=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start") || op=""

    # Step 5: Wait for secondary pod to be ready
    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 5: Waiting for SECONDARY LogScale pod to become Ready..."
    echo "────────────────────────────────────────────────────────────────────"
    pod_ready=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start") || pod_ready=""

    # Step 6: Track snapshot fetch from primary bucket
    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 6: Tracking global snapshot fetch from primary bucket..."
    echo "────────────────────────────────────────────────────────────────────"
    snapshot=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start") || snapshot=""

    # Step 7: Wait for secondary endpoint to be healthy
    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 7: Waiting for SECONDARY endpoint to become healthy..."
    echo "────────────────────────────────────────────────────────────────────"
    # If snapshot was confirmed in Step 6, extend the timeout for LogScale initialization
    local snapshot_confirmed="false"
    [ -n "$snapshot" ] && snapshot_confirmed="true"
    [ -n "$SECONDARY_FQDN" ] && healthy=$(wait_for_endpoint_healthy "$SECONDARY_FQDN" "$start" "$snapshot_confirmed") || healthy=""

    print_timing_summary "$start" "$primary_down_epoch" "" "$op" "$pod_ready" "$snapshot" "$healthy"

    echo ""
    echo -e "${YELLOW}IMPORTANT: NetworkPolicy is still blocking Object Storage!${NC}"
    echo -e "${YELLOW}           Run 'failback' to remove policy and restore access.${NC}"
    echo ""
    show_status
}

# ============================================================================
# Scenario Functions (Original)
# ============================================================================

simulate_primary_down() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: PRIMARY-DOWN (Scale primary operator to 0)${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will:"
    echo "  1. Scale PRIMARY humio-operator to 0 (LogScale pods terminate)"
    echo "  2. Wait for PRIMARY LB backends to become unhealthy (OCI Monitoring metrics)"
    echo "  3. OCI Monitoring Alarm triggers → ONS Topic → Function invoked"
    echo "  4. OCI Function scales SECONDARY humio-operator 0→1"
    echo "  5. Secondary LogScale recovers from primary Object Storage bucket"
    echo ""
    echo -e "${YELLOW}WARNING: This modifies the PRIMARY cluster! Use 'failback' to restore.${NC}"
    echo ""

    # Show current status
    show_status

    local current_primary_replicas
    current_primary_replicas=$(get_operator_replicas "$PRIMARY_KUBE_CONTEXT")

    if [ "${current_primary_replicas:-0}" -eq 0 ]; then
        echo -e "${YELLOW}WARN: Primary humio-operator is already at 0 replicas.${NC}"
        echo ""
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  INITIATING PRIMARY-DOWN SIMULATION${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local start=$(date +%s)

    print_step_header "Step 1: Scaling PRIMARY humio-operator to 0..." "$start"
    print_step_line "  Action: kubectl --context $PRIMARY_KUBE_CONTEXT -n $NAMESPACE scale deployment humio-operator --replicas=0"
    scale_operator "$PRIMARY_KUBE_CONTEXT" 0 "PRIMARY"
    print_step_line "${GREEN}  Done.${NC}" "+$(($(date +%s) - start))s"

    echo ""
    print_step_header "Step 1b: Deleting PRIMARY LogScale pods to simulate failure..." "$start"
    print_step_line "  Note: Scaling operator to 0 does NOT delete managed pods."
    print_step_line "  Deleting pods to trigger actual endpoint failure."
    kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
        -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator" \
        --force --grace-period=0 2>/dev/null || \
    kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
        -l "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator"
    print_step_line "${GREEN}  LogScale pods deleted.${NC}" "+$(($(date +%s) - start))s"

    echo ""
    print_step_header "Step 1c: Modifying LB health checker to fail backends..." "$start"
    print_step_line "  Changing LB backend health checker to invalid port."
    print_step_line "  This approach:"
    print_step_line "    - Immediately causes OCI LB backend health checks to fail (CRITICAL)"
    print_step_line "    - Keeps OCI Classic LB intact (no deletion/recreation)"
    print_step_line "    - Preserves LB IP address and TLS certificates"
    print_step_line "    - Is fully reversible by restoring the health checker config"
    echo ""
    if [ -n "$PRIMARY_LB_OCID" ] && [ "$PRIMARY_LB_OCID" != "null" ]; then
        if ! modify_lb_health_checker_invalid "$PRIMARY_LB_OCID" "$LB_BACKEND_SET_NAME" "${PRIMARY_OCI_PROFILE:-DEFAULT}"; then
            echo -e "${YELLOW}WARN: Failed to modify LB health checker. Continuing...${NC}"
        fi
    else
        echo -e "${YELLOW}WARN: PRIMARY_LB_OCID not set. Skipping health checker modification.${NC}"
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    print_step_line "               TRACKING DR FAILOVER MILESTONES" "+$(($(date +%s) - start))s"
    echo "════════════════════════════════════════════════════════════════════"
    echo "Timeout: ${FAILOVER_TIMEOUT_SECONDS}s"
    echo ""

    local primary_down_epoch="" alarm_fired_epoch="" op="" pod="" snapshot="" healthy=""

    # Step 2: Wait for PRIMARY LB backends to become unhealthy
    print_step_header "Step 2: Waiting for PRIMARY LB backends to become unhealthy..." "$start"
    print_step_line "  Using OCI Monitoring metrics (oci_lbaas.UnHealthyBackendServers)"
    if [ -n "$PRIMARY_LB_OCID" ] && [ "$PRIMARY_LB_OCID" != "null" ] && \
       [ -n "$PRIMARY_COMPARTMENT_OCID" ] && [ "$PRIMARY_COMPARTMENT_OCID" != "null" ]; then
        primary_down_epoch=$(wait_for_lb_backends_unhealthy \
            "$PRIMARY_LB_OCID" \
            "$PRIMARY_COMPARTMENT_OCID" \
            "$start" \
            "${PRIMARY_OCI_PROFILE:-DEFAULT}" \
            "$LB_BACKEND_SET_NAME") || primary_down_epoch=""
    else
        print_step_line "  ${YELLOW}Skipped (PRIMARY_LB_OCID or PRIMARY_COMPARTMENT_OCID not configured).${NC}" "+$(($(date +%s) - start))s"
    fi

    echo ""
    print_step_header "Step 3: Waiting for OCI Monitoring Alarm to trigger..." "$start"
    print_step_line "  Alarm monitors LB backend health, triggers after consecutive failures."
    print_step_line "  Expected wait: 60-180 seconds for alarm to fire and invoke function."
    echo ""
    if [ -n "$DR_FAILOVER_ALARM_OCID" ] && [ "$DR_FAILOVER_ALARM_OCID" != "null" ] && \
       [ -n "$PRIMARY_COMPARTMENT_OCID" ] && [ "$PRIMARY_COMPARTMENT_OCID" != "null" ]; then
        alarm_fired_epoch=$(wait_for_alarm_firing \
            "$DR_FAILOVER_ALARM_OCID" \
            "$PRIMARY_COMPARTMENT_OCID" \
            "$start" \
            "${SECONDARY_OCI_PROFILE:-DEFAULT}") || alarm_fired_epoch=""
    else
        print_step_line "  ${YELLOW}Skipped (DR_FAILOVER_ALARM_OCID or PRIMARY_COMPARTMENT_OCID not configured).${NC}" "+$(($(date +%s) - start))s"
        print_step_line "    DR_FAILOVER_ALARM_OCID: ${DR_FAILOVER_ALARM_OCID:-<not set>}"
        print_step_line "    PRIMARY_COMPARTMENT_OCID: ${PRIMARY_COMPARTMENT_OCID:-<not set>}"
    fi

    echo ""
    print_step_header "Step 4: Waiting for SECONDARY humio-operator to scale 0→1..." "$start"
    op=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start") || op=""

    echo ""
    print_step_header "Step 5: Waiting for SECONDARY LogScale pod to become Ready..." "$start"
    pod=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start") || pod=""

    echo ""
    print_step_header "Step 6: Tracking global snapshot fetch from primary bucket..." "$start"
    snapshot=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start") || snapshot=""

    echo ""
    print_step_header "Step 7: Waiting for SECONDARY endpoint to become healthy..." "$start"
    # If snapshot was confirmed in Step 6, extend the timeout for LogScale initialization
    local snapshot_confirmed="false"
    [ -n "$snapshot" ] && snapshot_confirmed="true"
    [ -n "$SECONDARY_FQDN" ] && healthy=$(wait_for_endpoint_healthy "$SECONDARY_FQDN" "$start" "$snapshot_confirmed") || healthy=""

    print_timing_summary "$start" "$primary_down_epoch" "$alarm_fired_epoch" "$op" "$pod" "$snapshot" "$healthy"

    echo ""
    echo -e "${YELLOW}IMPORTANT: Primary humio-operator is still at 0 replicas.${NC}"
    echo -e "${YELLOW}           Run 'failback' to restore primary and reset secondary.${NC}"
    echo ""
    show_status
}

simulate_failover() {
    # Detect monitoring mode: use LB mode if explicitly set or health check OCID is unavailable
    local use_lb_mode="false"
    if [ "$DR_MONITORING_MODE" = "lb_health" ] || \
       { [ -z "${EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID:-}" ] || [ "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" = "null" ]; }; then
        use_lb_mode="true"
    fi

    if [ "$use_lb_mode" = "true" ]; then
        simulate_failover_lb_mode
    else
        simulate_failover_hc_mode
    fi
}

simulate_failover_lb_mode() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: FAILOVER (via LB Backend Health)${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will:"
    echo "  1. Modify LB health checker to invalid port (backends become unhealthy)"
    echo "  2. OCI Monitoring Alarm fires (unhealthyBackendServers > 0)"
    echo "  3. ONS Topic → OCI Function scales SECONDARY humio-operator 0→1"
    echo "  4. Secondary LogScale recovers from primary Object Storage bucket"
    echo ""
    echo -e "${GREEN}ADVANTAGE: Non-invasive to LogScale - primary pods stay running.${NC}"
    echo -e "${GREEN}           Only LB health checker is modified (same as AWS/Azure/GCP pattern).${NC}"
    echo ""
    echo -e "${CYAN}NOTE: Primary humio-operator is NOT modified. Only LB health checker is changed.${NC}"
    echo ""

    if [ -z "$PRIMARY_LB_OCID" ] || [ "$PRIMARY_LB_OCID" = "null" ]; then
        echo -e "${RED}ERROR: PRIMARY_LB_OCID not found in Terraform state${NC}"
        echo "Please ensure the primary cluster is fully deployed."
        return 1
    fi

    # Show current status
    show_status

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  INITIATING DR FAILOVER (via LB Backend Health)${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local start=$(date +%s)

    print_step_header "Step 1: Modifying LB health checker to invalid port..." "$start"
    if ! modify_lb_health_checker_invalid "$PRIMARY_LB_OCID" "$LB_BACKEND_SET_NAME" "${PRIMARY_OCI_PROFILE:-DEFAULT}"; then
        echo -e "${RED}ERROR: Failed to modify LB health checker${NC}"
        return 1
    fi
    print_step_line "${GREEN}  Done. LB backends will become CRITICAL.${NC}" "+$(($(date +%s) - start))s"

    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    print_step_line "               TRACKING DR FAILOVER MILESTONES" "+$(($(date +%s) - start))s"
    echo "════════════════════════════════════════════════════════════════════"
    echo "Timeout: ${FAILOVER_TIMEOUT_SECONDS}s"
    echo ""

    local primary_down_epoch="" alarm_fired_epoch="" op="" pod="" snapshot="" healthy=""

    print_step_header "Step 2: Waiting for PRIMARY LB backends to become unhealthy..." "$start"
    print_step_line "  Using OCI Monitoring metrics (oci_lbaas.UnHealthyBackendServers)"
    if [ -n "$PRIMARY_LB_OCID" ] && [ "$PRIMARY_LB_OCID" != "null" ] && \
       [ -n "$PRIMARY_COMPARTMENT_OCID" ] && [ "$PRIMARY_COMPARTMENT_OCID" != "null" ]; then
        primary_down_epoch=$(wait_for_lb_backends_unhealthy \
            "$PRIMARY_LB_OCID" \
            "$PRIMARY_COMPARTMENT_OCID" \
            "$start" \
            "${PRIMARY_OCI_PROFILE:-DEFAULT}" \
            "$LB_BACKEND_SET_NAME") || primary_down_epoch=""
    else
        print_step_line "  ${YELLOW}Skipped (PRIMARY_COMPARTMENT_OCID not configured).${NC}" "+$(($(date +%s) - start))s"
    fi

    echo ""
    print_step_header "Step 3: Waiting for OCI Monitoring Alarm to trigger..." "$start"
    print_step_line "  Alarm monitors LB backend health, triggers after consecutive failures."
    echo ""
    if [ -n "$DR_FAILOVER_ALARM_OCID" ] && [ "$DR_FAILOVER_ALARM_OCID" != "null" ] && \
       [ -n "$PRIMARY_COMPARTMENT_OCID" ] && [ "$PRIMARY_COMPARTMENT_OCID" != "null" ]; then
        alarm_fired_epoch=$(wait_for_alarm_firing \
            "$DR_FAILOVER_ALARM_OCID" \
            "$PRIMARY_COMPARTMENT_OCID" \
            "$start" \
            "${SECONDARY_OCI_PROFILE:-DEFAULT}") || alarm_fired_epoch=""
    else
        print_step_line "  ${YELLOW}Skipped (DR_FAILOVER_ALARM_OCID not configured).${NC}" "+$(($(date +%s) - start))s"
    fi

    echo ""
    print_step_header "Step 4: Waiting for SECONDARY humio-operator to scale 0→1..." "$start"
    op=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start") || op=""

    echo ""
    print_step_header "Step 5: Waiting for SECONDARY LogScale pod to become Ready..." "$start"
    pod=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start") || pod=""

    echo ""
    print_step_header "Step 6: Tracking global snapshot fetch from primary bucket..." "$start"
    snapshot=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start") || snapshot=""

    echo ""
    print_step_header "Step 7: Waiting for SECONDARY endpoint to become healthy..." "$start"
    local snapshot_confirmed="false"
    [ -n "$snapshot" ] && snapshot_confirmed="true"
    [ -n "$SECONDARY_FQDN" ] && healthy=$(wait_for_endpoint_healthy "$SECONDARY_FQDN" "$start" "$snapshot_confirmed") || healthy=""

    print_timing_summary "$start" "$primary_down_epoch" "$alarm_fired_epoch" "$op" "$pod" "$snapshot" "$healthy"

    echo ""
    echo -e "${YELLOW}IMPORTANT: LB health checker is still set to invalid port on primary.${NC}"
    echo -e "${YELLOW}           Run 'failback' to restore the health checker and reset secondary.${NC}"
    echo ""
    show_status
}

simulate_failover_hc_mode() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: FAILOVER (via Health Check Path Manipulation)${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will:"
    echo "  1. Save the current health check path"
    echo "  2. Change health check path to an invalid endpoint (/dr-failover-test-invalid)"
    echo "  3. Health check stays ENABLED but reports UNHEALTHY"
    echo "  4. OCI Monitoring Alarm fires (mean() < 1 condition)"
    echo "  5. OCI Function scales SECONDARY humio-operator 0→1"
    echo "  6. Secondary LogScale recovers from primary Object Storage bucket"
    echo ""
    echo -e "${GREEN}ADVANTAGE: This approach produces failing metrics (HTTP.isHealthy=0)${NC}"
    echo -e "${GREEN}           instead of absent metrics, ensuring consistent alarm behavior.${NC}"
    echo ""
    echo -e "${CYAN}NOTE: Primary humio-operator is NOT modified by this script.${NC}"
    echo -e "${CYAN}      Failover is triggered via OCI Health Check path manipulation only.${NC}"
    echo ""

    if [ -z "${EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID:-}" ] || [ "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" = "null" ]; then
        echo -e "${RED}ERROR: DR alarm primary health check OCID not found in Terraform state${NC}"
        echo ""
        echo "The health check resource may not be deployed yet."
        echo "Please ensure the DR infrastructure is fully deployed:"
        echo "  terraform workspace select secondary"
        echo "  terraform apply -var-file=secondary-us-chicago-1.tfvars"
        return 1
    fi

    # Verify health check exists
    local hc_status=$(get_health_check_status "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID")
    if [ "$hc_status" = "NotFound" ]; then
        echo -e "${RED}ERROR: Health check not found (OCID: $EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID)${NC}"
        echo ""
        echo "The health check may have been deleted or the OCID is stale."
        echo "Re-run terraform apply to recreate the health check resource."
        return 1
    fi

    # Get the current path to save for later restoration
    local current_path=$(get_health_check_path "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID")
    if [ -z "$current_path" ]; then
        echo -e "${RED}ERROR: Could not retrieve current health check path${NC}"
        return 1
    fi
    PRIMARY_HEALTH_CHECK_ORIGINAL_PATH="$current_path"
    echo "Current health check path: $current_path"

    # Show current status
    show_status

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  INITIATING DR FAILOVER (via Health Check Path Manipulation)${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local start=$(date +%s)

    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 1: Changing health check path to invalid endpoint..."
    echo "────────────────────────────────────────────────────────────────────"
    echo "  Original path: $current_path"
    if ! set_health_check_path "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" "/dr-failover-test-invalid-endpoint"; then
        echo -e "${RED}ERROR: Failed to change health check path${NC}"
        echo "You may need to check IAM permissions or network connectivity."
        return 1
    fi
    echo -e "${GREEN}  Health check path changed. Alarm should fire within 60-120 seconds.${NC}"
    echo -e "${GREEN}  (Health check will return 404, triggering mean() < 1 condition)${NC}"

    echo ""
    echo "=== Tracking DR Failover Milestones ==="
    echo "Timeout: ${FAILOVER_TIMEOUT_SECONDS}s"
    echo ""

    local op="" pod="" snapshot="" healthy=""

    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 2: Waiting for SECONDARY humio-operator to scale 0→1..."
    echo "────────────────────────────────────────────────────────────────────"
    op=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start") || op=""

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 3: Waiting for SECONDARY LogScale pod to become Ready..."
    echo "────────────────────────────────────────────────────────────────────"
    pod=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start") || pod=""

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 4: Tracking global snapshot fetch from primary bucket..."
    echo "────────────────────────────────────────────────────────────────────"
    snapshot=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start") || snapshot=""

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 5: Waiting for SECONDARY endpoint to become healthy..."
    echo "────────────────────────────────────────────────────────────────────"
    # If snapshot was confirmed in Step 4, extend the timeout for LogScale initialization
    local snapshot_confirmed="false"
    [ -n "$snapshot" ] && snapshot_confirmed="true"
    [ -n "$SECONDARY_FQDN" ] && healthy=$(wait_for_endpoint_healthy "$SECONDARY_FQDN" "$start" "$snapshot_confirmed") || healthy=""

    print_timing_summary "$start" "" "" "$op" "$pod" "$snapshot" "$healthy"
    echo -e "${YELLOW}IMPORTANT: Health check path is still set to invalid endpoint.${NC}"
    echo -e "${YELLOW}           Original path was: $PRIMARY_HEALTH_CHECK_ORIGINAL_PATH${NC}"
    echo -e "${YELLOW}           Run 'failback' to restore the correct path.${NC}"
    show_status
}

simulate_region_down() {
    # Detect monitoring mode: use LB mode if explicitly set or health check OCID is unavailable
    local use_lb_mode="false"
    if [ "$DR_MONITORING_MODE" = "lb_health" ] || \
       { [ -z "${EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID:-}" ] || [ "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" = "null" ]; }; then
        use_lb_mode="true"
    fi

    if [ "$use_lb_mode" = "true" ]; then
        simulate_region_down_lb_mode
    else
        simulate_region_down_hc_mode
    fi
}

simulate_region_down_lb_mode() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: REGION-DOWN (Absent Metrics via Alarm Query Modification)${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will:"
    echo "  1. Save the current alarm query"
    echo "  2. Modify alarm query to reference a non-existent LB (metrics become absent)"
    echo "  3. Alarm fires via absent() detection after the configured absence window"
    echo "  4. ONS triggers the standby OCI Function"
    echo "  5. OCI Function scales SECONDARY humio-operator 0→1"
    echo ""
    echo -e "${YELLOW}NOTE: This does NOT modify the primary cluster at all.${NC}"
    echo -e "${YELLOW}      It validates the alarm's absent-metrics path for regional outage simulation.${NC}"
    echo ""

    if [ -z "$DR_FAILOVER_ALARM_OCID" ] || [ "$DR_FAILOVER_ALARM_OCID" = "null" ]; then
        echo -e "${RED}ERROR: DR_FAILOVER_ALARM_OCID not found in Terraform state${NC}"
        return 1
    fi

    # Get current alarm details
    local alarm_json
    alarm_json=$(oci monitoring alarm get --alarm-id "$DR_FAILOVER_ALARM_OCID" --profile "${SECONDARY_OCI_PROFILE:-DEFAULT}" $OCI_AUTH_FLAG 2>/dev/null || echo "")
    if [ -z "$alarm_json" ]; then
        echo -e "${RED}ERROR: Failed to retrieve alarm details${NC}"
        return 1
    fi

    local current_query
    current_query=$(jq_parse "$alarm_json" '.data.query')
    if [ -z "$current_query" ]; then
        echo -e "${RED}ERROR: Failed to read current alarm query${NC}"
        return 1
    fi

    # Save original query for restoration
    export DR_ORIGINAL_ALARM_QUERY="$current_query"
    echo "  Original alarm query saved for failback restoration."
    echo "  Current query: ${current_query:0:80}..."

    # Show current status
    show_status

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  INITIATING REGION-DOWN SIMULATION (absent metrics via query modification)${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local start=$(date +%s)

    print_step_header "Step 1: Modifying alarm query to reference non-existent LB..." "$start"
    # Replace the real LB OCID with a fake one to make metrics absent
    local fake_query
    fake_query=$(echo "$current_query" | sed "s|${PRIMARY_LB_OCID}|ocid1.loadbalancer.oc1.xx.absent-test-placeholder-00000000000000000000000000|g")
    print_step_line "  Modified query: ${fake_query:0:80}..."

    if ! oci monitoring alarm update --alarm-id "$DR_FAILOVER_ALARM_OCID" \
        --query-text "$fake_query" --force --profile "${SECONDARY_OCI_PROFILE:-DEFAULT}" $OCI_AUTH_FLAG 2>/dev/null; then
        echo -e "${RED}ERROR: Failed to update alarm query${NC}"
        return 1
    fi
    print_step_line "${GREEN}  Alarm query updated. Metrics will be absent.${NC}" "+$(($(date +%s) - start))s"
    echo "  Alarm should fire via absent() after the configured absence window + pending duration."

    echo ""
    echo "=== Tracking DR Failover Milestones ==="
    echo "Timeout: ${FAILOVER_TIMEOUT_SECONDS}s"
    echo ""

    local op="" pod="" snapshot="" healthy=""

    print_step_header "Step 2: Waiting for SECONDARY humio-operator to scale 0→1..." "$start"
    echo "  This may take several minutes (absent window + alarm pending duration)."
    op=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start") || op=""

    echo ""
    print_step_header "Step 3: Waiting for SECONDARY LogScale pod to become Ready..." "$start"
    pod=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start") || pod=""

    echo ""
    print_step_header "Step 4: Tracking global snapshot fetch from primary bucket..." "$start"
    snapshot=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start") || snapshot=""

    echo ""
    print_step_header "Step 5: Waiting for SECONDARY endpoint to become healthy..." "$start"
    local snapshot_confirmed="false"
    [ -n "$snapshot" ] && snapshot_confirmed="true"
    [ -n "$SECONDARY_FQDN" ] && healthy=$(wait_for_endpoint_healthy "$SECONDARY_FQDN" "$start" "$snapshot_confirmed") || healthy=""

    print_timing_summary "$start" "" "" "$op" "$pod" "$snapshot" "$healthy"

    echo ""
    echo -e "${YELLOW}IMPORTANT: Alarm query is still modified (referencing non-existent LB).${NC}"
    echo -e "${YELLOW}           Run 'failback' to restore the original alarm query.${NC}"
    show_status
}

simulate_region_down_hc_mode() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: REGION-DOWN (Disable PRIMARY Health Check)${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will:"
    echo "  1. Disable PRIMARY OCI Health Check (no probes/metrics emitted)"
    echo "  2. Alarm should fire via absent() after the configured absence window + pending duration"
    echo "  3. ONS triggers the standby OCI Function"
    echo "  4. OCI Function scales SECONDARY humio-operator 0→1"
    echo ""
    echo -e "${YELLOW}NOTE: This does NOT take the primary endpoint down by itself.${NC}"
    echo -e "${YELLOW}      It validates the alarm's absent-metrics path and ONS→Function invocation.${NC}"
    echo ""

    if [ -z "${EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID:-}" ] || [ "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" = "null" ]; then
        echo -e "${RED}ERROR: DR alarm primary health check OCID not found in Terraform state${NC}"
        echo ""
        echo "The health check resource may not be deployed yet."
        echo "Please ensure the DR infrastructure is fully deployed:"
        echo "  terraform workspace select secondary"
        echo "  terraform apply -var-file=secondary-us-chicago-1.tfvars"
        return 1
    fi

    # Verify health check exists
    local hc_status
    hc_status=$(get_health_check_status "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" || true)
    if [ "$hc_status" = "NotFound" ]; then
        echo -e "${RED}ERROR: Health check not found (OCID: $EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID)${NC}"
        return 1
    fi

    # Save current path for restoration, for consistency with failback behavior
    local current_path
    current_path=$(get_health_check_path "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" || echo "")
    [ -n "$current_path" ] && PRIMARY_HEALTH_CHECK_ORIGINAL_PATH="$current_path"

    # Show current status
    show_status

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  INITIATING REGION-DOWN SIMULATION (disable Health Check)${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    local start
    start=$(date +%s)

    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 1: Disabling PRIMARY health check..."
    echo "────────────────────────────────────────────────────────────────────"
    if ! set_health_check_enabled "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" "false"; then
        echo -e "${RED}ERROR: Failed to disable health check${NC}"
        return 1
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 2: Waiting for SECONDARY humio-operator to scale 0→1..."
    echo "────────────────────────────────────────────────────────────────────"
    echo "  This may take several minutes (absent window + alarm pending duration)."
    local op="" pod="" snapshot="" healthy=""
    op=$(track_operator_scaling "$SECONDARY_KUBE_CONTEXT" "$start") || op=""

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 3: Waiting for SECONDARY LogScale pod to become Ready..."
    echo "────────────────────────────────────────────────────────────────────"
    pod=$(track_logscale_pod_ready "$SECONDARY_KUBE_CONTEXT" "$start") || pod=""

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 4: Tracking global snapshot fetch from primary bucket..."
    echo "────────────────────────────────────────────────────────────────────"
    snapshot=$(track_snapshot_fetch "$SECONDARY_KUBE_CONTEXT" "$start") || snapshot=""

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 5: Waiting for SECONDARY endpoint to become healthy..."
    echo "────────────────────────────────────────────────────────────────────"
    # If snapshot was confirmed in Step 4, extend the timeout for LogScale initialization
    local snapshot_confirmed="false"
    [ -n "$snapshot" ] && snapshot_confirmed="true"
    [ -n "$SECONDARY_FQDN" ] && healthy=$(wait_for_endpoint_healthy "$SECONDARY_FQDN" "$start" "$snapshot_confirmed") || healthy=""

    print_timing_summary "$start" "" "" "$op" "$pod" "$snapshot" "$healthy"

    echo ""
    echo -e "${YELLOW}IMPORTANT: PRIMARY health check is still DISABLED.${NC}"
    echo -e "${YELLOW}           Run 'failback' to re-enable and restore the correct path.${NC}"
    show_status
}

simulate_transient_outage() {
    # Detect monitoring mode: use LB mode if explicitly set or health check OCID is unavailable
    local use_lb_mode="false"
    if [ "$DR_MONITORING_MODE" = "lb_health" ] || \
       { [ -z "${EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID:-$PRIMARY_HEALTH_CHECK_OCID}" ] || \
         [ "${EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID:-$PRIMARY_HEALTH_CHECK_OCID}" = "null" ]; }; then
        use_lb_mode="true"
    fi

    if [ "$use_lb_mode" = "true" ]; then
        simulate_transient_outage_lb_mode
    else
        simulate_transient_outage_hc_mode
    fi
}

simulate_transient_outage_lb_mode() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: TRANSIENT-OUTAGE (Anti-Flap Test via LB Health Checker)${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will:"
    echo "  1. Verify SECONDARY humio-operator is still at 0 replicas"
    echo "  2. Modify LB health checker to invalid port (backends become unhealthy)"
    echo "  3. Wait a short duration (less than alarm pending_duration)"
    echo "  4. Restore LB health checker (backends recover)"
    echo "  5. Confirm SECONDARY humio-operator did NOT scale to 1"
    echo ""
    echo -e "${CYAN}NOTE: This scenario validates that brief outages don't trigger failover.${NC}"
    echo -e "${CYAN}      The outage duration must be shorter than alarm pending_duration.${NC}"
    echo ""

    local outage_duration="$TRANSIENT_OUTAGE_DURATION_SECONDS"
    local observation_duration="$TRANSIENT_OBSERVATION_SECONDS"

    if [ -z "$PRIMARY_LB_OCID" ] || [ "$PRIMARY_LB_OCID" = "null" ]; then
        echo -e "${RED}ERROR: PRIMARY_LB_OCID not found in Terraform state${NC}"
        return 1
    fi

    local secondary_replicas
    secondary_replicas=$(get_operator_replicas "$SECONDARY_KUBE_CONTEXT" 2>/dev/null || echo "0")
    if [ "${secondary_replicas:-0}" -ne 0 ]; then
        echo -e "${YELLOW}WARN: SECONDARY humio-operator is currently at ${secondary_replicas} replicas.${NC}"
        echo "      Run 'failback' to reset secondary to 0 before running transient-outage."
        return 1
    fi

    echo "Configuration:"
    echo "  Outage duration:     ${outage_duration}s"
    echo "  Observation window:  ${observation_duration}s"
    echo ""

    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 1: Modifying LB health checker to invalid port (brief outage)..."
    echo "────────────────────────────────────────────────────────────────────"
    if ! modify_lb_health_checker_invalid "$PRIMARY_LB_OCID" "$LB_BACKEND_SET_NAME" "${PRIMARY_OCI_PROFILE:-DEFAULT}"; then
        echo -e "${RED}ERROR: Failed to modify LB health checker${NC}"
        return 1
    fi

    echo ""
    echo "Step 2: Waiting ${outage_duration}s (simulating brief outage)..."
    sleep "$outage_duration"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 3: Restoring LB health checker (outage resolved)..."
    echo "────────────────────────────────────────────────────────────────────"
    restore_lb_health_checker "$PRIMARY_LB_OCID" "$LB_BACKEND_SET_NAME" "${PRIMARY_OCI_PROFILE:-DEFAULT}"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 4: Observing SECONDARY humio-operator replicas for ${observation_duration}s..."
    echo "────────────────────────────────────────────────────────────────────"
    local start_epoch
    start_epoch=$(date +%s)
    local deadline=$((start_epoch + observation_duration))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local replicas
        replicas=$(get_operator_replicas "$SECONDARY_KUBE_CONTEXT" 2>/dev/null || echo "0")
        if [ "${replicas:-0}" -ne 0 ]; then
            echo -e "${RED}FAIL: SECONDARY humio-operator scaled to ${replicas} during transient outage window.${NC}"
            echo "      This suggests anti-flap gating is not working as expected."
            return 1
        fi
        local now
        now=$(date +%s)
        printf "  OK: secondary still at 0 replicas (+%ss)\n" "$((now - start_epoch))"
        sleep 10
    done

    echo ""
    echo -e "${GREEN}PASS: Secondary did not scale during transient outage.${NC}"
    show_status
}

simulate_transient_outage_hc_mode() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: TRANSIENT-OUTAGE (Anti-Flap Test)${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will:"
    echo "  1. Verify SECONDARY humio-operator is still at 0 replicas"
    echo "  2. Disable PRIMARY health check for a short duration"
    echo "  3. Re-enable PRIMARY health check"
    echo "  4. Confirm SECONDARY humio-operator did NOT scale to 1"
    echo ""
    echo -e "${CYAN}NOTE: This scenario MUST NOT modify PRIMARY humio-operator replicas.${NC}"
    echo -e "${CYAN}      It only toggles the OCI Health Check.${NC}"
    echo ""

    local outage_duration="$TRANSIENT_OUTAGE_DURATION_SECONDS"
    local observation_duration="$TRANSIENT_OBSERVATION_SECONDS"

    local hc_id="${EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID:-$PRIMARY_HEALTH_CHECK_OCID}"
    if [ -z "$hc_id" ] || [ "$hc_id" = "null" ]; then
        echo -e "${RED}ERROR: Health check OCID not found in Terraform state${NC}"
        return 1
    fi

    local hc_status
    hc_status=$(get_health_check_status "$hc_id" || true)
    if [ "$hc_status" = "NotFound" ]; then
        echo -e "${RED}ERROR: Health check not found (OCID: $hc_id)${NC}"
        return 1
    fi

    local secondary_replicas
    secondary_replicas=$(get_operator_replicas "$SECONDARY_KUBE_CONTEXT" 2>/dev/null || echo "0")
    if [ "${secondary_replicas:-0}" -ne 0 ]; then
        echo -e "${YELLOW}WARN: SECONDARY humio-operator is currently at ${secondary_replicas} replicas.${NC}"
        echo "      Run 'failback' to reset secondary to 0 before running transient-outage."
        return 1
    fi

    echo "Configuration:"
    echo "  Outage duration:     ${outage_duration}s"
    echo "  Observation window:  ${observation_duration}s"
    echo ""

    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 1: Disabling PRIMARY health check..."
    echo "────────────────────────────────────────────────────────────────────"
    if ! set_health_check_enabled "$hc_id" "false"; then
        echo -e "${RED}ERROR: Failed to disable health check${NC}"
        return 1
    fi

    echo ""
    echo "Step 2: Waiting ${outage_duration}s..."
    sleep "$outage_duration"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 3: Re-enabling PRIMARY health check..."
    echo "────────────────────────────────────────────────────────────────────"
    if ! set_health_check_enabled "$hc_id" "true"; then
        echo -e "${RED}ERROR: Failed to re-enable health check${NC}"
        return 1
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 4: Observing SECONDARY humio-operator replicas for ${observation_duration}s..."
    echo "────────────────────────────────────────────────────────────────────"
    local start_epoch
    start_epoch=$(date +%s)
    local deadline=$((start_epoch + observation_duration))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local replicas
        replicas=$(get_operator_replicas "$SECONDARY_KUBE_CONTEXT" 2>/dev/null || echo "0")
        if [ "${replicas:-0}" -ne 0 ]; then
            echo -e "${RED}FAIL: SECONDARY humio-operator scaled to ${replicas} during transient outage window.${NC}"
            echo "      This suggests anti-flap gating is not working as expected."
            return 1
        fi
        local now
        now=$(date +%s)
        printf "  OK: secondary still at 0 replicas (+%ss)\n" "$((now - start_epoch))"
        sleep 10
    done

    echo ""
    echo -e "${GREEN}PASS: Secondary did not scale during transient outage.${NC}"
    show_status
}

simulate_failback() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SCENARIO: FAILBACK to PRIMARY${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════${NC}"

    show_infrastructure_details

    echo "This will restore the system to normal state:"
    echo "  - Clean up V2 test artifacts (NetworkPolicies, iptables rules)"
    echo "  - Disable DR alarm during restoration"
    echo "  - Restore PRIMARY cluster (health check, operator, endpoint)"
    echo "  - Reset SECONDARY cluster (operator, LogScale, Kafka, storage)"
    echo "  - Re-enable DR alarm"
    echo ""

    show_status

    local start=$(date +%s)
    # Use generic Strimzi labels that work regardless of pool name (ctrl-brokers, dual-role, etc.)
    local kafka_label="strimzi.io/kind=Kafka,strimzi.io/component-type=kafka"
    local logscale_label="app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator"

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  V2 TEST ARTIFACT CLEANUP${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 1: Removing NetworkPolicies (storage-failure cleanup)..."
    echo "────────────────────────────────────────────────────────────────────"
    # Remove NetworkPolicies from storage-failure scenario
    local np_count
    np_count=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" get networkpolicy -l "dr-test=true" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "${np_count:-0}" -gt 0 ]; then
        echo "  Found $np_count NetworkPolicy(ies) with dr-test=true label"
        remove_storage_block_policy "$PRIMARY_KUBE_CONTEXT"
        echo -e "  ${GREEN}NetworkPolicies removed. Object Storage access restored.${NC}"
    else
        echo "  No test NetworkPolicies found. Skipping."
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 2: Restoring iptables rules (logscale-crash block-health cleanup)..."
    echo "────────────────────────────────────────────────────────────────────"
    # Restore health endpoint if blocked (from logscale-crash block-health mode)
    restore_logscale_health_endpoint "$PRIMARY_KUBE_CONTEXT"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 3: Checking PRIMARY LogScale pod health (logscale-crash cleanup)..."
    echo "────────────────────────────────────────────────────────────────────"
    # Check if PRIMARY LogScale pod exists and is healthy
    local primary_pod=$(get_logscale_pod_name "$PRIMARY_KUBE_CONTEXT")
    if [ -n "$primary_pod" ]; then
        local pod_ready=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" get pod "$primary_pod" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        local pod_phase=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" get pod "$primary_pod" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo "  PRIMARY LogScale pod: $primary_pod"
        echo "  Pod phase: $pod_phase, Ready: $pod_ready"

        if [ "$pod_ready" != "True" ] || [ "$pod_phase" != "Running" ]; then
            echo -e "  ${YELLOW}Pod is not healthy. Forcing restart...${NC}"
            kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pod "$primary_pod" --force --grace-period=0 2>/dev/null || \
            kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pod "$primary_pod" 2>/dev/null || true
            echo "  Pod deletion initiated. Operator will recreate it."
        else
            echo -e "  ${GREEN}Pod is healthy. No restart needed.${NC}"
        fi
    else
        echo "  No PRIMARY LogScale pod found. Operator will create one after scaling."
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ALARM MANAGEMENT${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 4: Disabling DR failover alarm (prevent re-triggering)..."
    echo "────────────────────────────────────────────────────────────────────"
    if [ -n "${DR_FAILOVER_ALARM_OCID:-}" ] && [ "$DR_FAILOVER_ALARM_OCID" != "null" ]; then
        local alarm_status=$(get_alarm_status "$DR_FAILOVER_ALARM_OCID")
        if [ "$alarm_status" = "NotFound" ]; then
            echo "  Alarm resource not found. Skipping."
        elif [ "$alarm_status" = "true" ]; then
            echo "  Alarm is ENABLED. Disabling during restoration..."
            set_alarm_enabled "$DR_FAILOVER_ALARM_OCID" "false"
            echo -e "  ${GREEN}Alarm disabled. Will re-enable after restoration completes.${NC}"
        else
            echo "  Alarm already disabled."
        fi
    else
        echo "  Could not find DR failover alarm OCID. Skipping."
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  PRIMARY CLUSTER RESTORATION${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 5: Restoring PRIMARY health check (enabled + correct path)..."
    echo "────────────────────────────────────────────────────────────────────"
    if [ -n "${EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID:-}" ] && [ "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" != "null" ]; then
        local hc_status=$(get_health_check_status "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID")
        if [ "$hc_status" = "NotFound" ]; then
            echo "  Health check resource not deployed. Skipping."
            echo "  Run: terraform apply -var-file=secondary-us-chicago-1.tfvars"
        else
            # First, restore the path if it was changed (failover-path scenario)
            local current_path=$(get_health_check_path "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID")
            if [ -n "$current_path" ] && [ "$current_path" != "/api/v1/status" ]; then
                echo "  Health check path is '$current_path' (not default). Restoring to /api/v1/status..."
                set_health_check_path "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" "/api/v1/status"
            else
                echo "  Health check path is already correct (/api/v1/status)."
            fi

            # Then, ensure it's enabled
            if [ "$hc_status" = "false" ]; then
                echo "  Health check is DISABLED. Re-enabling..."
                set_health_check_enabled "$EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID" "true"
            elif [ "$hc_status" = "true" ]; then
                echo "  Health check already enabled."
            else
                echo "  Unknown health check status: $hc_status"
            fi
        fi
    else
        echo "  Could not find DR alarm primary health check OCID. Skipping."
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 6: Scaling PRIMARY humio-operator to 1 (if needed)..."
    echo "────────────────────────────────────────────────────────────────────"
    local primary_replicas=$(get_operator_replicas "$PRIMARY_KUBE_CONTEXT")
    if [ "${primary_replicas:-0}" -eq 0 ]; then
        echo "  Primary humio-operator is at 0 replicas. Scaling to 1..."
        scale_operator "$PRIMARY_KUBE_CONTEXT" 1 "PRIMARY"
        echo -e "  ${GREEN}Primary humio-operator scaled to 1.${NC}"
    else
        echo "  Primary humio-operator already at ${primary_replicas} replica(s). No action needed."
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 6b: Restoring PRIMARY LB health checker..."
    echo "────────────────────────────────────────────────────────────────────"
    if [ -n "$PRIMARY_LB_OCID" ] && [ "$PRIMARY_LB_OCID" != "null" ]; then
        # Always check the actual HC state — don't rely on in-memory flags
        # which are lost if the script was killed or failback runs in a new session
        local current_hc_port
        current_hc_port=$(oci lb health-checker get \
            --load-balancer-id "$PRIMARY_LB_OCID" \
            --backend-set-name "$LB_BACKEND_SET_NAME" \
            --profile "${PRIMARY_OCI_PROFILE:-DEFAULT}" $OCI_AUTH_FLAG 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['port'])" 2>/dev/null || echo "")
        # Discover the expected port from the Kubernetes service's healthCheckNodePort
        local expected_port
        expected_port=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "${NAMESPACE:-logging}" \
            get svc "${PRIMARY_CLUSTER_NAME:-dr-primary}-lb" \
            -o jsonpath='{.spec.healthCheckNodePort}' 2>/dev/null || echo "")
        expected_port="${expected_port:-${LB_HC_ORIGINAL_PORT:-30579}}"
        if [ -n "$current_hc_port" ] && [ "$current_hc_port" != "$expected_port" ]; then
            echo "  Health checker is on port ${current_hc_port} (expected ${expected_port}). Restoring..."
            restore_lb_health_checker "$PRIMARY_LB_OCID" "$LB_BACKEND_SET_NAME" "${PRIMARY_OCI_PROFILE:-DEFAULT}"
        else
            echo "  Health checker is on expected port ${current_hc_port:-unknown}. No restore needed."
        fi
    else
        echo "  No PRIMARY LB OCID available. Skipping health checker restore."
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 6c: Restoring PRIMARY nginx-ingress (if applicable)..."
    echo "────────────────────────────────────────────────────────────────────"
    local ingress_ns="${INGRESS_NAMESPACE:-logging-ingress}"

    # Check if nginx-ingress is scaled to 0
    echo "  Checking nginx-ingress deployment status..."
    local ingress_scaled_down
    ingress_scaled_down=$(check_nginx_ingress_scaled_down "$PRIMARY_KUBE_CONTEXT")
    if [ "${ingress_scaled_down:-0}" -eq 1 ]; then
        echo "  nginx-ingress is scaled to 0. Restoring..."
        restore_nginx_ingress "$PRIMARY_KUBE_CONTEXT"
    else
        echo "  nginx-ingress is already running."
    fi

    # Also verify nginx-ingress deployment status
    echo "  Verifying nginx-ingress deployment..."
    local ingress_deploy
    # Find the nginx-ingress-controller deployment
    ingress_deploy=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$ingress_ns" get deployments \
        -l "app.kubernetes.io/name=ingress-nginx" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$ingress_deploy" ]; then
        # Fallback: try stored name from primary-down
        ingress_deploy="${PRIMARY_NGINX_INGRESS_DEPLOY:-}"
        if [ -z "$ingress_deploy" ]; then
            # Last resort: list all deployments in the namespace
            ingress_deploy=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$ingress_ns" get deployments \
                --no-headers 2>/dev/null | awk '{print $1}' | head -1)
        fi
    fi
    if [ -n "$ingress_deploy" ]; then
        local current_replicas=$(kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$ingress_ns" get deployment "$ingress_deploy" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        if [ "${current_replicas:-0}" -eq 0 ]; then
            echo "  nginx-ingress deployment '$ingress_deploy' is at 0 replicas. Scaling to 2..."
            kubectl --context "$PRIMARY_KUBE_CONTEXT" -n "$ingress_ns" scale deployment "$ingress_deploy" --replicas=2
            echo -e "  ${GREEN}nginx-ingress scaled to 2 replicas.${NC}"
        else
            echo "  nginx-ingress already at ${current_replicas} replica(s). No scaling needed."
        fi
    else
        echo "  Could not find nginx-ingress deployment in $ingress_ns namespace."
        echo "  You may need to manually verify nginx-ingress status:"
        echo "    kubectl --context $PRIMARY_KUBE_CONTEXT -n $ingress_ns get deployments"
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 7: Waiting for PRIMARY LB backends to become healthy..."
    echo "────────────────────────────────────────────────────────────────────"
    echo "  Using OCI Monitoring metrics (oci_lbaas.UnHealthyBackendServers)"
    echo "  This is more reliable than HTTP endpoint checks with restricted public_lb_cidrs"
    echo ""
    if [ -n "$PRIMARY_LB_OCID" ] && [ "$PRIMARY_LB_OCID" != "null" ] && \
       [ -n "$PRIMARY_COMPARTMENT_OCID" ] && [ "$PRIMARY_COMPARTMENT_OCID" != "null" ]; then
        local primary_healthy_epoch
        primary_healthy_epoch=$(wait_for_lb_backends_healthy \
            "$PRIMARY_LB_OCID" \
            "$PRIMARY_COMPARTMENT_OCID" \
            "$start" \
            "${PRIMARY_OCI_PROFILE:-DEFAULT}" \
            "$LB_BACKEND_SET_NAME") || primary_healthy_epoch=""
        if [ -n "$primary_healthy_epoch" ]; then
            local delta=$((primary_healthy_epoch - start))
            echo -e "  ${GREEN}Primary LB backends healthy after ${delta}s.${NC}"
        else
            echo -e "  ${YELLOW}WARN: Primary LB backends did not become healthy within timeout.${NC}"
            echo "        Continuing with secondary cleanup..."
        fi
    else
        echo -e "  ${YELLOW}Skipped (PRIMARY_LB_OCID or PRIMARY_COMPARTMENT_OCID not configured).${NC}"
        echo "    PRIMARY_LB_OCID: ${PRIMARY_LB_OCID:-<not set>}"
        echo "    PRIMARY_COMPARTMENT_OCID: ${PRIMARY_COMPARTMENT_OCID:-<not set>}"
        echo "    Run 'terraform output primary_ingest_lb_ocid' in the primary workspace to verify."
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 7b: Resetting DNS steering policy (re-enabling primary answer)..."
    echo "────────────────────────────────────────────────────────────────────"
    echo "  The DR failover function disables the primary answer during failover."
    echo "  This step re-enables it so DNS resolves to the primary LB."
    reset_dns_steering_policy

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  SECONDARY CLUSTER RESET${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 8: Scaling SECONDARY humio-operator to 0..."
    echo "────────────────────────────────────────────────────────────────────"
    scale_operator "$SECONDARY_KUBE_CONTEXT" 0 "SECONDARY"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 9: Deleting SECONDARY LogScale pods..."
    echo "────────────────────────────────────────────────────────────────────"
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
        -l "$logscale_label" --ignore-not-found=true
    echo "  Delete command issued."

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 10: Waiting for SECONDARY LogScale pods to terminate..."
    echo "────────────────────────────────────────────────────────────────────"
    wait_for_pods_deleted "$SECONDARY_KUBE_CONTEXT" "$logscale_label" 120 || true

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 11: Scaling SECONDARY strimzi-cluster-operator to 0..."
    echo "────────────────────────────────────────────────────────────────────"
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" scale deployment strimzi-cluster-operator --replicas=0 2>/dev/null && echo "  Done." || echo "  WARN: Could not scale strimzi-cluster-operator"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 12: Deleting SECONDARY Strimzi Kafka pods..."
    echo "────────────────────────────────────────────────────────────────────"
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
        -l "$kafka_label" --ignore-not-found=true --force --grace-period=0 2>/dev/null || \
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pods \
        -l "$kafka_label" --ignore-not-found=true
    echo "  Delete command issued."

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 13: Waiting for SECONDARY Kafka pods to terminate..."
    echo "────────────────────────────────────────────────────────────────────"
    wait_for_pods_deleted "$SECONDARY_KUBE_CONTEXT" "$kafka_label" 120 || true

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 14: Deleting SECONDARY Strimzi Kafka PVCs..."
    echo "────────────────────────────────────────────────────────────────────"
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete pvc \
        -l "$kafka_label" --ignore-not-found=true

    echo "  Waiting for PVCs to be deleted..."
    local pvc_deadline=$(($(date +%s) + 60))
	    while [ "$(date +%s)" -lt "$pvc_deadline" ]; do
	        local pvc_count
	        pvc_count=$(kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" get pvc -l "$kafka_label" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
	        if [ "${pvc_count:-0}" -eq 0 ]; then
	            echo "  Kafka PVCs deleted."
	            break
	        fi
        echo "  Waiting for $pvc_count PVC(s) to terminate..."
        sleep 5
    done

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 15: Deleting SECONDARY StrimziPodSet (reset Kafka state)..."
    echo "────────────────────────────────────────────────────────────────────"
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" delete strimzipodset \
        --all --ignore-not-found=true 2>/dev/null || true
    echo "  StrimziPodSet deleted."

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 16: Scaling SECONDARY strimzi-cluster-operator back to 1..."
    echo "────────────────────────────────────────────────────────────────────"
    kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" scale deployment strimzi-cluster-operator --replicas=1 2>/dev/null && echo "  Done." || echo "  WARN: Could not scale strimzi-cluster-operator"

    echo ""
    echo "  Waiting for Strimzi to recreate Kafka pods (30s)..."
    sleep 30

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 17: Deleting SECONDARY Object Storage bucket contents..."
    echo "────────────────────────────────────────────────────────────────────"
    # Try to get bucket name from HumioCluster CR first, fall back to variable
    local secondary_bucket
    secondary_bucket=$(kubectl --context "$SECONDARY_KUBE_CONTEXT" -n "$NAMESPACE" get humiocluster -o jsonpath='{.items[0].spec.commonEnvironmentVariables[?(@.name=="S3_STORAGE_BUCKET")].value}' 2>/dev/null || echo "")
    [ -z "$secondary_bucket" ] && secondary_bucket="$SECONDARY_BUCKET_NAME"

    if [ -n "$secondary_bucket" ]; then
        echo "  Target bucket: ${secondary_bucket}"

        # Get and save retention rules before deletion
        echo "  Checking for retention rules on bucket..."
        local retention_rules_json
        retention_rules_json=$(oci os retention-rule list --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG \
            --bucket-name "$secondary_bucket" --all 2>/dev/null) || retention_rules_json='{"data":{"items":[]}}'

        # OCI CLI returns .data.items[] not .data[]
        local retention_rule_count
        retention_rule_count=$(jq_parse "$retention_rules_json" '.data.items | length')
        [ -z "$retention_rule_count" ] && retention_rule_count="0"

        # Store retention rule details for re-creation
        local saved_retention_rules=""

        if [ "${retention_rule_count:-0}" -gt 0 ]; then
            echo "  Found $retention_rule_count retention rule(s). Saving and removing temporarily..."

            # Save retention rule details for later re-creation
            echo "  Extracting retention rule details..."
            saved_retention_rules=$(jq_parse_compact "$retention_rules_json" '.data.items[] | {id: .id, "display-name": ."display-name", "time-amount": .duration."time-amount", "time-unit": .duration."time-unit"}')
            echo "  Retention rule details saved."

            # Delete each retention rule
            echo "  Temporarily removing retention rules..."
            local rule_ids
            rule_ids=$(jq_parse "$retention_rules_json" '.data.items[].id')

            if [ -n "$rule_ids" ]; then
                while IFS= read -r rule_id; do
                    [ -z "$rule_id" ] && continue
                    local rule_name
                    rule_name=$(jq_parse "$retention_rules_json" '.data.items[] | select(.id == $id) | ."display-name"' --arg id "$rule_id")
                    [ -z "$rule_name" ] && rule_name="unknown"
                    echo "    Deleting retention rule: $rule_name ($rule_id)..."
                    if oci os retention-rule delete --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG \
                        --bucket-name "$secondary_bucket" --retention-rule-id "$rule_id" --force 2>/dev/null; then
                        echo "    Retention rule deleted."
                    else
                        echo "    WARN: Could not delete retention rule. Object deletion may fail."
                    fi
                done <<< "$rule_ids"

                # Wait for retention rule deletion to propagate (OCI docs say ~30 seconds, 20s is usually sufficient)
                echo "  Waiting 20 seconds for retention rule deletion to propagate..."
                sleep 20
            else
                echo "  WARN: Could not extract rule IDs. Proceeding with object deletion..."
            fi
        else
            echo "  No retention rules found on bucket."
        fi

        # Delete bucket contents
        echo "  Deleting all objects in bucket..."
        echo "  (This may take a few minutes depending on bucket size)"
        if oci os object bulk-delete --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG \
            --bucket-name "$secondary_bucket" --force 2>&1; then
            echo "  Object Storage bucket contents deleted successfully."
        else
            echo "  Bucket empty or deletion completed with warnings."
        fi

        # Verify bucket is empty
        local remaining_objects remaining_json
        remaining_json=$(oci os object list --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG \
            --bucket-name "$secondary_bucket" --limit 1 2>/dev/null) || remaining_json='{"data":[]}'
        remaining_objects=$(jq_parse "$remaining_json" '.data | length')
        if [ "${remaining_objects:-0}" -eq 0 ]; then
            echo "  Verified: Object Storage bucket is now empty."
        else
            echo "  WARN: Some objects may still remain. Manual verification recommended."
        fi

        # Re-create retention rules
        if [ -n "$saved_retention_rules" ] && [ "${retention_rule_count:-0}" -gt 0 ]; then
            echo "  Re-creating retention rules..."

            while IFS= read -r rule_json; do
                [ -z "$rule_json" ] && continue
                local rule_name time_amount time_unit
                rule_name=$(jq_parse "$rule_json" '."display-name"')
                time_amount=$(jq_parse "$rule_json" '."time-amount"')
                time_unit=$(jq_parse "$rule_json" '."time-unit"')

                if [ -n "$rule_name" ] && [ "$rule_name" != "null" ] && [ -n "$time_amount" ] && [ "$time_amount" != "null" ]; then
                    echo "    Re-creating retention rule: $rule_name (${time_amount} ${time_unit})..."
                    if oci os retention-rule create --profile "$SECONDARY_OCI_PROFILE" $OCI_AUTH_FLAG \
                        --bucket-name "$secondary_bucket" \
                        --display-name "$rule_name" \
                        --time-amount "$time_amount" \
                        --time-unit "$time_unit" 2>/dev/null; then
                        echo "    Retention rule re-created successfully."
                    else
                        echo "    WARN: Could not re-create retention rule. Manual creation may be required."
                        echo "           Rule: $rule_name, Duration: ${time_amount} ${time_unit}"
                    fi
                fi
            done <<< "$saved_retention_rules"

            echo "  Retention rules restored."
        fi
    else
        echo "  WARN: Could not determine secondary bucket name. Manual cleanup may be required."
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ALARM RESTORATION${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════${NC}"

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 18: Restoring alarm query (if modified by region-down test)..."
    echo "────────────────────────────────────────────────────────────────────"
    if [ -n "${DR_ORIGINAL_ALARM_QUERY:-}" ] && [ -n "${DR_FAILOVER_ALARM_OCID:-}" ] && [ "$DR_FAILOVER_ALARM_OCID" != "null" ]; then
        echo "  Original alarm query saved from region-down test. Restoring..."
        if oci monitoring alarm update --alarm-id "$DR_FAILOVER_ALARM_OCID" \
            --query-text "$DR_ORIGINAL_ALARM_QUERY" --force --profile "${SECONDARY_OCI_PROFILE:-DEFAULT}" $OCI_AUTH_FLAG 2>/dev/null; then
            echo -e "  ${GREEN}Alarm query restored to original.${NC}"
            unset DR_ORIGINAL_ALARM_QUERY
        else
            echo -e "  ${RED}ERROR: Failed to restore alarm query. Manual fix required:${NC}"
            echo "    oci monitoring alarm update --alarm-id $DR_FAILOVER_ALARM_OCID --query-text '<original_query>'"
        fi
    else
        echo "  Alarm query not modified (no region-down test detected). Skipping."
    fi

    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Step 19: Re-enabling DR failover alarm..."
    echo "────────────────────────────────────────────────────────────────────"
    if [ -n "${DR_FAILOVER_ALARM_OCID:-}" ] && [ "$DR_FAILOVER_ALARM_OCID" != "null" ]; then
        local alarm_status=$(get_alarm_status "$DR_FAILOVER_ALARM_OCID")
        if [ "$alarm_status" = "NotFound" ]; then
            echo "  Alarm resource not found. Skipping."
        elif [ "$alarm_status" = "false" ]; then
            echo "  Alarm is DISABLED. Re-enabling..."
            set_alarm_enabled "$DR_FAILOVER_ALARM_OCID" "true"
            echo -e "  ${GREEN}Alarm re-enabled. DR failover automation is active.${NC}"
        else
            echo "  Alarm already enabled."
        fi
        # Also remove any active suppression
        remove_alarm_suppression "$DR_FAILOVER_ALARM_OCID"
    else
        echo "  Could not find DR failover alarm OCID. Skipping."
    fi

    echo ""
    local end_epoch=$(date +%s)
    local duration=$((end_epoch - start))

    echo "════════════════════════════════════════════════════════════════════"
    echo "               FAILBACK COMPLETE"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Failback completed in ${duration}s (~$((duration/60))m $((duration%60))s)."
    echo ""

    show_status
}

# ============================================================================
# Main Execution
# ============================================================================

# Resolve cluster pair before proceeding
if ! resolve_cluster_pair; then
    echo -e "${RED}Error: Could not resolve DR cluster pair${NC}" >&2
    exit 1
fi

echo -e "${CYAN}DR Cluster Configuration:${NC}"
echo "  Primary:   $PRIMARY_TFVARS (workspace: $PRIMARY_WORKSPACE)"
echo "  Secondary: $SECONDARY_TFVARS (workspace: $SECONDARY_WORKSPACE)"
echo ""

if [ "$SKIP_TUNNEL_SETUP" = "false" ]; then
    # When setting up tunnels, use default context names if not explicitly set
    [ -z "$PRIMARY_KUBE_CONTEXT" ] && PRIMARY_KUBE_CONTEXT="oci-primary"
    [ -z "$SECONDARY_KUBE_CONTEXT" ] && SECONDARY_KUBE_CONTEXT="oci-secondary"

    # Verify tfvars files exist (already validated in resolve_cluster_pair for explicit mode)
    [ ! -f "$PRIMARY_TFVARS" ] && { echo -e "${RED}Error: Primary tfvars file not found: $PRIMARY_TFVARS${NC}" >&2; exit 1; }
    [ ! -f "$SECONDARY_TFVARS" ] && { echo -e "${RED}Error: Secondary tfvars file not found: $SECONDARY_TFVARS${NC}" >&2; exit 1; }

    echo -e "${CYAN}Configuration:${NC}"
    echo "  Primary tfvars:   $PRIMARY_TFVARS"
    echo "  Secondary tfvars: $SECONDARY_TFVARS"
    echo "  Primary port:     $PRIMARY_LOCAL_PORT"
    echo "  Secondary port:   $SECONDARY_LOCAL_PORT"
    echo ""

    ensure_ssh_config
    trap cleanup_tunnels EXIT INT TERM

    if ! setup_cluster_tunnel "PRIMARY" "$PRIMARY_WORKSPACE" "$PRIMARY_TFVARS" "$PRIMARY_LOCAL_PORT" "$PRIMARY_KUBE_CONTEXT"; then
        echo -e "${RED}Failed to setup PRIMARY cluster tunnel. Aborting.${NC}" >&2
        exit 1
    fi
    echo ""
    if ! setup_cluster_tunnel "SECONDARY" "$SECONDARY_WORKSPACE" "$SECONDARY_TFVARS" "$SECONDARY_LOCAL_PORT" "$SECONDARY_KUBE_CONTEXT"; then
        echo -e "${RED}Failed to setup SECONDARY cluster tunnel. Aborting.${NC}" >&2
        exit 1
    fi

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Bastion Tunnels Established                                       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo "  oci-primary:   https://127.0.0.1:$PRIMARY_LOCAL_PORT"
    echo "  oci-secondary: https://127.0.0.1:$SECONDARY_LOCAL_PORT"
    echo ""
else
    echo -e "${YELLOW}Skipping tunnel setup - using existing kubectl contexts${NC}"
    echo ""

    # Even when skipping tunnel setup, we need to load essential config from Terraform
    echo -e "${CYAN}Loading configuration from Terraform state...${NC}"

    # Load primary config (use single terraform output -json call for efficiency)
    echo -n "  Loading primary workspace ($PRIMARY_WORKSPACE)... "
    terraform workspace select "$PRIMARY_WORKSPACE" >/dev/null 2>&1 || {
        echo -e "${RED}FAILED${NC}"
        echo -e "${RED}Error: Failed to select Terraform workspace '$PRIMARY_WORKSPACE'${NC}" >&2
        exit 1
    }
    PRIMARY_TF_OUTPUT=$(terraform output -json 2>/dev/null || echo "{}")
    echo -e "${GREEN}done${NC}"
    PRIMARY_HEALTH_CHECK_OCID=$(echo "$PRIMARY_TF_OUTPUT" | jq -r '.primary_health_check_id.value // empty' 2>/dev/null || echo "")
    PRIMARY_CLUSTER_ID=$(echo "$PRIMARY_TF_OUTPUT" | jq -r '.cluster_id.value // empty' 2>/dev/null || echo "")
    PRIMARY_CLUSTER_NAME=$(echo "$PRIMARY_TF_OUTPUT" | jq -r '.cluster_name.value // empty' 2>/dev/null || echo "")
    PRIMARY_REGION=$(echo "$PRIMARY_TF_OUTPUT" | jq -r '.region.value // empty' 2>/dev/null)
    [ -z "$PRIMARY_REGION" ] && PRIMARY_REGION=$(read_tfvar region "$PRIMARY_TFVARS")
    PRIMARY_OCI_PROFILE=$(echo "$PRIMARY_TF_OUTPUT" | jq -r '.oci_profile_used.value // empty' 2>/dev/null)
    [ -z "$PRIMARY_OCI_PROFILE" ] && PRIMARY_OCI_PROFILE=$(read_tfvar config_file_profile "$PRIMARY_TFVARS")
    [ -z "$PRIMARY_OCI_PROFILE" ] && PRIMARY_OCI_PROFILE="DEFAULT"
    PRIMARY_FQDN=$(read_tfvar "logscale_public_fqdn" "$PRIMARY_TFVARS" || echo "")
    PRIMARY_LB_OCID=$(echo "$PRIMARY_TF_OUTPUT" | jq -r '.primary_ingest_lb_ocid.value // empty' 2>/dev/null || echo "")
    PRIMARY_LB_IP=$(echo "$PRIMARY_TF_OUTPUT" | jq -r '.primary_ingest_lb_ip.value // empty' 2>/dev/null || echo "")
    PRIMARY_COMPARTMENT_OCID=$(echo "$PRIMARY_TF_OUTPUT" | jq -r '.compartment_ocid.value // empty' 2>/dev/null || echo "")
    STEERING_POLICY_ID=$(echo "$PRIMARY_TF_OUTPUT" | jq -r '.steering_policy_id.value // empty' 2>/dev/null || echo "")

    # Load secondary config (use single terraform output -json call for efficiency)
    echo -n "  Loading secondary workspace ($SECONDARY_WORKSPACE)... "
    terraform workspace select "$SECONDARY_WORKSPACE" >/dev/null 2>&1 || {
        echo -e "${RED}FAILED${NC}"
        echo -e "${RED}Error: Failed to select Terraform workspace '$SECONDARY_WORKSPACE'${NC}" >&2
        exit 1
    }
    SECONDARY_TF_OUTPUT=$(terraform output -json 2>/dev/null || echo "{}")
    echo -e "${GREEN}done${NC}"
    DR_FAILOVER_PRIMARY_HEALTH_CHECK_OCID=$(echo "$SECONDARY_TF_OUTPUT" | jq -r '.dr_failover_primary_health_check_id.value // empty' 2>/dev/null || echo "")
    DR_FAILOVER_ALARM_OCID=$(echo "$SECONDARY_TF_OUTPUT" | jq -r '.dr_failover_alarm_id.value // empty' 2>/dev/null || echo "")
    DR_MONITORING_MODE=$(echo "$SECONDARY_TF_OUTPUT" | jq -r '.dr_monitoring_mode.value // empty' 2>/dev/null || echo "")
    SECONDARY_CLUSTER_ID=$(echo "$SECONDARY_TF_OUTPUT" | jq -r '.cluster_id.value // empty' 2>/dev/null || echo "")
    SECONDARY_CLUSTER_NAME=$(echo "$SECONDARY_TF_OUTPUT" | jq -r '.cluster_name.value // empty' 2>/dev/null || echo "")
    SECONDARY_REGION=$(echo "$SECONDARY_TF_OUTPUT" | jq -r '.region.value // empty' 2>/dev/null)
    [ -z "$SECONDARY_REGION" ] && SECONDARY_REGION=$(read_tfvar region "$SECONDARY_TFVARS")
    SECONDARY_OCI_PROFILE=$(echo "$SECONDARY_TF_OUTPUT" | jq -r '.oci_profile_used.value // empty' 2>/dev/null)
    [ -z "$SECONDARY_OCI_PROFILE" ] && SECONDARY_OCI_PROFILE=$(read_tfvar config_file_profile "$SECONDARY_TFVARS")
    [ -z "$SECONDARY_OCI_PROFILE" ] && SECONDARY_OCI_PROFILE="DEFAULT"
    SECONDARY_FQDN=$(read_tfvar "logscale_public_fqdn" "$SECONDARY_TFVARS" || echo "")
    SECONDARY_BUCKET_NAME=$(echo "$SECONDARY_TF_OUTPUT" | jq -r '.storage_bucket_name.value // empty' 2>/dev/null || echo "")

    log_debug "Terraform state loaded: PRIMARY_CLUSTER_NAME=$PRIMARY_CLUSTER_NAME, SECONDARY_CLUSTER_NAME=$SECONDARY_CLUSTER_NAME"

    # Auto-detect kubectl contexts from kubeconfig if not explicitly set
    echo ""
    echo -e "${CYAN}Auto-detecting kubectl contexts from kubeconfig...${NC}"

    # Cache the context list once to avoid repeated kubectl calls
    log_debug "Fetching kubectl contexts from kubeconfig..."
    AVAILABLE_CONTEXTS=$(kubectl config get-contexts -o name 2>/dev/null || echo "")
    log_debug "Found $(echo "$AVAILABLE_CONTEXTS" | wc -l | tr -d ' ') contexts"
    log_debug "PRIMARY_CLUSTER_NAME=$PRIMARY_CLUSTER_NAME, PRIMARY_WORKSPACE=$PRIMARY_WORKSPACE"

    if [ -z "$PRIMARY_KUBE_CONTEXT" ]; then
        # Try multiple discovery methods in order of preference:
        # 1. OKE cluster name from Terraform (e.g., "single", "dr-secondary")
        # 2. oci-<cluster_name> convention (e.g., oci-single)
        # 3. oci-<workspace_name> convention (e.g., oci-single)
        # 4. Exact workspace name as context
        # 5. OCID-based discovery from cluster ID
        discovered_context=""

        # Method 1: Try OKE cluster name from Terraform state
        if [ -n "$PRIMARY_CLUSTER_NAME" ] && echo "$AVAILABLE_CONTEXTS" | grep -qx "${PRIMARY_CLUSTER_NAME}"; then
            discovered_context="${PRIMARY_CLUSTER_NAME}"
            log_debug "Found PRIMARY context via cluster name: $discovered_context"
        # Method 2: Try oci-<cluster_name> convention
        elif [ -n "$PRIMARY_CLUSTER_NAME" ] && echo "$AVAILABLE_CONTEXTS" | grep -qx "oci-${PRIMARY_CLUSTER_NAME}"; then
            discovered_context="oci-${PRIMARY_CLUSTER_NAME}"
            log_debug "Found PRIMARY context via oci-<cluster_name> convention: $discovered_context"
        # Method 3: Try oci-<workspace> naming convention
        elif echo "$AVAILABLE_CONTEXTS" | grep -qx "oci-${PRIMARY_WORKSPACE}"; then
            discovered_context="oci-${PRIMARY_WORKSPACE}"
            log_debug "Found PRIMARY context via oci-<workspace> convention: $discovered_context"
        # Method 4: Try exact workspace name
        elif echo "$AVAILABLE_CONTEXTS" | grep -qx "${PRIMARY_WORKSPACE}"; then
            discovered_context="${PRIMARY_WORKSPACE}"
            log_debug "Found PRIMARY context via exact workspace name: $discovered_context"
        # Method 5: OCID-based discovery
        elif [ -n "$PRIMARY_CLUSTER_ID" ] && [ "$PRIMARY_CLUSTER_ID" != "null" ]; then
            discovered_context=$(discover_kube_context_for_cluster "$PRIMARY_CLUSTER_ID" || echo "")
        fi

        if [ -n "$discovered_context" ]; then
            PRIMARY_KUBE_CONTEXT="$discovered_context"
            echo -e "  ${GREEN}PRIMARY context:   $PRIMARY_KUBE_CONTEXT${NC}"
        else
            echo -e "  ${RED}ERROR: Could not find kubectl context for PRIMARY cluster${NC}"
            echo "         Cluster name: ${PRIMARY_CLUSTER_NAME:-<not set>}"
            echo "         Workspace: $PRIMARY_WORKSPACE"
            [ -n "$PRIMARY_CLUSTER_ID" ] && echo "         Cluster OCID: $PRIMARY_CLUSTER_ID"
            echo ""
            echo "  Available contexts:"
            echo "$AVAILABLE_CONTEXTS" | sed 's/^/    /'
            echo ""
            echo "  To fix this, either:"
            echo "    1. Set PRIMARY_KUBE_CONTEXT environment variable"
            [ -n "$PRIMARY_CLUSTER_NAME" ] && echo "    2. Create a kubeconfig entry with name '${PRIMARY_CLUSTER_NAME}'"
            [ -n "$PRIMARY_CLUSTER_ID" ] && echo "    3. Run: oci ce cluster create-kubeconfig --cluster-id $PRIMARY_CLUSTER_ID"
            exit 1
        fi
    else
        echo -e "  PRIMARY context:   $PRIMARY_KUBE_CONTEXT (from env var)"
    fi

    if [ -z "$SECONDARY_KUBE_CONTEXT" ]; then
        # Try multiple discovery methods (same as primary)
        discovered_context=""

        # Method 1: Try OKE cluster name from Terraform state
        if [ -n "$SECONDARY_CLUSTER_NAME" ] && echo "$AVAILABLE_CONTEXTS" | grep -qx "${SECONDARY_CLUSTER_NAME}"; then
            discovered_context="${SECONDARY_CLUSTER_NAME}"
            log_debug "Found SECONDARY context via cluster name: $discovered_context"
        # Method 2: Try oci-<cluster_name> convention
        elif [ -n "$SECONDARY_CLUSTER_NAME" ] && echo "$AVAILABLE_CONTEXTS" | grep -qx "oci-${SECONDARY_CLUSTER_NAME}"; then
            discovered_context="oci-${SECONDARY_CLUSTER_NAME}"
            log_debug "Found SECONDARY context via oci-<cluster_name> convention: $discovered_context"
        # Method 3: Try oci-<workspace> naming convention
        elif echo "$AVAILABLE_CONTEXTS" | grep -qx "oci-${SECONDARY_WORKSPACE}"; then
            discovered_context="oci-${SECONDARY_WORKSPACE}"
            log_debug "Found SECONDARY context via oci-<workspace> convention: $discovered_context"
        # Method 4: Try exact workspace name
        elif echo "$AVAILABLE_CONTEXTS" | grep -qx "${SECONDARY_WORKSPACE}"; then
            discovered_context="${SECONDARY_WORKSPACE}"
            log_debug "Found SECONDARY context via exact workspace name: $discovered_context"
        # Method 5: OCID-based discovery
        elif [ -n "$SECONDARY_CLUSTER_ID" ] && [ "$SECONDARY_CLUSTER_ID" != "null" ]; then
            discovered_context=$(discover_kube_context_for_cluster "$SECONDARY_CLUSTER_ID" || echo "")
        fi

        if [ -n "$discovered_context" ]; then
            SECONDARY_KUBE_CONTEXT="$discovered_context"
            echo -e "  ${GREEN}SECONDARY context: $SECONDARY_KUBE_CONTEXT${NC}"
        else
            echo -e "  ${RED}ERROR: Could not find kubectl context for SECONDARY cluster${NC}"
            echo "         Cluster name: ${SECONDARY_CLUSTER_NAME:-<not set>}"
            echo "         Workspace: $SECONDARY_WORKSPACE"
            [ -n "$SECONDARY_CLUSTER_ID" ] && echo "         Cluster OCID: $SECONDARY_CLUSTER_ID"
            echo ""
            echo "  Available contexts:"
            echo "$AVAILABLE_CONTEXTS" | sed 's/^/    /'
            echo ""
            echo "  To fix this, either:"
            echo "    1. Set SECONDARY_KUBE_CONTEXT environment variable"
            [ -n "$SECONDARY_CLUSTER_NAME" ] && echo "    2. Create a kubeconfig entry with name '${SECONDARY_CLUSTER_NAME}'"
            [ -n "$SECONDARY_CLUSTER_ID" ] && echo "    3. Run: oci ce cluster create-kubeconfig --cluster-id $SECONDARY_CLUSTER_ID"
            exit 1
        fi
    else
        echo -e "  SECONDARY context: $SECONDARY_KUBE_CONTEXT (from env var)"
    fi

    # Verify the contexts are accessible
    echo ""
    echo -e "${CYAN}Verifying kubectl context connectivity...${NC}"
    if ! kubectl --context "$PRIMARY_KUBE_CONTEXT" cluster-info >/dev/null 2>&1; then
        echo -e "  ${YELLOW}WARN: PRIMARY context ($PRIMARY_KUBE_CONTEXT) may not be accessible${NC}"
        echo "        This could indicate the cluster is unreachable or credentials expired."
    else
        echo -e "  ${GREEN}PRIMARY context:   OK${NC}"
    fi
    if ! kubectl --context "$SECONDARY_KUBE_CONTEXT" cluster-info >/dev/null 2>&1; then
        echo -e "  ${YELLOW}WARN: SECONDARY context ($SECONDARY_KUBE_CONTEXT) may not be accessible${NC}"
        echo "        This could indicate the cluster is unreachable or credentials expired."
    else
        echo -e "  ${GREEN}SECONDARY context: OK${NC}"
    fi

    echo ""
fi

# Prefer the standby-exported monitor used by the DR alarm/function; fall back to the
# global DNS primary monitor from the primary workspace (older setups).
if [ -n "${DR_FAILOVER_PRIMARY_HEALTH_CHECK_OCID:-}" ] && [ "$DR_FAILOVER_PRIMARY_HEALTH_CHECK_OCID" != "null" ]; then
    EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID="$DR_FAILOVER_PRIMARY_HEALTH_CHECK_OCID"
else
    EFFECTIVE_DR_PRIMARY_HEALTH_CHECK_OCID="$PRIMARY_HEALTH_CHECK_OCID"
fi

# Run the requested scenario
echo ""
case "$SCENARIO" in
    primary-down) simulate_primary_down ;;
    failover) simulate_failover ;;
    region-down) simulate_region_down ;;
    transient-outage) simulate_transient_outage ;;
    dns-failover-check) show_dns_status ;;
    failback) simulate_failback ;;
    status) show_status ;;
    logscale-crash) simulate_logscale_crash ;;
    storage-failure) simulate_storage_failure ;;
esac

echo ""
echo "Done."
