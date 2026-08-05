# LogScale OCI Infrastructure

Terraform module for deploying LogScale on OCI Container Engine for Kubernetes (OKE).

## Features

- Private OKE cluster with OCI Bastion Service (default) or public endpoint access
- Multi-AZ deployment with automatic availability domain discovery
- Object Storage with S3-compatible access for LogScale data
- OCI Classic Load Balancer with end-to-end TLS (Let's Encrypt + backend re-encryption)
- HTTP health checks with node-label-selector for accurate pod-level failure detection
- Disaster Recovery (DR) with automated failover via OCI Monitoring + Functions
- TopoLVM-based NVMe storage provisioning

## Requirements

| Name | Version |
|------|---------|
| Terraform | >= 1.0 |
| OCI Provider | >= 5.0 |
| OCI CLI | Latest |
| kubectl | >= 1.27 |

## Quick Start

```bash
# 1. Clone and configure
git clone <repository-url>
cd logscale-oci
cp example.tfvars my-cluster.tfvars
# Edit my-cluster.tfvars with your OCI credentials and cluster settings

# 2. Initialize
terraform workspace new <workspace-name>
terraform init -backend-config=backend-configs/primary-oci.hcl

# 3. Deploy (targeted apply sequence - order matters)
terraform apply -var-file="my-cluster.tfvars" -target=module.oci-core
terraform apply -var-file="my-cluster.tfvars" -target=module.oci-logscale-storage
terraform apply -var-file="my-cluster.tfvars" -target=module.oke
terraform apply -var-file="my-cluster.tfvars" -target=module.pre-install
terraform apply -var-file="my-cluster.tfvars" -target=module.logscale.module.crds
terraform apply -var-file="my-cluster.tfvars" -target=module.logscale
terraform apply -var-file="my-cluster.tfvars"

# 4. Access cluster (bastion mode)
LOCAL_PORT=16443 ./scripts/setup-bastion-tunnel.sh --workspace primary kubectl
```

> **Note**: The final untargeted `terraform apply` deploys remaining modules (cert-manager-oci-webhook, loadbalancer, global-dns, dr-failover-function) that depend on the LogScale stack being operational.

## Cluster Access Modes

| Mode | Configuration | Access Method |
|------|---------------|---------------|
| **Bastion (Default)** | `provision_bastion = true` | SSH tunnel via OCI Bastion Service |
| **Public Endpoint** | `provision_bastion = false`<br>`endpoint_public_access = true` | Direct with IP allowlist |

## Usage

### Single Cluster

```hcl
# terraform.tfvars
workspace_name    = "production"
cluster_name      = "logscale-prod"
region            = "us-chicago-1"
dr                = ""  # Standalone, no DR

# OCI Authentication
tenancy_ocid      = "ocid1.tenancy.oc1..xxx"
root_tenancy_ocid = "ocid1.tenancy.oc1..xxx"
compartment_ocid  = "ocid1.compartment.oc1..xxx"
user_ocid         = "ocid1.user.oc1..xxx"
user_fingerprint  = "xx:xx:xx:xx:xx:xx:xx:xx"
private_key_path  = "~/.oci/oci_api_key.pem"

# Cluster sizing
logscale_cluster_type = "advanced"
logscale_cluster_size = "small"

# Access control
provision_bastion         = true
bastion_client_allow_list = ["YOUR_IP/32"]
public_lb_cidrs           = ["YOUR_OFFICE_CIDR/24"]

# LogScale
logscale_license     = "REDACTED"
logscale_public_fqdn = "logscale.example.com"
cert_issuer_email    = "admin@example.com"

# DNS-01 certificate validation (required when public_lb_cidrs blocks Let's Encrypt)
cert_dns01_webhook_enabled = true
cert_dns01_provider        = "oci"
use_native_webhook         = true
```

### DR Configuration

Deploy primary and secondary clusters using Terraform workspaces:

```bash
# Primary cluster
terraform workspace new primary
terraform init -backend-config=backend-configs/primary-oci.hcl
terraform apply -var-file=primary.tfvars  # (use targeted sequence above)

# Secondary cluster
terraform workspace new secondary
terraform init -backend-config=backend-configs/secondary-oci.hcl
terraform apply -var-file=secondary.tfvars  # (use targeted sequence above)
```

#### Primary Cluster (dr = "active")

```hcl
# primary.tfvars
workspace_name = "primary"
cluster_name   = "dr-primary"
dr             = "active"

# Hostname Configuration
logscale_public_fqdn        = "logscale-dr.example.com"
dns_zone_name               = "example.com"

# Global DNS (managed by primary only)
manage_global_dns           = true
create_global_dns_zone      = true
global_logscale_hostname    = "logscale-dr"       # logscale-dr.example.com (global)
primary_logscale_hostname   = "logscale-primary"  # logscale-primary.example.com (direct)
secondary_logscale_hostname = "logscale-secondary"

# Remote state for secondary LB IP lookup
secondary_remote_state_config = {
  backend   = "oci"
  workspace = "secondary"
  config = {
    bucket    = "terraform-state"
    namespace = "your-namespace"
    region    = "us-chicago-1"
    key       = "env:/logscale-oci"
  }
}
```

#### Secondary Cluster (dr = "standby")

```hcl
# secondary.tfvars
workspace_name = "secondary"
cluster_name   = "dr-secondary"
dr             = "standby"

# DR recovery - reads from primary bucket
primary_remote_state_config = {
  backend   = "oci"
  workspace = "primary"
  config = {
    bucket    = "terraform-state"
    namespace = "your-namespace"
    region    = "us-chicago-1"
    key       = "env:/logscale-oci"
  }
}

# Failover function (auto-scales operator on primary failure)
dr_failover_function_enabled = true
```

#### DR Variable Reference

| Variable | Values | Description |
|----------|--------|-------------|
| `dr` | `"active"`, `"standby"`, `""` | DR mode. Empty = standalone cluster |
| `logscale_public_fqdn` | FQDN | Set to global hostname for DR failover |
| `global_logscale_hostname` | hostname | Global failover hostname prefix |
| `primary_logscale_hostname` | hostname | Primary cluster alias for direct access |
| `secondary_logscale_hostname` | hostname | Secondary cluster alias for direct access |
| `manage_global_dns` | `true`/`false` | Primary manages DNS steering policy |
| `primary_remote_state_config` | object | Standby reads primary state for encryption key |
| `secondary_remote_state_config` | object | Primary reads secondary state for LB IP |
| `dr_failover_function_enabled` | `true`/`false` | Enable automated failover (standby only) |

#### Failover Detection

The DR alarm uses LB backend health metrics with a scale-independent query:

```
(BackendServers - UnHealthyBackendServers) < 1 || UnHealthyBackendServers.absent(2m)
```

This triggers when zero healthy backends remain (complete failure) or metrics disappear (regional outage), regardless of node pool size.

The LoadBalancer Service uses:
- **HTTP health check** on the `healthCheckNodePort` — detects pod-level failures (not just connectivity)
- **Node-label-selector** — filters backends to only nodes running LogScale pods, eliminating false-unhealthy noise

#### Failover Timing

| Stage | Default | Testing |
|-------|---------|---------|
| Health check interval | 60s | 10s |
| Alarm pending duration | 1m | 1m (OCI minimum) |
| Pre-failover validation | 180s | 0s |
| **Total detection → operator scaled** | ~6-7 min | ~2-3 min |

See [DR_OPERATIONS_GUIDE.md](DR_OPERATIONS_GUIDE.md) for failover procedures and recovery runbooks.

## Load Balancer

The `loadbalancer` module creates an OCI Classic Flexible Load Balancer with:

- **Frontend TLS**: Let's Encrypt certificate via cert-manager DNS-01 challenge (OCI DNS webhook)
- **Backend re-encryption**: Uses the `ca-keypair` secret auto-generated by the humio-operator
- **HTTP health check**: On the Kubernetes `healthCheckNodePort` — kube-proxy returns 200 (pods healthy) or 503 (no local pods)
- **Node-label-selector**: Only nodes in `logscale-digest`, `logscale-ingest`, `logscale-ui` pools are LB backends
- **externalTrafficPolicy: Local**: Preserves client IP, routes traffic only to nodes with pods

## Inputs

### Required

| Name | Description |
|------|-------------|
| `workspace_name` | Must match `terraform.workspace` (prevents wrong tfvars on wrong workspace) |
| `tenancy_ocid` | OCI tenancy OCID |
| `root_tenancy_ocid` | Root tenancy OCID (for dynamic group creation) |
| `compartment_ocid` | Compartment OCID |
| `region` | OCI region |
| `user_ocid` | User OCID for API authentication |
| `user_fingerprint` | API key fingerprint |
| `private_key_path` | Path to API private key |
| `cluster_name` | OKE cluster name |
| `logscale_license` | LogScale license key |
| `logscale_public_fqdn` | Public FQDN for LogScale |
| `worker_image_id` | OKE worker node image OCID |
| `ssh_public_key_path` | SSH public key path |
| `ssh_private_key_path` | SSH private key path |
| `cert_issuer_email` | Email for Let's Encrypt certificate issuer |

### Access Control

| Name | Default | Description |
|------|---------|-------------|
| `provision_bastion` | `true` | Enable OCI Bastion Service |
| `endpoint_public_access` | `false` | Enable public K8s API endpoint |
| `bastion_client_allow_list` | `[]` | CIDRs for bastion access (required when bastion enabled) |
| `control_plane_allowed_cidrs` | `[]` | CIDRs for K8s API (required when public endpoint enabled) |
| `public_lb_cidrs` | `[]` | CIDRs for load balancer access |

### Cluster Configuration

| Name | Default | Description |
|------|---------|-------------|
| `kubernetes_version` | `"v1.33.1"` | Kubernetes version |
| `logscale_cluster_type` | `"basic"` | Cluster type: `basic`, `dedicated-ui`, `advanced` |
| `logscale_cluster_size` | `"small"` | Size: `xsmall`, `small`, `medium`, `large`, `xlarge` |
| `target_replication_factor` | `2` | Data replication factor |

### Certificate Configuration

| Name | Default | Description |
|------|---------|-------------|
| `cert_dns01_webhook_enabled` | `false` | Enable DNS-01 ACME challenge via OCI DNS |
| `cert_dns01_provider` | `"oci"` | DNS-01 provider |
| `use_native_webhook` | `false` | Use native Terraform-managed webhook |

## Outputs

| Name | Description |
|------|-------------|
| `cluster_id` | OKE cluster OCID |
| `cluster_name` | OKE cluster name |
| `cluster_endpoint_details` | Cluster API endpoint info |
| `kubeconfig_command` | Command to generate kubeconfig |
| `kubeconfig_tunnel_command` | Command to configure kubectl via tunnel |
| `bastion_service_id` | Bastion service OCID |
| `storage_bucket_name` | Object Storage bucket name |
| `storage_endpoint_base` | S3-compatible endpoint URL |
| `vcn_id` | VCN OCID |
| `resource_summary` | Human-readable summary of deployed resources |

DR-specific outputs (when `dr` is set):

| Name | Description |
|------|-------------|
| `primary_ingest_lb_ip` | Primary cluster load balancer IP |
| `secondary_ingest_lb_ip` | Secondary cluster load balancer IP |
| `steering_policy_id` | DNS Steering Policy OCID |
| `dns_zone_id` | DNS Zone OCID |
| `dns_zone_nameservers` | NS records for DNS zone delegation |
| `storage_encryption_key_value` | Encryption key (shared via remote state) |

## Cluster Sizing

| Size | Nodes | Digest Nodes | Use Case |
|------|-------|--------------|----------|
| `xsmall` | ~15 | 3 | Development |
| `small` | ~26 | 6 | Small production |
| `medium` | ~58 | 21 | Medium production |
| `large` | ~87 | 42 | Large production |
| `xlarge` | ~156 | 78 | Enterprise |

## Module Structure

```
├── main.tf              # Root module configuration
├── variables.tf         # Input variables
├── outputs.tf           # Output values
├── locals.tf            # Local values and cluster sizing
├── validation.tf        # Input validation rules
├── backend.tf           # Remote state backend configuration
├── data_sources.tf      # Data source lookups (DR remote state, etc.)
├── providers.tf         # Provider configuration (OCI, Kubernetes, Helm)
├── versions.tf          # Required provider versions
└── modules/
    ├── oci/
    │   ├── core/                    # VCN, subnets, NSGs, gateways
    │   ├── bastion/                 # OCI Bastion Service
    │   ├── oke/                     # OKE cluster and node pools
    │   ├── storage/                 # Object Storage bucket
    │   ├── global-dns/              # DNS steering policy (DR)
    │   └── dr-failover-function/    # Automated failover via OCI Function (DR)
    └── kubernetes/
        ├── cert-manager-oci-webhook/  # DNS-01 ACME challenge via OCI DNS
        ├── loadbalancer/              # OCI LB Service + Let's Encrypt cert
        └── pre-install/               # Pre-install resources (namespaces, secrets, etc.)
```

## Accessing the Cluster

### With Bastion (Default)

```bash
# Start tunnel
LOCAL_PORT=16443 ./scripts/setup-bastion-tunnel.sh --workspace primary kubectl

# Use kubectl
kubectl --server=https://127.0.0.1:16443 --insecure-skip-tls-verify get nodes
```

### With Public Endpoint

```bash
# Generate kubeconfig
$(terraform output -raw kubeconfig_command)

# Use kubectl directly
kubectl get nodes
```

### DR Dual-Cluster Access

```bash
# Terminal 1: Primary
LOCAL_PORT=16443 ./scripts/setup-bastion-tunnel.sh --workspace primary kubectl

# Terminal 2: Secondary
LOCAL_PORT=16444 ./scripts/setup-bastion-tunnel.sh --workspace secondary kubectl

# Use contexts
export KUBECONFIG=$(pwd)/kubeconfig-dr.yaml  # local file (gitignored)
kubectl --context oci-primary get nodes
kubectl --context oci-secondary get nodes
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Connection timeout | Verify your IP is in `bastion_client_allow_list` or `control_plane_allowed_cidrs` |
| Permission denied | Check SSH key permissions and add to agent: `ssh-add ~/.ssh/id_ed25519` |
| kubectl refused | Ensure tunnel is running: `ps aux \| grep ssh \| grep 6443` |
| Bastion session failed | Verify bastion service is active: `oci bastion bastion get --bastion-id <id>` |

## Documentation

- [DR Operations Guide](DR_OPERATIONS_GUIDE.md) - DR standby setup, failover procedures, and recovery runbooks
- [OCI Network Security](OCI_NETWORK_SECURITY.md) - VCN architecture, NSGs, and security lists
- [DR Failover Function](modules/oci/dr-failover-function/README.md) - Automated failover function details
- [Scripts](scripts/README.md) - Utility scripts (bastion tunnel setup)

## License

Proprietary - CrowdStrike
