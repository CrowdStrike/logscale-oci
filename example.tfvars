# =============================================================================
# LogScale OCI Terraform Configuration - Example tfvars
# =============================================================================
# This file provides a template for configuring LogScale on OCI.
# Copy this file and customize for your deployment:
#   - primary.tfvars   (dr="active", manages global DNS)
#   - secondary.tfvars (dr="standby", DR automation)
#   - single.tfvars    (dr="", standalone cluster)
#
# Deployment:
#   terraform workspace new <primary|secondary|single>
#   terraform init -backend-config=backend-configs/primary-oci.hcl
#   terraform apply -var-file="<name>.tfvars" -target=module.oci-core
#   terraform apply -var-file="<name>.tfvars" -target=module.oci-logscale-storage
#   terraform apply -var-file="<name>.tfvars" -target=module.oke
#   terraform apply -var-file="<name>.tfvars" -target=module.pre-install
#   terraform apply -var-file="<name>.tfvars" -target=module.logscale.module.crds
#   terraform apply -var-file="<name>.tfvars" -target=module.logscale
#   terraform apply -var-file="<name>.tfvars"
# =============================================================================

# =============================================================================
# WORKSPACE VALIDATION
# Must match terraform workspace name - prevents applying wrong config
# =============================================================================
workspace_name = "primary" # Options: "primary", "secondary", "single", or custom

# =============================================================================
# OCI AUTHENTICATION
# Required for all OCI API operations
# =============================================================================
tenancy_ocid      = "ocid1.tenancy.oc1..example"
root_tenancy_ocid = "ocid1.tenancy.oc1..example" # Usually same as tenancy_ocid
compartment_ocid  = "ocid1.compartment.oc1..example"
region            = "us-chicago-1"

# API Key Authentication
user_ocid           = "ocid1.user.oc1..example"
user_fingerprint    = "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
private_key_path    = "~/.oci/oci_api_key.pem"
config_file_profile = "DEFAULT" # OCI CLI profile name

# SSH Keys for OKE Node Access
ssh_public_key_path  = "~/.ssh/id_ed25519.pub"
ssh_private_key_path = "~/.ssh/id_ed25519"

# =============================================================================
# NETWORKING
# IMPORTANT: VCN CIDRs must be unique per cluster in the same compartment
# Suggested allocation:
#   Primary:   10.0.0.0/16
#   Secondary: 10.1.0.0/16
#   Single:    10.2.0.0/16
# =============================================================================
vcn_cidr                     = "10.0.0.0/16"
cluster_endpoint_subnet_cidr = "10.0.1.0/28"
lb_subnet_cidr               = "10.0.2.0/24"
pods_cidr                    = "10.0.64.0/18" # Optional: defaults to auto-assigned

# Load Balancer Access Control
# List CIDRs allowed to reach the public load balancer (ports 80/443)
# Note: 0.0.0.0/0 is NOT needed when use_external_health_check=false (default)
public_lb_cidrs = [
  "10.0.0.0/8",     # Internal networks
  "192.168.1.0/24", # Office network
  "203.0.113.0/24", # VPN egress
]

# =============================================================================
# KUBERNETES API ACCESS
# Choose ONE access mode - cannot change after cluster creation
# =============================================================================

# Option A: Bastion Tunnel (Recommended for production)
# Secure private access via OCI Bastion Service
provision_bastion      = true
endpoint_public_access = false
bastion_client_allow_list = [
  "203.0.113.0/24", # Your office/VPN CIDRs allowed to create bastion sessions
]

# Option B: Public Endpoint (Simpler, less secure)
# Direct access with IP allowlist - uncomment below and comment Option A
# provision_bastion      = false
# endpoint_public_access = true
# control_plane_allowed_cidrs = [
#   "203.0.113.0/24", # CIDRs allowed to access K8s API (port 6443)
# ]

# When using bastion tunnel, set this to your tunnel endpoint
# kubernetes_api_host = "https://127.0.0.1:16443"

# =============================================================================
# OKE CLUSTER CONFIGURATION
# =============================================================================
cluster_name       = "logscale-prod"
kubernetes_version = "v1.33.1"

# Worker Node Image (Oracle Linux with OKE optimizations)
# Find latest: oci compute image list --compartment-id <ocid> --operating-system "Oracle Linux"
worker_image_id = "ocid1.image.oc1.<region>.example"

# =============================================================================
# LOGSCALE APPLICATION
# =============================================================================
logscale_cluster_type  = "advanced" # Options: "basic", "advanced"
logscale_cluster_size  = "xsmall"   # Options: "xsmall", "small", "medium", "large"
logscale_image_version = "1.210.0"
oke_cluster_type       = "BASIC_CLUSTER" # Options: "BASIC_CLUSTER", "ENHANCED_CLUSTER"
logscale_public_fqdn   = "logscale.example.com"
logscale_namespace     = "logging"
image_pull_secret      = "dockerhub-creds"

# License Key (JWT format)
logscale_license = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzUxMiJ9.example..."

# =============================================================================
# DNS CONFIGURATION
# =============================================================================
dns_zone_name = "example.com" # Must be delegated to OCI DNS

# External DNS Controller (creates A records for services)
external_dns_enabled        = true
external_dns_domain_filters = ["example.com"]

# =============================================================================
# DR CONFIGURATION
# =============================================================================
# Options:
#   "active"  - Primary in DR pair (manages global DNS, health checks)
#   "standby" - Secondary in DR pair (DR automation, reads from primary bucket)
#   ""        - Standalone cluster (no DR infrastructure)
dr = "active"

# Two-Phase Promotion (only relevant when dr="active" after promotion)
# Phase 1: dr_use_dedicated_routing=false (zero-downtime, generic selectors)
# Phase 2: dr_use_dedicated_routing=true  (optimal routing to UI/Ingest pools)
dr_use_dedicated_routing = true

# -----------------------------------------------------------------------------
# Global DNS (only set manage_global_dns=true on ONE cluster)
# -----------------------------------------------------------------------------
manage_global_dns      = true # true for primary/single, false for secondary
create_global_dns_zone = true # true to create zone, false to use existing

# Hostnames for DR failover DNS steering
global_logscale_hostname    = "logscale"           # Global FQDN for clients
primary_logscale_hostname   = "logscale-primary"   # Direct access to primary
secondary_logscale_hostname = "logscale-secondary" # Direct access to secondary

# -----------------------------------------------------------------------------
# Remote State Configuration (required for DR)
# -----------------------------------------------------------------------------
# Primary reads secondary state for LB IP; Secondary reads primary for encryption key

# For PRIMARY cluster - read secondary's outputs
# secondary_remote_state_config = {
#   backend   = "oci"
#   workspace = "secondary"
#   config = {
#     bucket              = "terraform-state-bucket"
#     namespace           = "tenancy-namespace"
#     region              = "us-chicago-1"
#     key                 = "env:/logscale-oci-oke"
#     auth                = "ApiKey"
#     config_file_profile = "DEFAULT"
#   }
# }

# For SECONDARY cluster - read primary's outputs (REQUIRED)
# primary_remote_state_config = {
#   backend   = "oci"
#   workspace = "primary"
#   config = {
#     bucket              = "terraform-state-bucket"
#     namespace           = "tenancy-namespace"
#     region              = "us-chicago-1"
#     key                 = "env:/logscale-oci-oke"
#     auth                = "ApiKey"
#     config_file_profile = "DEFAULT"
#   }
# }

# -----------------------------------------------------------------------------
# DR Recovery Configuration (SECONDARY only)
# S3_RECOVER_FROM_* env vars - refers to PRIMARY (source) cluster
# -----------------------------------------------------------------------------
# s3_recover_from_region                     = "us-chicago-1"
# s3_recover_from_bucket                     = "" # Auto-fetched from primary remote state
# s3_recover_from_encryption_key_secret_name = "dr-secondary-oci-storage-encryption"
# s3_recover_from_encryption_key_secret_key  = "oci-storage-encryption-key"
# s3_recover_from_replace_region             = "us-chicago-1/us-chicago-1"

# -----------------------------------------------------------------------------
# DR Failover Function (SECONDARY only)
# Automated operator scaling on primary failure
# -----------------------------------------------------------------------------
# dr_failover_function_enabled                     = true
# dr_failover_function_target_node_count           = 1
# dr_failover_function_timeout                     = 300
# dr_failover_function_memory_mb                   = 256
# dr_failover_function_log_retention_days          = 30  # Must be 30/60/90/120/150/180
# dr_failover_function_skip_secondary_health_check = false
# dr_failover_function_pre_failover_failure_seconds = 180 # Use 0 for testing only

# Testing Configuration (faster failover - NOT for production)
# dr_failover_function_alarm_pending_duration                = "PT1M" # OCI minimum
# dr_failover_function_alarm_repeat_notification_duration    = "PT5M"
# dr_failover_function_absent_detection_period               = "1m"
# dr_failover_function_primary_health_check_interval_seconds = 10

# OCIR Image Build (auto-builds DR function container)
# dr_failover_function_auto_build_image = true
# ocir_username = "username" # Native IAM: "user", IDCS: "oracleidentitycloudservice/user@email.com"

# =============================================================================
# COMPONENT VERSIONS
# =============================================================================
# Strimzi Kafka
strimzi_operator_version       = "0.47.0"
strimzi_operator_chart_version = "0.47.0"
provision_kafka_servers        = true
byo_kafka_connection_string    = "" # Leave empty when provision_kafka_servers=true

# Humio Operator
humio_operator_version       = "0.32.0"
humio_operator_chart_version = "0.32.0"

# Other Components
cm_version                       = "v1.15.1" # cert-manager
topo_lvm_chart_version           = "15.5.2"  # TopoLVM storage

# =============================================================================
# CERTIFICATE CONFIGURATION
# =============================================================================
cert_issuer_email               = "admin@example.com"
use_own_certificate_for_ingress = false

# -----------------------------------------------------------------------------
# DNS-01 ACME Challenge Configuration
# Required when public_lb_cidrs blocks Let's Encrypt HTTP-01 validation
# Enables certificate issuance using OCI DNS for domain validation
# -----------------------------------------------------------------------------
cert_dns01_webhook_enabled = true
cert_dns01_provider        = "oci"

# ClusterIssuer name for cert-manager (defaults to "letsencrypt-prod")
# cluster_issuer_name = "letsencrypt-prod"

# Let's Encrypt server (production or staging)
# Production: "https://acme-v02.api.letsencrypt.org/directory"
# Staging: "https://acme-staging-v02.api.letsencrypt.org/directory"
# letsencrypt_server = "https://acme-v02.api.letsencrypt.org/directory"

# DNS-01 Provider Configuration
cert_dns01_provider        = "oci"
cert_dns01_webhook_enabled = true
use_native_webhook         = true

# =============================================================================
# RESOURCE NAMING
# =============================================================================
resource_name_prefix = "log"

# Tags applied to all OCI resources
common_tags = {
  App         = "humio"
  ManagedBy   = "Terraform"
  Environment = "production"
  Region      = "us-chicago-1"
}

# =============================================================================
# KUBERNETES CONFIGURATION
# =============================================================================
kubectl_context    = "oci-primary" # Context name in kubeconfig-dr.yaml

# =============================================================================
# OPTIONAL: Humio Operator Resource Limits
# =============================================================================
humio_operator_extra_values = {
  "operator.resources.limits.cpu"      = "250m"
  "operator.resources.limits.memory"   = "750Mi"
  "operator.resources.requests.cpu"    = "250m"
  "operator.resources.requests.memory" = "750Mi"
}
