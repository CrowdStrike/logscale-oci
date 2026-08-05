# Bastion Tunnel Scripts

This directory contains helper scripts for establishing secure SSH and `kubectl` access to a private OKE cluster via the OCI Bastion Service.

| Script | Description | Recommended |
|--------|-------------|-------------|
| `setup-bastion-tunnel.sh` | Original interactive bastion/tunnel manager | No |
| `setup-bastion-tunnel-v2.sh` | Enhanced mode-based script with auto-refresh and logging | No |
| `setup-bastion-tunnel-v3.sh` | **Latest**: Workspace validation, network mismatch detection, session reuse | **Yes** |

All scripts assume:

- You are running it from a machine with:
  - `terraform` (initialized in this repository’s root).
  - OCI CLI (`oci`) configured with a profile that matches your Terraform configuration.
  - `jq`, `ssh`, `kubectl`, `nc` (or `telnet`), and `timeout`.
- The Terraform stack has already been applied with `provision_bastion = true`.

## `setup-bastion-tunnel.sh` (interactive)

### Usage

From the repository root:

```bash
cd /path/to/repo
./scripts/setup-bastion-tunnel.sh
```

You will see an interactive menu:

1. SSH access to OKE worker nodes.
2. `kubectl` connectivity to the Kubernetes cluster API.
3. Both SSH and `kubectl` access.
4. Exit.

The script:

- Reads Terraform outputs (bastion ID, cluster ID, region, SSH keys, subnet IDs, etc.).
- Creates short‑lived bastion `PORT_FORWARDING` sessions using the OCI CLI.
- Starts SSH tunnels for either worker SSH or direct Kubernetes API access.
- Validates connectivity where possible (e.g. test SSH via `127.0.0.1:$SSH_PORT`).
- Cleans up bastion sessions and tunnels automatically when you exit (Ctrl+C).

### Environment Variables

You can adjust behavior via environment variables, for example:

- `LOCAL_PORT` – local port for the Kubernetes API tunnel (default `6443`).
- `SSH_PORT` – local port for worker SSH tunnel (default `2222`).
- `SESSION_DURATION` – bastion session TTL in seconds (default `3600`).
- `DEBUG` – set to `0` to reduce debug output (default `1`).

Example:

```bash
SESSION_DURATION=7200 LOCAL_PORT=8443 SSH_PORT=2223 \
  ./scripts/setup-bastion-tunnel.sh
```

### Cleanup

The script traps `EXIT`, `INT`, and `TERM` signals and will:

- Terminate any SSH tunnel processes it started.
- Delete any bastion sessions it created.

You can safely stop it with `Ctrl+C`; bastion resources are cleaned up automatically.

---

## `setup-bastion-tunnel-v2.sh` (enhanced)

`setup-bastion-tunnel-v2.sh` builds on the original script and adds:

- Non‑interactive **modes**: `ssh`, `kubectl`, `both` (default `both`).
- **Workspace** selection via `--workspace <name>` (uses `terraform workspace select`).
- **tfvars fallbacks** via `--tfvars <file>` (or `--tfvars=file`) when Terraform outputs are missing:
  - Reads `compartment_ocid`/`compartment_id`, `region`, `config_file_profile` (OCI profile), and `ssh_public_key_path` from the tfvars file.
  - Falls back to `terraform.tfvars` automatically if `--tfvars` is not provided and the file exists.
  - Defaults `OCI_PROFILE` to `DEFAULT` if no profile is found.
- **Session/tunnel watchdogs** that:
  - Restart tunnels if the SSH process dies.
  - Refresh bastion sessions before TTL expiry.
- **Structured logging** to `LOG_DIR` (default current directory `.`).

### Usage

From the repository root:

```bash
# SSH access only (current workspace)
./scripts/setup-bastion-tunnel-v2.sh ssh

# Direct kubectl access only (current workspace)
./scripts/setup-bastion-tunnel-v2.sh kubectl

# SSH + kubectl (current workspace)
./scripts/setup-bastion-tunnel-v2.sh both
```

With explicit workspace and tfvars:

```bash
./scripts/setup-bastion-tunnel-v2.sh --workspace prod --tfvars my-cluster.tfvars both
```

### Additional Environment Variables

In addition to the variables supported by the original script, v2 also honors:

- `REFRESH_MARGIN` – seconds before session TTL when auto‑refresh should occur (default `300`).
- `WATCH_INTERVAL` – seconds between session/tunnel health checks (default `30`).
- `INITIAL_RETRY_ATTEMPTS` – how many times to retry initial session/tunnel setup before failing (default `3`).
- `INITIAL_RETRY_DELAY` – delay in seconds between initial retries (default `10`).
- `LOG_DIR` – directory for log files (default current directory `.`).

Example:

```bash
SESSION_DURATION=7200 REFRESH_MARGIN=600 WATCH_INTERVAL=60 \
  INITIAL_RETRY_ATTEMPTS=5 INITIAL_RETRY_DELAY=15 \
  ./scripts/setup-bastion-tunnel-v2.sh --workspace prod --tfvars my-cluster.tfvars both
```

### Cleanup

The v2 script also traps `EXIT`, `INT`, and `TERM` and will:

- Terminate any SSH tunnel processes it started (both worker and API tunnels).
- Delete any bastion sessions it created for SSH and kubectl access.

You can safely stop it with `Ctrl+C`; bastion sessions and tunnels are cleaned up automatically.

---

## `setup-bastion-tunnel-v3.sh` (recommended)

**Version 3.4.1 is the recommended script** for establishing bastion tunnels. It addresses critical bugs in v2 and adds several improvements:

### Key Improvements Over v2

| Feature | v2 | v3 |
|---------|----|----|
| Workspace validation | No validation | **Validates bastion can reach target network** |
| Network mismatch detection | Silent failure | **Clear error message with fix guidance** |
| Session reuse | Creates new session every time | **Reuses existing active sessions with SSH key validation** |
| Error messages | Generic errors | **Actionable error messages** |
| Default tfvars | Manual | **Auto-detects based on workspace name** |
| Concurrent execution | Not supported | **Supports multiple terminals with locking** |
| File logging | Always enabled | **Disabled by default, opt-in with `--log-file`** |
| SSH key validation | N/A | **Only reuses sessions matching your SSH key** |

### The Problem v3 Solves

In v2, if you ran the script with the wrong workspace, it would silently fail:

```bash
# WRONG: Using primary bastion to reach secondary cluster network
# v2 would fail with cryptic "session/tunnel setup failed" error
LOCAL_PORT=16444 ./scripts/setup-bastion-tunnel-v2.sh --workspace primary kubectl
# Actually connecting to secondary K8s API (10.1.1.3) via primary bastion (10.0.x.x network)
```

**Root cause**: Each bastion service can only reach resources in its own VCN:
- Primary bastion (10.0.x.x) can reach primary K8s API (10.0.1.9)
- Secondary bastion (10.1.x.x) can reach secondary K8s API (10.1.1.3)

**v3 detects this mismatch** and provides clear guidance:

```
ERROR: Network mismatch detected!

  Bastion 'dr-primary-bastion-service' is in network: 10.0.x.x
  Target K8s API is in network: 10.1.x.x

This usually means you're using the wrong workspace.

Current workspace: primary

To fix this, use the correct workspace:
  LOCAL_PORT=16444 ./scripts/setup-bastion-tunnel-v3.sh --workspace secondary kubectl
```

### Usage

```bash
# Connect to PRIMARY cluster (port 16443)
LOCAL_PORT=16443 ./scripts/setup-bastion-tunnel-v3.sh --workspace primary kubectl

# Connect to SECONDARY cluster (port 16444)
LOCAL_PORT=16444 ./scripts/setup-bastion-tunnel-v3.sh --workspace secondary kubectl

# With debug logging
LOCAL_PORT=16443 ./scripts/setup-bastion-tunnel-v3.sh --workspace primary --debug kubectl

# With debug logging saved to file
LOCAL_PORT=16443 ./scripts/setup-bastion-tunnel-v3.sh --workspace primary --debug --log-file kubectl

# Don't reuse existing sessions (force new session)
LOCAL_PORT=16443 ./scripts/setup-bastion-tunnel-v3.sh --workspace primary --no-reuse kubectl
```

### Options

| Option | Description |
|--------|-------------|
| `--workspace <name>` | Terraform workspace (primary\|secondary) |
| `--tfvars <file>` | Path to tfvars file |
| `--debug` | Enable debug logging |
| `--log-file` | Save logs to file (default: logs to screen only) |
| `--no-reuse` | Don't reuse existing bastion sessions |
| `--help` | Show help message |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOCAL_PORT` | `6443` | Local port for K8s API tunnel |
| `SSH_PORT` | `2222` | Local port for SSH tunnel |
| `SESSION_DURATION` | `3600` | Bastion session TTL in seconds |
| `REFRESH_MARGIN` | `300` | Seconds before TTL to refresh session |
| `WATCH_INTERVAL` | `30` | Seconds between health checks |
| `DEBUG` | `0` | Enable debug logging (0\|1) |
| `REUSE_SESSIONS` | `1` | Reuse existing active sessions (0\|1) |
| `LOG_TO_FILE` | `0` | Save logs to file (0\|1) |
| `LOG_DIR` | `./logs` | Directory for log files |
| `TF_LOCK_TIMEOUT` | `120` | Max seconds to wait for Terraform workspace lock |

### DR Setup: Dual Cluster Access

For DR testing, you need tunnels to both clusters simultaneously. **v3.1.0 supports concurrent execution** - you can run both commands in separate terminals:

**Terminal 1 - Primary cluster:**
```bash
LOCAL_PORT=16443 ./scripts/setup-bastion-tunnel-v3.sh --workspace primary kubectl
```

**Terminal 2 - Secondary cluster:**
```bash
LOCAL_PORT=16444 ./scripts/setup-bastion-tunnel-v3.sh --workspace secondary kubectl
```

The scripts use file-based locking to safely share the Terraform workspace. The second script will briefly wait for the first to extract its configuration, then proceed independently.

Then use `kubeconfig-dr.yaml` to access both:
```bash
export KUBECONFIG=$(pwd)/kubeconfig-dr.yaml

# Access primary (port 16443)
kubectl --context oci-primary get pods -n logging

# Access secondary (port 16444)
kubectl --context oci-secondary get pods -n logging
```

### Concurrent Execution (v3.1.0)

v3.1.0 adds Terraform workspace locking to allow safe concurrent execution:

- **Lock file**: `/tmp/bastion-tunnel-locks/terraform-workspace.lock`
- **Lock timeout**: 120 seconds (configurable via `TF_LOCK_TIMEOUT`)
- **Stale lock detection**: Automatically removes locks from dead processes
- **All Terraform operations**: Performed while holding the lock, then released

This allows running tunnels to both primary and secondary clusters simultaneously without workspace conflicts.

### SSH Key Validation (v3.2.1)

v3.2.1 adds SSH key fingerprint validation when reusing bastion sessions:

- **Problem solved**: Previously, the script would reuse any active session matching the target IP/port, even if it was created with a different SSH key. This caused "Permission denied (publickey)" errors when reconnecting after the tunnel dropped.
- **Solution**: The script now computes the SHA256 fingerprint of your SSH public key and only reuses sessions where the fingerprint matches.
- **Behavior**: If no session with a matching SSH key is found, a new session is created automatically.

This prevents authentication failures when multiple users share a bastion service or when SSH keys change.

### Session Cleanup Robustness (v3.4.1)

v3.4.1 fixes an issue where the session cleanup function would fail with "integer expression expected" errors:

- **Problem solved**: When the OCI CLI returned an empty or malformed response (e.g., network timeout, API error), the `jq` command would return an empty string instead of a number, causing bash integer comparisons to fail.
- **Solution**: The script now validates that the session count is a valid integer before comparisons, defaulting to 0 if the response is invalid.
- **Behavior**: The script gracefully handles OCI API failures during session cleanup without crashing.

### Cleanup

The v3 script traps `EXIT`, `INT`, `TERM`, and `HUP` signals and will:

- Terminate SSH tunnel processes it started
- Optionally delete bastion sessions (unless `REUSE_SESSIONS=1`)

Press `Ctrl+C` to stop; resources are cleaned up automatically.
