# ============================================================================
# Remote State Configuration for DR
# ============================================================================
# OCI Backend Workspace Workaround:
# The OCI backend stores workspace state at path: tf-state-env/{workspace}/{key}
# However, terraform_remote_state does NOT properly prepend this path when reading
# from a different workspace. We must construct the full key path manually.
#
# Example: workspace="primary", key="env:/logscale-oci-oke"
#   Actual path in bucket: tf-state-env/primary/env:/logscale-oci-oke
#   But terraform_remote_state tries: env:/logscale-oci-oke (WRONG!)
#
# Solution: Use workspace="default" (no prefix) and manually construct the full key.

locals {
  # Extract workspace and key from primary_remote_state_config
  _primary_workspace = try(var.primary_remote_state_config.workspace, "default")
  _primary_base_key  = try(var.primary_remote_state_config.config.key, "")

  # Construct full path: tf-state-env/{workspace}/{key}
  # Only add prefix if workspace is not "default"
  _primary_full_key = (
    local._primary_workspace != "default" && local._primary_base_key != ""
    ? "tf-state-env/${local._primary_workspace}/${local._primary_base_key}"
    : local._primary_base_key
  )

  # Build effective config with corrected key path
  effective_primary_remote_state_config = (
    var.primary_remote_state_config != null
    ? {
      backend   = try(var.primary_remote_state_config.backend, "oci")
      workspace = "default" # Always use "default" since we manually construct the full key path
      config = merge(
        var.primary_remote_state_config.config,
        { key = local._primary_full_key }
      )
    }
    : null
  )

  # Extract workspace and key from secondary_remote_state_config (primary reads secondary's state)
  _secondary_workspace = try(var.secondary_remote_state_config.workspace, "default")
  _secondary_base_key  = try(var.secondary_remote_state_config.config.key, "")

  # Construct full path for secondary: tf-state-env/{workspace}/{key}
  _secondary_full_key = (
    local._secondary_workspace != "default" && local._secondary_base_key != ""
    ? "tf-state-env/${local._secondary_workspace}/${local._secondary_base_key}"
    : local._secondary_base_key
  )

  # Build effective config for secondary remote state
  effective_secondary_remote_state_config = (
    var.secondary_remote_state_config != null
    ? {
      backend   = try(var.secondary_remote_state_config.backend, "oci")
      workspace = "default" # Always use "default" since we manually construct the full key path
      config = merge(
        var.secondary_remote_state_config.config,
        { key = local._secondary_full_key }
      )
    }
    : null
  )
}

# ============================================================================
# Resource Naming and Configuration
# ============================================================================

locals {
  # Resource naming prefix using cluster_name for readable, identifiable bucket names
  resource_name_prefix = var.cluster_name

  # Load and parse cluster size configurations
  cluster_size_template = jsondecode(
    templatefile("${path.module}/cluster_size.tpl", {})
  )

  # Validate cluster size exists
  cluster_size_validation = contains(
    keys(local.cluster_size_template),
    var.logscale_cluster_size
  ) ? null : file("ERROR: Invalid cluster size '${var.logscale_cluster_size}'")

  # Get node group definitions for selected cluster size
  node_group_definitions = local.cluster_size_template[var.logscale_cluster_size]

  # Common resource tags
  common_tags = {
    Environment             = terraform.workspace
    Application             = "LogScale"
    ClusterSize             = var.logscale_cluster_size
    ClusterType             = var.logscale_cluster_type
    ManagedBy               = "Terraform"
    CreatedDate             = formatdate("YYYY-MM-DD", timestamp())
    ResourcePrefix          = local.resource_name_prefix
    "Oracle-Tags.CreatedBy" = "terraform"
    "Oracle-Tags.CreatedOn" = formatdate("YYYY-MM-DD'T'hh:mm:ss", timestamp())
  }

  # Kubernetes namespace labels
  k8s_common_labels = {
    "app.kubernetes.io/name"       = "logscale"
    "app.kubernetes.io/instance"   = var.cluster_name
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/version"    = var.logscale_image_version
  }

  # logscale-kubernetes uses k8s_namespace_prefix for all supporting namespaces.
  # Keep cert-manager co-located with that module's namespace convention.
  cert_manager_namespace = format("%s-cert", var.logscale_namespace)

  # ACME HTTP-01 reachability heuristic:
  # - HTTP-01 requires port 80 to be reachable from Let's Encrypt validation infrastructure.
  # - In this repo, port 80 is governed by `public_lb_cidrs` (security lists + NSGs).
  # - In DR mode, the standby cluster typically cannot satisfy HTTP-01 for the global FQDN
  #   because it does not receive live traffic until failover.
  acme_http01_publicly_reachable = contains(toset([for cidr in var.public_lb_cidrs : trimspace(cidr)]), "0.0.0.0/0")

  logscale_public_fqdn_is_global = (
    trimspace(var.global_logscale_hostname) != "" &&
    trimspace(var.dns_zone_name) != "" &&
    trimspace(var.logscale_public_fqdn) == "${trimspace(var.global_logscale_hostname)}.${trimspace(var.dns_zone_name)}"
  )

  acme_http01_likely_reachable = local.acme_http01_publicly_reachable && !(
    var.dr == "standby" && local.logscale_public_fqdn_is_global
  )

  acme_http01_blocked = !local.acme_http01_likely_reachable

  # When true, this repo deploys the native OCI DNS-01 webhook + ClusterIssuer and
  # disables the default HTTP-01 issuer in ../logscale-kubernetes.
  enable_cert_manager_dns01 = (
    var.cert_dns01_provider == "oci" &&
    var.cert_dns01_webhook_enabled &&
    (
      var.cert_dns01_webhook_mode == "always" ||
      (var.cert_dns01_webhook_mode == "auto" && local.acme_http01_blocked)
    )
  )

  # Effective logscale_public_fqdn: global hostname for DR mode, cluster-specific otherwise
  effective_logscale_public_fqdn = (
    var.dr != "" && trimspace(var.global_logscale_hostname) != "" && trimspace(var.dns_zone_name) != ""
    ? "${trimspace(var.global_logscale_hostname)}.${trimspace(var.dns_zone_name)}"
    : var.logscale_public_fqdn
  )

  # Storage configuration (uses same region as OKE cluster)
  storage_config = {
    bucket_name = "${local.resource_name_prefix}-logscale-data"
    endpoint    = local.final_storage_bucket_namespace != "" ? "https://${local.final_storage_bucket_namespace}.compat.objectstorage.${var.region}.oraclecloud.com" : ""
    region      = var.region
  }

  # Network configuration for OKE (removed - using variables instead)

  # Validate required configurations
  # Storage bucket compartment always uses compartment_ocid (no separate variable needed)
  final_storage_bucket_compartment = var.compartment_ocid

  validations = {
    storage_config = local.final_storage_bucket_namespace != "" ? null : file("ERROR: Storage bucket namespace must be provided")

    node_config = true ? null : file("ERROR: Cluster size configuration validation")
  }

  # Dynamic AD and Subnets Configuration
  # Automatically retrieves all availability domains and generates subnets
  dynamic_ad_and_subnets = {
    for i, ad in data.oci_identity_availability_domains.ads.availability_domains :
    "ad${i + 1}" => {
      ad          = ad.name
      subnet_cidr = cidrsubnet(var.vcn_cidr, 4, i + 10) # Creates /20 subnets: 10.0.160.0/20, 10.0.176.0/20, 10.0.192.0/20
      name        = "${var.cluster_name}-ad-${i + 1}-subnet"
    }
  }
  # Bastion target subnet selection logic
  # Select the first available worker node subnet for bastion targeting
  # This ensures bastion can reach worker nodes in at least one subnet
  bastion_target_subnet_id = var.provision_bastion ? values(module.oci-core.node_pool_subnets)[0].id : null
}

locals {
  # Try to get cluster ID from module output first, fall back to data source
  # When multiple clusters exist with the same name, match by VCN ID to get the correct one
  matched_cluster_index = try(
    index([for c in data.oci_containerengine_cluster.existing : c.vcn_id], module.oci-core.vcn_id),
    0
  )

  cluster_id = try(
    module.oke.cluster_id,
    length(data.oci_containerengine_clusters.existing.clusters) > 0 ? data.oci_containerengine_clusters.existing.clusters[local.matched_cluster_index].id : null
  )

  # Dynamically detect OCI CLI profile
  # Try to get from environment variable first, then use external data source as fallback
  oci_profile = coalesce(
    var.config_file_profile != "" ? var.config_file_profile : null,
    try(data.external.oci_profile[0].result.profile, null),
    "DEFAULT"
  )

  # Remote DR outputs if remote state configured (standby cluster reads primary)
  remote_dr_outputs = (
    local.effective_primary_remote_state_config != null
    && lookup(data.terraform_remote_state.primary, "primary", null) != null
    && can(data.terraform_remote_state.primary["primary"].outputs)
    ? data.terraform_remote_state.primary["primary"].outputs
    : null
  )

  # Remote secondary outputs if remote state configured (primary cluster reads secondary)
  # This enables dynamic discovery of secondary_ingest_lb_ip for health check monitoring
  remote_secondary_outputs = (
    local.effective_secondary_remote_state_config != null
    && lookup(data.terraform_remote_state.secondary, "secondary", null) != null
    && can(data.terraform_remote_state.secondary["secondary"].outputs)
    ? data.terraform_remote_state.secondary["secondary"].outputs
    : null
  )

  # Remote (primary) values pulled from state when available
  remote_primary_bucket_name = try(local.remote_dr_outputs.storage_bucket_name, null)
  remote_primary_region      = try(local.remote_dr_outputs.region, null)
  remote_primary_namespace   = try(local.remote_dr_outputs.storage_bucket_namespace, null)

  # Namespace discovery order:
  # 1. Primary remote state (when configured and non-empty) – used by standby clusters.
  # 2. Data source discovery in this tenancy via oci_objectstorage_namespace.
  remote_state_namespace_available = (
    local.remote_primary_namespace != null && trimspace(local.remote_primary_namespace) != ""
  )

  discovered_namespace = try(data.oci_objectstorage_namespace.this.namespace, null)

  final_storage_bucket_namespace = (
    local.remote_state_namespace_available
    ? trimspace(local.remote_primary_namespace)
    : (
      local.discovered_namespace != null && trimspace(local.discovered_namespace) != ""
      ? trimspace(local.discovered_namespace)
      : ""
    )
  )

  # Final values prefer remote state when available, otherwise use provided tfvars
  final_s3_recover_from_region = local.remote_primary_region != null ? local.remote_primary_region : var.s3_recover_from_region
  final_s3_recover_from_bucket = local.remote_primary_bucket_name != null ? local.remote_primary_bucket_name : var.s3_recover_from_bucket

  # Replacement region convenience (<primary>/<secondary>)
  fallback_s3_recover_from_replace_region = (
    try(local.remote_dr_outputs.region, null) != null && var.region != null ?
    format("%s/%s", local.remote_dr_outputs.region, var.region) :
    null
  )
  final_s3_recover_from_replace_region = local.fallback_s3_recover_from_replace_region != null ? local.fallback_s3_recover_from_replace_region : var.s3_recover_from_replace_region

  # Replacement bucket convenience (<primary-bucket>/<secondary-bucket>)
  # This allows LogScale to translate bucket paths when reading from primary storage
  fallback_s3_recover_from_replace_bucket = (
    local.remote_primary_bucket_name != null && local.remote_primary_bucket_name != "" ?
    format("%s/%s", local.remote_primary_bucket_name, try(module.oci-logscale-storage.bucket_name, "")) :
    null
  )
  final_s3_recover_from_replace_bucket = (
    var.s3_recover_from_replace_bucket != null && var.s3_recover_from_replace_bucket != "" ?
    var.s3_recover_from_replace_bucket :
    local.fallback_s3_recover_from_replace_bucket
  )

  # S3-compatible endpoint for OCI Object Storage (required for DR recovery)
  # Constructed from primary's namespace and region when available from remote state
  fallback_s3_recover_from_endpoint_base = (
    local.remote_primary_namespace != null && local.remote_primary_region != null ?
    format("https://%s.compat.objectstorage.%s.oraclecloud.com", local.remote_primary_namespace, local.remote_primary_region) :
    null
  )
  final_s3_recover_from_endpoint_base = (
    var.s3_recover_from_endpoint_base != null && var.s3_recover_from_endpoint_base != "" ?
    var.s3_recover_from_endpoint_base :
    local.fallback_s3_recover_from_endpoint_base
  )

  # DR recovery environment variables (only set when dr="standby")
  # Using a separate local to avoid conditional type mismatch with mixed value/valueFrom objects
  _dr_recovery_envvars_raw = [
    {
      name      = "S3_RECOVER_FROM_REPLACE_REGION"
      value     = local.final_s3_recover_from_replace_region
      valueFrom = null
    },
    {
      name      = "S3_RECOVER_FROM_REPLACE_BUCKET"
      value     = local.final_s3_recover_from_replace_bucket
      valueFrom = null
    },
    {
      name      = "S3_RECOVER_FROM_BUCKET"
      value     = local.final_s3_recover_from_bucket
      valueFrom = null
    },
    {
      name      = "S3_RECOVER_FROM_REGION"
      value     = local.final_s3_recover_from_region
      valueFrom = null
    },
    {
      name      = "S3_RECOVER_FROM_ENDPOINT_BASE"
      value     = local.final_s3_recover_from_endpoint_base
      valueFrom = null
    },
    {
      name      = "S3_RECOVER_FROM_PATH_STYLE_ACCESS"
      value     = var.s3_recover_from_path_style_access != null ? tostring(var.s3_recover_from_path_style_access) : "true"
      valueFrom = null
    },
    {
      name  = "S3_RECOVER_FROM_ENCRYPTION_KEY"
      value = null
      valueFrom = {
        secretKeyRef = {
          name = module.pre-install.oci_storage_encryption_key_secret_name
          key  = module.pre-install.oci_storage_encryption_key_secret_key
        }
      }
    },
    {
      name      = "ENABLE_ALERTS"
      value     = "false"
      valueFrom = null
    },
  ]

  dr_recovery_envvars = local._dr_recovery_envvars_raw

  # Active mode settings
  dr_active_envvars = var.dr == "active" ? [
    {
      name      = "ENABLE_ALERTS"
      value     = "true"
      valueFrom = null
    },
  ] : []

  # Common DR settings (applied to both active and standby)
  dr_common_envvars = var.dr != "" ? [
    {
      # Required for DR: allows LogScale to use endpoint config from bucket entities
      name      = "BUCKET_STORAGE_MULTIPLE_ENDPOINTS"
      value     = "true"
      valueFrom = null
    },
  ] : []

  # Combine all DR-related LogScale env vars
  # Use flatten pattern to avoid conditional type mismatch with mixed value/valueFrom objects
  logscale_dr_envvars = flatten([
    var.dr == "standby" ? [local.dr_recovery_envvars] : [],
    local.dr_active_envvars,
    local.dr_common_envvars
  ])



  # DR peer bucket configuration for cross-region read access
  # Priority: explicit tfvars -> remote state -> recover_from_bucket tfvar
  effective_dr_peer_bucket = try(
    coalesce(
      var.dr_primary_bucket_name,
      local.remote_primary_bucket_name,
      var.s3_recover_from_bucket
    ),
    null
  )

  # Primary encryption key from remote state (only for standby clusters)
  remote_primary_encryption_key = var.dr == "standby" ? try(local.remote_dr_outputs.storage_encryption_key_value, null) : null

  # DR failover health checks (from remote state when available)
  remote_primary_health_check_id   = try(local.remote_dr_outputs.primary_health_check_id, null)
  remote_secondary_health_check_id = try(local.remote_dr_outputs.secondary_health_check_id, null)

  final_primary_health_check_id = local.remote_primary_health_check_id != null && trimspace(local.remote_primary_health_check_id) != "" ? local.remote_primary_health_check_id : (
    trimspace(var.dr_primary_health_check_id) != "" ? var.dr_primary_health_check_id : null
  )

  final_secondary_health_check_id = local.remote_secondary_health_check_id != null && trimspace(local.remote_secondary_health_check_id) != "" ? local.remote_secondary_health_check_id : (
    trimspace(var.dr_secondary_health_check_id) != "" ? var.dr_secondary_health_check_id : null
  )

  # Steering policy IDs (available only on active cluster / primary state)
  remote_steering_policy_id           = try(local.remote_dr_outputs.steering_policy_id, null)
  remote_steering_policy_attachment   = try(local.remote_dr_outputs.steering_policy_attachment_id, null)
  final_steering_policy_id            = local.remote_steering_policy_id != null && trimspace(local.remote_steering_policy_id) != "" ? local.remote_steering_policy_id : null
  final_steering_policy_attachment_id = local.remote_steering_policy_attachment != null && trimspace(local.remote_steering_policy_attachment) != "" ? local.remote_steering_policy_attachment : null

  # Ingest LB IPs - dynamically discovered from kubernetes service or remote state
  # For primary (active) cluster: use local LB IP as primary, secondary remote state for secondary
  # For secondary (standby) cluster: use primary remote state for primary, local LB IP for secondary
  local_lb_ingress_ips = try(
    [for ing in data.kubernetes_service.logscale_lb[0].status[0].load_balancer[0].ingress : ing.ip if try(ing.ip, "") != ""],
    []
  )

  # Prefer a public VIP if multiple are reported (OCI may include both public + private VIPs).
  # This avoids accidentally publishing an RFC1918 address into global DNS records.
  local_lb_ip = try(
    [for ip in local.local_lb_ingress_ips : ip if !can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.)", ip))][0],
    try(local.local_lb_ingress_ips[0], "")
  )

  # Find the Classic Load Balancer OCID by matching the local LB IP address
  # This is needed for LB backend health monitoring (recommended for DR)
  # Classic LB ip_address_details is an array of objects: [{ip_address: "...", is_public: true/false, ...}]
  local_lb_ocid = try(
    [for lb in data.oci_load_balancer_load_balancers.all.load_balancers :
      lb.id if anytrue([for ip in lb.ip_address_details : contains(local.local_lb_ingress_ips, ip.ip_address)])
    ][0],
    ""
  )

  final_primary_ingest_lb_ip = var.dr == "active" ? (
    local.local_lb_ip != "" ? local.local_lb_ip : var.primary_ingest_lb_ip
    ) : (
    local.remote_dr_outputs != null ? try(local.remote_dr_outputs.primary_ingest_lb_ip, var.primary_ingest_lb_ip) : var.primary_ingest_lb_ip
  )

  # For active cluster: use secondary remote state to dynamically get secondary's LB IP
  # For standby cluster: use local LB IP (this cluster IS the secondary)
  final_secondary_ingest_lb_ip = var.dr == "standby" ? (
    local.local_lb_ip != "" ? local.local_lb_ip : var.secondary_ingest_lb_ip
    ) : (
    # Active cluster reads from secondary remote state
    local.remote_secondary_outputs != null ? try(local.remote_secondary_outputs.secondary_ingest_lb_ip, var.secondary_ingest_lb_ip) : var.secondary_ingest_lb_ip
  )

  # Primary LB OCID - needed for LB backend health monitoring (Option B)
  # For active cluster: use local LB OCID
  # For standby cluster: read from primary's remote state
  final_primary_lb_ocid = var.dr == "active" ? (
    local.local_lb_ocid
    ) : (
    local.remote_dr_outputs != null ? try(local.remote_dr_outputs.primary_ingest_lb_ocid, "") : ""
  )

}
