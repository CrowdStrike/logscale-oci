/**
 * ## Module: oci/bastion
 * This module creates an OCI Bastion Service for secure access to OKE worker nodes across multiple subnets.
 *
 * ### Enhanced Multi-Subnet Architecture:
 * - Creates bastion service in a dedicated bastion subnet
 * - Provides connectivity to ALL worker node subnets via VCN routing
 * - Eliminates subnet compatibility issues between bastion and worker nodes
 * - Supports dynamic bastion session creation to any worker node in any subnet
 *
 * ### Network Architecture:
 * - Bastion Subnet: Dedicated /24 subnet for OCI Bastion Service
 * - Worker Subnets: Multiple AD-specific subnets for worker nodes
 * - VCN Routing: Automatic routing between bastion and all worker subnets
 * - Security Groups: NSG-based access control for enhanced security
 */

# OCI Bastion Service (managed service for secure SSH access)
resource "oci_bastion_bastion" "this" {
  count = var.provision_bastion ? 1 : 0

  # Basic configuration
  bastion_type   = "STANDARD"
  compartment_id = var.compartment_ocid
  name           = "${var.cluster_name}-bastion-service"

  # Network configuration
  target_subnet_id = var.target_subnet_id

  # Client CIDR block allowlist
  client_cidr_block_allow_list = var.bastion_client_allow_list

  # Maximum session TTL in seconds (30 minutes to 3 hours)
  max_session_ttl_in_seconds = var.max_session_ttl

  # DNS proxy configuration
  dns_proxy_status = var.enable_dns_proxy ? "ENABLED" : "DISABLED"

  # Tags
  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "Purpose"     = "LogScale-OKE-Bastion-Service"
    "Environment" = terraform.workspace
    "ClusterName" = var.cluster_name
    "Type"        = "Managed-Service"
  })

  defined_tags = var.defined_tags

  lifecycle {
    ignore_changes = [defined_tags]
  }
}