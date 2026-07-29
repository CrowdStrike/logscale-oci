# OKE Cluster Information
output "cluster_id" {
  description = "The OCID of the OKE cluster"
  value       = module.oke.cluster_id
}

output "cluster_name" {
  description = "The name of the OKE cluster"
  value       = var.cluster_name
}

output "cluster_kubernetes_version" {
  description = "The Kubernetes version of the cluster"
  value       = var.kubernetes_version
}

# Kubernetes Configuration
output "kubeconfig_command" {
  description = "Command to update local kubeconfig"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${module.oke.cluster_id} --file $HOME/.kube/config --region ${var.region} --token-version 2.0.0 --profile ${local.oci_profile}"
}

output "kubeconfig_tunnel_command" {
  description = "Command to configure kubeconfig for SSH tunnel access (requires SSH tunnel to be established separately)"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${module.oke.cluster_id} --file $HOME/.kube/config --region ${var.region} --token-version 2.0.0 --profile ${local.oci_profile} && kubectl config set-cluster cluster-${module.oke.cluster_id} --server=https://localhost:6443 --insecure-skip-tls-verify=true && kubectl config set-credentials user-$(echo '${module.oke.cluster_id}' | cut -d'.' -f5) --exec-command=oci --exec-arg=ce --exec-arg=cluster --exec-arg=generate-token --exec-arg=--cluster-id --exec-arg=${module.oke.cluster_id} --exec-arg=--region --exec-arg=${var.region} --exec-arg=--profile --exec-arg=${local.oci_profile} --exec-api-version=client.authentication.k8s.io/v1beta1 && kubectl config set-context $(kubectl config current-context) --cluster=cluster-${module.oke.cluster_id} --user=user-$(echo '${module.oke.cluster_id}' | cut -d'.' -f5)"
  sensitive   = true
}

# Kubeconfig from OKE module - use for on-demand file generation
# Generate file with: terraform output -raw kubeconfig_yaml > kubeconfig.yaml
output "kubeconfig" {
  description = "Kubeconfig object with cluster_name as context name"
  value       = module.oke.kubeconfig_with_cluster_name
  sensitive   = true
}



output "oci_profile_used" {
  description = "The OCI CLI profile being used for this deployment"
  value       = local.oci_profile
}

output "region" {
  description = "The OCI region where resources are deployed"
  value       = var.region
}

output "compartment_ocid" {
  description = "The OCID of the compartment where resources are deployed"
  value       = var.compartment_ocid
}

output "cluster_ca_certificate" {
  description = "Base64 encoded cluster CA certificate"
  value       = module.oke.cluster_ca_certificate
  sensitive   = true
}

# Cluster Endpoint Information
output "cluster_endpoint_details" {
  description = "Detailed cluster endpoint information including public and private endpoints"
  value       = module.oke.cluster_endpoint_details
}

# OCI Bastion Service Access
output "bastion_service_id" {
  description = "OCID of the OCI Bastion Service"
  value       = var.provision_bastion ? module.oci-bastion[0].bastion_service_id : null
}

output "bastion_service_name" {
  description = "Name of the OCI Bastion Service"
  value       = var.provision_bastion ? module.oci-bastion[0].bastion_service_name : null
}

output "bastion_connection_info" {
  description = "Essential OCI Bastion Service connection information"
  value = var.provision_bastion ? {
    bastion_id       = module.oci-bastion[0].bastion_service_id
    bastion_name     = module.oci-bastion[0].bastion_service_name
    target_subnet_id = module.oci-bastion[0].bastion_service_target_subnet
    allowed_cidrs    = var.bastion_client_allow_list

    # PORT_FORWARDING Session (recommended - no plugin required)
    create_port_forward_cmd = "oci bastion session create-port-forwarding --bastion-id ${module.oci-bastion[0].bastion_service_id} --target-private-ip <PRIVATE_IP> --target-port 22 --ssh-public-key-file ${var.ssh_public_key_path} --session-ttl 3600 --profile ${local.oci_profile}"

    # MANAGED_SSH Session (requires bastion plugin enabled on target instances)
    create_managed_ssh_cmd = "oci bastion session create-managed-ssh --bastion-id ${module.oci-bastion[0].bastion_service_id} --target-resource-id <INSTANCE_OCID> --target-os-username opc --ssh-public-key-file ${var.ssh_public_key_path} --session-ttl 3600 --profile ${local.oci_profile}"

    get_session_ssh_cmd = "oci bastion session get --session-id <SESSION_ID> --query 'data.\"ssh-metadata\".\"command\"' --raw-output --profile ${local.oci_profile}"
    list_nodes_cmd      = "oci compute instance list --compartment-id ${var.compartment_ocid} --lifecycle-state RUNNING --query 'data[].{Name:\"display-name\",OCID:id,\"Private-IP\":\"private-ip\"}' --output json --profile ${local.oci_profile} | jq -r '[.[] | select(.Name | startswith(\"oke-\"))]'"
  } : null
}


# Storage Information
output "storage_bucket_name" {
  description = "Name of the OCI storage bucket"
  value       = module.oci-logscale-storage.bucket_name
}

output "storage_endpoint_base" {
  description = "Storage endpoint URL"
  value       = module.oci-logscale-storage.storage_endpoint_base
}

# Note: The actual certificate value is stored in the Kubernetes secret
# Use kubectl to retrieve it: kubectl get secret <secret_name> -o jsonpath='{.data.ca\.crt}' | base64 -d

# Network Information
output "vcn_id" {
  description = "VCN OCID"
  value       = module.oke.vcn_id
}

output "subnet_ids" {
  description = "Map of subnet OCIDs"
  value = {
    for key, subnet in module.oke.node_pool_subnets :
    key => subnet.id
  }
}

# Resource Summary
output "resource_summary" {
  description = "Summary of resources deployed"
  value = {
    cluster_size    = var.logscale_cluster_size
    cluster_type    = var.logscale_cluster_type
    resource_prefix = local.resource_name_prefix
  }
}

# Essential OCI Commands
output "oci_commands" {
  description = "Essential OCI CLI commands for cluster management"
  value = {
    # OCI Bastion Service management (interactive)
    bastion_service_manager = var.provision_bastion ? "./scripts/setup-bastion-tunnel.sh" : "No bastion provisioned"

    # OCI Bastion Service commands
    list_worker_nodes = "oci compute instance list --compartment-id ${var.compartment_ocid} --lifecycle-state RUNNING --query 'data[].{Name:\"display-name\",OCID:id,\"Private-IP\":\"private-ip\"}' --output json --profile ${local.oci_profile} | jq -r '[.[] | select(.Name | startswith(\"oke-\"))]'"

    # Recommended PORT_FORWARDING approach (no plugin required)
    create_port_forward_session = var.provision_bastion ? "oci bastion session create-port-forwarding --bastion-id ${module.oci-bastion[0].bastion_service_id} --target-private-ip <PRIVATE_IP> --target-port 22 --ssh-public-key-file ${var.ssh_public_key_path} --session-ttl 3600 --profile ${local.oci_profile}" : "No bastion provisioned"

    # Alternative MANAGED_SSH approach (requires bastion plugin)
    create_managed_ssh_session = var.provision_bastion ? "oci bastion session create-managed-ssh --bastion-id ${module.oci-bastion[0].bastion_service_id} --target-resource-id <INSTANCE_OCID> --target-os-username opc --ssh-public-key-file ${var.ssh_public_key_path} --session-ttl 3600 --profile ${local.oci_profile}" : "No bastion provisioned"

    # Legacy name for backward compatibility (use create_managed_ssh_session instead)
    create_bastion_session = var.provision_bastion ? "oci bastion session create-managed-ssh --bastion-id ${module.oci-bastion[0].bastion_service_id} --target-resource-id <INSTANCE_OCID> --target-os-username opc --ssh-public-key-file ${var.ssh_public_key_path} --session-ttl 3600 --profile ${local.oci_profile}" : "No bastion provisioned"

    get_session_ssh_command = var.provision_bastion ? "oci bastion session get --session-id <SESSION_ID> --query 'data.\"ssh-metadata\".\"command\"' --raw-output --profile ${local.oci_profile}" : "No bastion provisioned"

    list_bastion_sessions = var.provision_bastion ? "oci bastion session list --bastion-id ${module.oci-bastion[0].bastion_service_id} --session-lifecycle-state ACTIVE --profile ${local.oci_profile}" : "No bastion provisioned"

    bastion_workflow_example = var.provision_bastion ? "# PORT_FORWARDING (Recommended - no plugin required): | # 1. Get private IP: oci compute instance list --compartment-id ${var.compartment_ocid} --lifecycle-state RUNNING | # 2. Create session: oci bastion session create-port-forwarding --bastion-id ${module.oci-bastion[0].bastion_service_id} --target-private-ip <PRIVATE_IP> --target-port 22 --ssh-public-key-file ${var.ssh_public_key_path} --session-ttl 3600 --profile ${local.oci_profile} | # 3. Get SESSION_ID from output | # 4. Get SSH template: oci bastion session get --session-id <SESSION_ID> --query 'data.\"ssh-metadata\".\"command\"' --raw-output --profile ${local.oci_profile} | # 5. Replace placeholders and run SSH command | # MANAGED_SSH (requires bastion plugin): oci bastion session create-managed-ssh --bastion-id ${module.oci-bastion[0].bastion_service_id} --target-resource-id <OCID> --target-os-username opc --ssh-public-key-file ${var.ssh_public_key_path} --session-ttl 3600 --profile ${local.oci_profile}" : "No bastion provisioned"
  }
}

output "ssh_public_key_path" {
  description = "Path to the SSH public key used for bastion and node access"
  value       = var.ssh_public_key_path
}

output "ssh_private_key_path" {
  description = "Path to the SSH private key used for bastion and node access"
  value       = var.ssh_private_key_path
}

# Storage encryption key for DR standby clusters
# This comes from OCI pre-install module which creates
# the ${cluster_name}-oci-storage-encryption secret that LogScale uses.
output "storage_encryption_key_value" {
  description = "Storage encryption key for DR standby clusters to use via remote state"
  value       = module.pre-install.oci_storage_encryption_key_value
  sensitive   = true
}

output "storage_bucket_namespace" {
  description = "Object Storage namespace for DR standby clusters"
  value       = module.oci-logscale-storage.bucket_namespace
}

# Ingest load balancer IPs (for remote state consumers / DR)
# These are dynamically discovered from the kubernetes nginx ingress service
output "primary_ingest_lb_ip" {
  description = "Primary LogScale ingest load balancer IP (dynamically discovered)"
  value       = var.dr == "active" ? local.local_lb_ip : local.final_primary_ingest_lb_ip
}

output "secondary_ingest_lb_ip" {
  description = "Secondary LogScale ingest load balancer IP (dynamically discovered)"
  value       = var.dr == "standby" ? local.local_lb_ip : local.final_secondary_ingest_lb_ip
}

# Load Balancer OCID outputs - needed for LB backend health monitoring (Option B)
output "primary_ingest_lb_ocid" {
  description = "Primary LogScale ingest load balancer OCID (dynamically discovered for LB health metrics)"
  value       = var.dr == "active" ? local.local_lb_ocid : local.final_primary_lb_ocid
}

output "primary_health_check_id" {
  description = "OCI health check ID for the primary cluster (only set when manage_global_dns=true)."
  value       = var.manage_global_dns ? module.global-dns[0].primary_health_check_id : null
}

output "secondary_health_check_id" {
  description = "OCI health check ID for the secondary cluster (only set when manage_global_dns=true)."
  value       = var.manage_global_dns ? module.global-dns[0].secondary_health_check_id : null
}

output "steering_policy_id" {
  description = "OCI DNS Steering Policy OCID for global LogScale failover (only set when manage_global_dns=true)."
  value       = var.manage_global_dns ? module.global-dns[0].steering_policy_id : null
}

output "steering_policy_attachment_id" {
  description = "OCI DNS Steering Policy Attachment OCID for global LogScale failover (only set when manage_global_dns=true)."
  value       = var.manage_global_dns ? module.global-dns[0].steering_policy_attachment_id : null
}

output "steering_policy_ids_for_dr" {
  description = "Steering policy and attachment OCIDs exported for standby DR automation to consume via remote state."
  value = {
    steering_policy_id            = var.manage_global_dns ? module.global-dns[0].steering_policy_id : null
    steering_policy_attachment_id = var.manage_global_dns ? module.global-dns[0].steering_policy_attachment_id : null
  }
}

output "dns_zone_id" {
  description = "OCI DNS Zone ID for global LogScale DR failover."
  value       = var.manage_global_dns ? module.global-dns[0].dns_zone_id : null
}

output "dns_zone_nameservers" {
  description = "OCI DNS Zone nameservers. Configure these as NS records in Route53 for subdomain delegation."
  value       = var.manage_global_dns ? module.global-dns[0].dns_zone_nameservers : null
}

# DR Failover Function outputs (only available when dr="standby")
output "dr_failover_function_log_group_id" {
  description = "Log group OCID for DR failover function invocation logs (standby cluster only)"
  value       = var.dr == "standby" ? module.dr-failover-function[0].log_group_id : null
}

output "dr_failover_function_log_id" {
  description = "Log OCID for DR failover function invocations (standby cluster only)"
  value       = var.dr == "standby" ? module.dr-failover-function[0].log_id : null
}

output "dr_failover_function_name" {
  description = "Name of the DR failover function (standby cluster only)"
  value       = var.dr == "standby" ? module.dr-failover-function[0].function_name : null
}

output "dr_failover_alarm_id" {
  description = "Monitoring alarm OCID for primary health check failure (standby cluster only)"
  value       = var.dr == "standby" ? module.dr-failover-function[0].alarm_id : null
}

output "dr_failover_primary_health_check_id" {
  description = "Effective PRIMARY health check OCID used by the standby DR alarm/function (standby cluster only)."
  value       = var.dr == "standby" ? module.dr-failover-function[0].primary_health_check_id : null
}

output "dr_failover_topic_id" {
  description = "ONS topic OCID for DR failover notifications (standby cluster only)"
  value       = var.dr == "standby" ? module.dr-failover-function[0].notification_topic_id : null
}

output "dr_failover_function_application_id" {
  description = "Function application OCID for DR failover (standby cluster only)"
  value       = var.dr == "standby" ? module.dr-failover-function[0].function_application_id : null
}

output "dr_monitoring_mode" {
  description = "DR alarm monitoring mode: 'lb_health' or 'health_check' (standby cluster only)"
  value       = var.dr == "standby" ? module.dr-failover-function[0].monitoring_mode : null
}

# Kubeconfig YAML output - uses cluster_name as context for user-friendly naming
# Generate file with: terraform output -raw kubeconfig_yaml > kubeconfig.yaml
output "kubeconfig_yaml" {
  description = "Full kubeconfig YAML content with cluster_name as context. Generate file with: terraform output -raw kubeconfig_yaml > kubeconfig.yaml"
  value       = yamlencode(module.oke.kubeconfig_with_cluster_name)
  sensitive   = true
}

# Kubernetes endpoint for use by providers and external tools
output "kubernetes_endpoint" {
  description = "Kubernetes API server endpoint (public or private based on configuration)"
  value       = "https://${module.oke.cluster_endpoint_details.public_endpoint != null ? module.oke.cluster_endpoint_details.public_endpoint : module.oke.cluster_endpoint_details.private_endpoint}"
}

# LogScale Access
output "logscale_lb_ip" {
  description = "Public IP of the LogScale LoadBalancer Service"
  value       = module.loadbalancer.logscale_lb_ip
}

output "logscale_port_forward_command" {
  description = "kubectl port-forward command for local access to LogScale"
  value       = "kubectl port-forward -n ${var.logscale_namespace} svc/${var.cluster_name}-lb 8080:443"
}

