# Bastion Module Outputs

# OCI Bastion Service Outputs
output "bastion_service_id" {
  description = "The OCID of the OCI Bastion Service"
  value       = var.provision_bastion ? oci_bastion_bastion.this[0].id : null
}

output "bastion_service_name" {
  description = "The name of the OCI Bastion Service"
  value       = var.provision_bastion ? oci_bastion_bastion.this[0].name : null
}

output "bastion_service_target_subnet" {
  description = "The target subnet ID for the OCI Bastion Service"
  value       = var.provision_bastion ? oci_bastion_bastion.this[0].target_subnet_id : null
}

output "bastion_service_max_session_ttl" {
  description = "The maximum session TTL in seconds for the OCI Bastion Service"
  value       = var.provision_bastion ? oci_bastion_bastion.this[0].max_session_ttl_in_seconds : null
}

output "bastion_service_dns_proxy_status" {
  description = "The DNS proxy status for the OCI Bastion Service"
  value       = var.provision_bastion ? oci_bastion_bastion.this[0].dns_proxy_status : null
}

# Connection Information
output "bastion_connection_info" {
  description = "Information about connecting using the OCI Bastion Service"
  value = var.provision_bastion ? {
    bastion_id         = oci_bastion_bastion.this[0].id
    bastion_name       = oci_bastion_bastion.this[0].name
    target_subnet_id   = oci_bastion_bastion.this[0].target_subnet_id
    max_session_ttl    = oci_bastion_bastion.this[0].max_session_ttl_in_seconds
    allowed_cidrs      = var.bastion_client_allow_list
    create_session_cmd = "oci bastion session create-managed-ssh --bastion-id ${oci_bastion_bastion.this[0].id} --target-resource-id <INSTANCE_OCID> --ssh-public-key-file ${var.ssh_public_key_path}"
  } : null
}

output "bastion_provisioned" {
  description = "Whether the OCI Bastion Service was provisioned"
  value       = var.provision_bastion
}

# Enhanced Multi-Subnet Architecture Outputs
output "compatible_worker_subnets" {
  description = "Map of all worker node subnets accessible via this bastion service"
  value       = var.provision_bastion ? var.node_pool_subnets : {}
}

output "bastion_architecture_summary" {
  description = "Summary of the enhanced bastion architecture for multi-subnet worker node access"
  value = var.provision_bastion ? {
    bastion_subnet_id   = oci_bastion_bastion.this[0].target_subnet_id
    worker_subnet_count = length(var.node_pool_subnets)
    worker_subnet_ids   = [for subnet in var.node_pool_subnets : subnet.id]
    connectivity_method = "VCN-routing-based"
    architecture_type   = "dedicated-bastion-subnet"
    benefits = [
      "Can reach worker nodes in ANY subnet",
      "No subnet compatibility issues",
      "Supports dynamic session creation",
      "Enhanced security with dedicated subnet"
    ]
  } : null
}