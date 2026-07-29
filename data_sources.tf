# Data sources for the OCI LogScale infrastructure

# ============================================================================
# Remote State Data Sources
# ============================================================================

# Remote state data source for secondary clusters to access primary outputs
data "terraform_remote_state" "primary" {
  for_each  = local.effective_primary_remote_state_config == null ? {} : { primary = local.effective_primary_remote_state_config }
  backend   = each.value.backend
  workspace = each.value.workspace
  config    = each.value.config
}

# Remote state data source for primary clusters to access secondary outputs
# This enables dynamic discovery of secondary_ingest_lb_ip for health check monitoring
data "terraform_remote_state" "secondary" {
  for_each  = local.effective_secondary_remote_state_config == null ? {} : { secondary = local.effective_secondary_remote_state_config }
  backend   = each.value.backend
  workspace = each.value.workspace
  config    = each.value.config
}

# ============================================================================
# OCI Data Sources
# ============================================================================

# Availability domains for the compartment
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

# Object Storage namespace for this tenancy/compartment
# Provides a safe default for storage_bucket_namespace when remote state doesn't supply it
data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

# Detect OCI CLI profile if not explicitly configured
data "external" "oci_profile" {
  count = var.config_file_profile == "" ? 1 : 0
  program = ["bash", "-c", <<-EOT
    # Try to get the default profile from OCI config
    default_profile=$(oci config list --query 'data[?is_default==\`true\`].profile_name | [0]' --raw-output 2>/dev/null || echo "")

    # If no default found, check environment variable
    if [ -z "$default_profile" ] || [ "$default_profile" = "null" ]; then
      default_profile="$${OCI_CLI_PROFILE:-DEFAULT}"
    fi

    # Output as JSON
    echo "{\"profile\":\"$default_profile\"}"
  EOT
  ]
}

# ============================================================================
# Kubernetes Data Sources
# ============================================================================

# LogScale load balancer IP for global DNS and standby discovery
# The service is created by the pre-install module as ${cluster_name}-lb in the logscale namespace
data "kubernetes_service" "logscale_lb" {
  count = (var.manage_global_dns || var.dr == "standby") ? 1 : 0

  metadata {
    name      = "${var.cluster_name}-lb"
    namespace = var.logscale_namespace
  }

  depends_on = [module.loadbalancer]
}

# ============================================================================
# OCI Classic Load Balancer Data Source for Health Monitoring
# ============================================================================
# Look up all Classic Load Balancers in the compartment to find the nginx-ingress LB OCID
# This is needed for LB backend health metrics (recommended for DR monitoring)
data "oci_load_balancer_load_balancers" "all" {
  compartment_id = var.compartment_ocid
  state          = "ACTIVE"
}

# ============================================================================
# OCI Health Check Vantage Points Data Source
# ============================================================================
# Retrieves the list of OCI Health Check vantage points (external cloud provider
# locations: AWS, Azure, GCP) from which health checks probe targets.
# This data source is used to dynamically add vantage point IPs to security rules
# so the health check service can reach the load balancer.
#
# Important: OCI Health Checks use EXTERNAL vantage points only (no OCI-internal
# option). Without allowing these IPs, health checks will always report unhealthy.
data "oci_health_checks_vantage_points" "all" {}
