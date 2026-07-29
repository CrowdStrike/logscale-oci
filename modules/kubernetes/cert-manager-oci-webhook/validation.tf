# =============================================================================
# Input Validation for cert-manager OCI DNS Webhook Module
# =============================================================================

# Validate that required OCI credentials are provided
locals {
  # Validate OCI credential completeness
  oci_credentials_valid = alltrue([
    length(var.tenancy_ocid) > 0,
    length(var.user_ocid) > 0,
    length(var.fingerprint) > 0,
    length(var.region) > 0,
    length(var.private_key) > 0,
    length(var.compartment_ocid) > 0
  ])

  # Validate namespace configuration
  namespace_valid = length(var.namespace) > 0

  # Validate cert-manager integration settings
  cert_manager_config_valid = alltrue([
    length(var.cert_manager_namespace) > 0,
    length(var.cert_manager_service_account_name) > 0
  ])

  # Validate webhook configuration
  webhook_config_valid = alltrue([
    length(var.group_name) > 0,
    length(var.solver_name) > 0,
    length(var.image_repository) > 0,
    length(var.image_tag) > 0,
    var.replicas >= 1,
    var.replicas <= 10
  ])

  # Validate ClusterIssuer configuration
  cluster_issuer_config_valid = alltrue([
    length(var.cert_issuer_name) > 0,
    length(var.cert_issuer_email) > 0,
    can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.cert_issuer_email))
  ])

  # Validate certificate durations are in valid Go duration format (e.g., "8760h", "8760h0m0s", "30m")
  duration_format_valid = alltrue([
    can(regex("^([0-9]+[hms])+$", var.root_ca_duration)),
    can(regex("^([0-9]+[hms])+$", var.serving_cert_duration))
  ])

  # Validate image pull policy
  image_pull_policy_valid = contains(["Always", "IfNotPresent", "Never"], var.image_pull_policy)

  # Aggregate all validation checks
  all_checks = {
    oci_credentials       = local.oci_credentials_valid
    namespace             = local.namespace_valid
    cert_manager_config   = local.cert_manager_config_valid
    webhook_config        = local.webhook_config_valid
    cluster_issuer_config = local.cluster_issuer_config_valid
    duration_format       = local.duration_format_valid
    image_pull_policy     = local.image_pull_policy_valid
  }

  # Check if all validations pass (skip when disabled)
  all_validations_pass = var.enabled ? alltrue(values(local.all_checks)) : true

  # Generate validation error messages
  validation_errors = var.enabled ? compact([
    local.oci_credentials_valid ? "" : "OCI credentials incomplete - ensure tenancy_ocid, user_ocid, fingerprint, region, private_key, and compartment_ocid are all provided",
    local.namespace_valid ? "" : "Namespace must be specified",
    local.cert_manager_config_valid ? "" : "cert-manager configuration incomplete - ensure cert_manager_namespace and cert_manager_service_account_name are provided",
    local.webhook_config_valid ? "" : "Webhook configuration invalid - ensure group_name, solver_name, image_repository, image_tag are provided and replicas is between 1-10",
    local.cluster_issuer_config_valid ? "" : "ClusterIssuer configuration invalid - ensure cert_issuer_name and valid cert_issuer_email are provided",
    local.duration_format_valid ? "" : "Certificate duration format invalid - must be a Go duration like '8760h', '8760h0m0s', or '30m'",
    local.image_pull_policy_valid ? "" : "image_pull_policy must be one of: Always, IfNotPresent, Never"
  ]) : []

  # Trigger validation failure if checks don't pass
  _validation_check = var.enabled && !local.all_validations_pass ? file("ERROR: Validation failed:\n${join("\n", local.validation_errors)}") : null
}

# Output validation summary for troubleshooting
output "validation_status" {
  description = "Module input validation status"
  value = var.enabled ? {
    enabled                     = var.enabled
    oci_credentials_valid       = local.oci_credentials_valid
    namespace_valid             = local.namespace_valid
    cert_manager_config_valid   = local.cert_manager_config_valid
    webhook_config_valid        = local.webhook_config_valid
    cluster_issuer_config_valid = local.cluster_issuer_config_valid
    duration_format_valid       = local.duration_format_valid
    image_pull_policy_valid     = local.image_pull_policy_valid
    all_validations_passed      = local.all_validations_pass
  } : null
}

output "validation_summary" {
  description = "Backward-compatible alias for validation_status"
  value = var.enabled ? {
    enabled                     = var.enabled
    oci_credentials_valid       = local.oci_credentials_valid
    namespace_valid             = local.namespace_valid
    cert_manager_config_valid   = local.cert_manager_config_valid
    webhook_config_valid        = local.webhook_config_valid
    cluster_issuer_config_valid = local.cluster_issuer_config_valid
    duration_format_valid       = local.duration_format_valid
    image_pull_policy_valid     = local.image_pull_policy_valid
    all_validations_passed      = local.all_validations_pass
  } : null
}
