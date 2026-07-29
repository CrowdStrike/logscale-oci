# Core Network Module Outputs

# VCN Outputs
output "vcn_id" {
  description = "The OCID of the VCN"
  value       = oci_core_vcn.main.id
}

output "vcn_cidr" {
  description = "The CIDR block of the VCN"
  value       = var.vcn_cidr
}

# Gateway Outputs
output "internet_gateway_id" {
  description = "The OCID of the Internet Gateway"
  value       = oci_core_internet_gateway.main.id
}

output "nat_gateway_id" {
  description = "The OCID of the NAT Gateway"
  value       = oci_core_nat_gateway.main.id
}

output "service_gateway_id" {
  description = "The OCID of the Service Gateway"
  value       = oci_core_service_gateway.main.id
}

# Route Table Outputs
output "public_route_table_id" {
  description = "The OCID of the public route table"
  value       = oci_core_route_table.public.id
}

output "private_route_table_id" {
  description = "The OCID of the private route table"
  value       = oci_core_route_table.private.id
}

# Security List Outputs
output "public_security_list_id" {
  description = "The OCID of the public security list"
  value       = oci_core_security_list.public.id
}

output "private_security_list_id" {
  description = "The OCID of the private security list"
  value       = oci_core_security_list.private.id
}

# Network Security Group Outputs
output "worker_nsg_id" {
  description = "The OCID of the worker NSG"
  value       = oci_core_network_security_group.worker.id
}

output "api_endpoint_nsg_id" {
  description = "The OCID of the API endpoint NSG"
  value       = oci_core_network_security_group.api_endpoint.id
}

output "bastion_nsg_id" {
  description = "The OCID of the bastion NSG"
  value       = var.provision_bastion ? oci_core_network_security_group.bastion[0].id : null
}

output "lb_nsg_id" {
  description = "The OCID of the public load balancer NSG (for OCI CCM)"
  value       = oci_core_network_security_group.public_lb.id
}

# Subnet Outputs
output "cluster_endpoint_subnet_id" {
  description = "The OCID of the cluster endpoint subnet"
  value       = oci_core_subnet.cluster_endpoint_subnet.id
}

output "lb_subnet_id" {
  description = "The OCID of the load balancer subnet"
  value       = oci_core_subnet.lb_subnet.id
}

output "pod_subnet_id" {
  description = "The OCID of the pod subnet"
  value       = oci_core_subnet.pod_subnet.id
}

output "node_pool_subnets" {
  description = "Map of node pool subnets"
  value = {
    for key, subnet in oci_core_subnet.node_pool_subnet : key => {
      id         = subnet.id
      cidr_block = subnet.cidr_block
      ad         = var.ad_and_subnets[key].ad
    }
  }
}

# Bastion Subnet Output
output "bastion_subnet_id" {
  description = "The OCID of the dedicated bastion subnet"
  value       = var.provision_bastion ? oci_core_subnet.bastion_subnet[0].id : null
}

# Fault Domain Outputs
output "fault_domains" {
  description = "Fault domains for each availability domain"
  value = {
    for k, v in data.oci_identity_fault_domains.fds : k => v.fault_domains[*].name
  }
}

# Network Configuration Summary
output "network_configuration" {
  description = "Complete network configuration details"
  value = {
    vcn = {
      id        = oci_core_vcn.main.id
      cidr      = var.vcn_cidr
      dns_label = oci_core_vcn.main.dns_label
    }
    subnets = {
      cluster_endpoint = {
        id   = oci_core_subnet.cluster_endpoint_subnet.id
        cidr = var.cluster_endpoint_subnet_cidr
      }
      load_balancer = {
        id   = oci_core_subnet.lb_subnet.id
        cidr = var.lb_subnet_cidr
      }
      pods = {
        id   = oci_core_subnet.pod_subnet.id
        cidr = var.pods_cidr
      }
      node_pools = {
        for k, v in oci_core_subnet.node_pool_subnet : k => {
          id   = v.id
          cidr = v.cidr_block
          ad   = var.ad_and_subnets[k].ad
        }
      }
    }
    security_groups = {
      worker_nsg_id       = oci_core_network_security_group.worker.id
      api_endpoint_nsg_id = oci_core_network_security_group.api_endpoint.id
    }
    gateways = {
      internet_gateway_id = oci_core_internet_gateway.main.id
      nat_gateway_id      = oci_core_nat_gateway.main.id
      service_gateway_id  = oci_core_service_gateway.main.id
    }
    route_tables = {
      public_rt_id  = oci_core_route_table.public.id
      private_rt_id = oci_core_route_table.private.id
    }
  }
}

# Service CIDR for OCI services
output "oci_services_cidr" {
  description = "CIDR block for OCI services"
  value       = data.oci_core_services.all_services.services[0].cidr_block
}

# Bastion Enhanced Route Table Output
output "bastion_enhanced_route_table_id" {
  description = "ID of the enhanced route table for bastion with worker node routes"
  value       = var.provision_bastion ? oci_core_route_table.bastion_enhanced[0].id : null
}
