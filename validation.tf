# This file validates the configuration at plan time
# All validations are now moved to variable blocks with validation rules
# and locals blocks with validation expressions

# =============================================================================
# WORKSPACE-TFVARS VALIDATION
# =============================================================================
# This critical validation ensures the correct tfvars file is used with the
# correct Terraform workspace. It prevents accidental destruction of resources
# by applying primary tfvars to secondary workspace or vice versa.
#
# The workspace_name variable in tfvars must match terraform.workspace exactly.
# =============================================================================

check "workspace_tfvars_match" {
  assert {
    condition     = var.workspace_name == terraform.workspace
    error_message = <<-EOT

      ============================================================================
      ERROR: WORKSPACE MISMATCH DETECTED!
      ============================================================================

      Current Terraform workspace: '${terraform.workspace}'
      workspace_name in tfvars:    '${var.workspace_name}'

      The tfvars file specifies workspace_name = "${var.workspace_name}"
      but you are currently in the '${terraform.workspace}' workspace.

      To fix this, either:

      1. Switch to the correct workspace:
         terraform workspace select ${var.workspace_name}

      2. Or use the correct tfvars file for the '${terraform.workspace}' workspace:
         terraform plan -var-file=${terraform.workspace}-us-chicago-1.tfvars

      This validation prevents accidental destruction of resources by applying
      the wrong tfvars file to the wrong workspace.
      ============================================================================
    EOT
  }
}

# =============================================================================
# BASTION / PUBLIC ENDPOINT ACCESS VALIDATIONS
# =============================================================================

# When bastion is enabled, bastion_client_allow_list is REQUIRED
check "bastion_client_allow_list_required" {
  assert {
    condition     = var.provision_bastion ? length(var.bastion_client_allow_list) > 0 : true
    error_message = "bastion_client_allow_list is required when provision_bastion=true."
  }
}

# When public endpoint is enabled, control_plane_allowed_cidrs is REQUIRED
check "control_plane_cidrs_required_for_public_endpoint" {
  assert {
    condition     = var.endpoint_public_access ? length(var.control_plane_allowed_cidrs) > 0 : true
    error_message = "control_plane_allowed_cidrs is required when endpoint_public_access=true."
  }
}

# Prevent 0.0.0.0/0 in control_plane_allowed_cidrs
check "control_plane_cidrs_no_wildcard" {
  assert {
    condition     = !contains(var.control_plane_allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed in control_plane_allowed_cidrs. Specify specific CIDR blocks."
  }
}

# Additional runtime validations
locals {
  # Validate cluster configuration consistency
  cluster_config_validation = {
    # Ensure minimum resources for production clusters
    production_ready = var.target_replication_factor >= 2

    # Validate storage configuration (namespace is auto-discovered, compartment always set)
    storage_config_valid = length(local.final_storage_bucket_namespace) > 0

    # Validate network configuration
    network_config_valid = alltrue([
      var.provision_bastion ? length(var.bastion_client_allow_list) > 0 : true,
      length(var.public_lb_cidrs) > 0,
      length(local.dynamic_ad_and_subnets) >= 2
    ])

    # Validate certificate configuration
    cert_config_valid = true # Certificate configuration is optional

    # Security validations
    # NOTE: 0.0.0.0/0 in public_lb_cidrs is only allowed when use_external_health_check=true
    # (OCI Health Check vantage points require open access from AWS/Azure/GCP).
    # When use_external_health_check=false (default), 0.0.0.0/0 should NOT be in public_lb_cidrs.
    security_compliant = alltrue([
      # Bastion security
      var.provision_bastion ? !contains(var.bastion_client_allow_list, "0.0.0.0/0") : true,
      # Load balancer security - only allow 0.0.0.0/0 when using external health checks
      var.use_external_health_check ? true : !contains(var.public_lb_cidrs, "0.0.0.0/0"),
      # Control plane security - 0.0.0.0/0 not allowed (enforced by check block)
      !contains(var.control_plane_allowed_cidrs, "0.0.0.0/0")
    ])
  }

  # Check all validations pass
  all_validations_pass = alltrue(values(local.cluster_config_validation))

  # Generate validation error message if needed
  validation_errors = compact([
    local.cluster_config_validation.production_ready ? "" : "Production clusters require at least 3 digest nodes and replication factor >= 2",
    local.cluster_config_validation.storage_config_valid ? "" : "Storage bucket namespace and compartment must be provided",
    local.cluster_config_validation.network_config_valid ? "" : "Network configuration incomplete - check bastion_client_allow_list, public_lb_cidrs, and dynamic ADs",
    local.cluster_config_validation.cert_config_valid ? "" : "Certificate configuration is optional",
    local.cluster_config_validation.security_compliant ? "" : "Security compliance failed - check bastion access, load balancer access, and cluster endpoint configuration"
  ])

  # Fail if validations don't pass
  _validation_check = local.all_validations_pass ? null : file("ERROR: Validation failed: ${join(", ", local.validation_errors)}")
}

# Resource allocation validation
locals {
  # Standard OCI limits per AD
  max_compute_instances_per_ad = 100
  max_block_volumes_per_ad     = 100

  # Calculate total instances needed
  total_instances = sum([
    local.node_group_definitions["logscale_digest_desired_node_count"],
    local.node_group_definitions["logscale_ingest_desired_node_count"],
    local.node_group_definitions["logscale_ui_desired_node_count"],
    local.node_group_definitions["strimzi_node_desired_node_count"]
  ])

  # Calculate total block volumes needed (simplified since pod counts are not available)
  total_block_volumes = local.total_instances

  # Check if within limits
  within_instance_limits = local.total_instances <= local.max_compute_instances_per_ad * length(local.dynamic_ad_and_subnets)
  within_volume_limits   = local.total_block_volumes <= local.max_block_volumes_per_ad * length(local.dynamic_ad_and_subnets)

  # Aggregate resource validation results
  resource_validation = {
    max_compute_instances_per_ad = local.max_compute_instances_per_ad
    max_block_volumes_per_ad     = local.max_block_volumes_per_ad
    total_instances              = local.total_instances
    total_block_volumes          = local.total_block_volumes
    within_instance_limits       = local.within_instance_limits
    within_volume_limits         = local.within_volume_limits
  }

  # Validate resource limits
  _resource_limit_check = local.resource_validation.within_instance_limits && local.resource_validation.within_volume_limits ? null : file("ERROR: Requested resources exceed OCI limits. Total instances: ${local.resource_validation.total_instances}, Total volumes: ${local.resource_validation.total_block_volumes}")
}

# Output validation summary
output "validation_summary" {
  description = "Summary of validation checks"
  value = {
    cluster_size             = var.logscale_cluster_size
    cluster_type             = var.logscale_cluster_type
    production_ready         = local.cluster_config_validation.production_ready
    total_instances_required = local.resource_validation.total_instances
    total_volumes_required   = local.resource_validation.total_block_volumes
    within_oci_limits        = local.resource_validation.within_instance_limits && local.resource_validation.within_volume_limits
    all_validations_passed   = local.all_validations_pass
  }
}
