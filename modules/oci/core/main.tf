/**
 * ## Module: oci/core
 * This module creates core networking infrastructure for OKE including VCN, subnets, gateways, and security groups.
 */

# VCN Resource
resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_block     = var.vcn_cidr
  display_name   = "${var.cluster_name}-vcn"
  dns_label      = substr(replace("${var.cluster_name}-vcn", "-", ""), 0, 15)

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "VCN"
    "ClusterName"  = var.cluster_name
  })
}

# Internet Gateway
resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-igw"

  freeform_tags = var.common_tags
}

# NAT Gateway
resource "oci_core_nat_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-nat"

  freeform_tags = var.common_tags
}

# Service Gateway for OCI services access
resource "oci_core_service_gateway" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-sgw"

  services {
    service_id = data.oci_core_services.all_services.services[0].id
  }

  freeform_tags = var.common_tags
}

# Data source for OCI services
data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

# Route Tables
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  freeform_tags = var.common_tags
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.main.id
  }

  route_rules {
    destination       = data.oci_core_services.all_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.main.id
  }

  freeform_tags = var.common_tags
}

# Security Lists
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-public-sl"

  # Public subnets are used for the OCI Classic Load Balancer and OCI Bastion Service.
  # - SSH (22) is NOT opened here; OCI Bastion Service controls access via bastion_client_allow_list.
  # - LB ingress is restricted to public_lb_cidrs to match the LB NSG rules.

  dynamic "ingress_security_rules" {
    for_each = toset(var.public_lb_cidrs)
    iterator = cidr
    content {
      protocol    = "6" # TCP
      source      = cidr.value
      description = "Allow HTTP from ${cidr.value}"
      tcp_options {
        min = 80
        max = 80
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = toset(var.public_lb_cidrs)
    iterator = cidr
    content {
      protocol    = "6" # TCP
      source      = cidr.value
      description = "Allow HTTPS from ${cidr.value}"
      tcp_options {
        min = 443
        max = 443
      }
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    description = "Allow all outbound traffic"
  }

  egress_security_rules {
    protocol    = "6" # TCP
    destination = var.vcn_cidr
    description = "Allow SSH to VCN resources"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Allow ICMP egress from bastion to VCN for troubleshooting
  egress_security_rules {
    protocol    = "1" # ICMP
    destination = var.vcn_cidr
    description = "Allow ICMP from bastion to VCN resources"
  }

  freeform_tags = var.common_tags
}

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-private-sl"

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.vcn_cidr
    description = "Allow inbound SSH from VCN"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Note: OCI Bastion Service manages SSH access directly - no explicit subnet rules needed

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.vcn_cidr
    description = "Allow Kubernetes API server"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.vcn_cidr
    description = "Allow kubelet API"
    tcp_options {
      min = 10250
      max = 10250
    }
  }

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.vcn_cidr
    description = "Allow NodePort services"
    tcp_options {
      min = 30000
      max = 32767
    }
  }

  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = var.vcn_cidr
    description = "Allow ICMP for path discovery"
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    protocol    = "all"
    source      = var.vcn_cidr
    description = "Allow all traffic within VCN"
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    description = "Allow all outbound traffic"
  }

  egress_security_rules {
    protocol         = "all"
    destination      = data.oci_core_services.all_services.services[0].cidr_block
    destination_type = "SERVICE_CIDR_BLOCK"
    description      = "Allow traffic to OCI services"
  }

  freeform_tags = var.common_tags
}

# Network Security Groups
resource "oci_core_network_security_group" "worker" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-worker-nsg"

  freeform_tags = var.common_tags
}

resource "oci_core_network_security_group" "api_endpoint" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-api-endpoint-nsg"

  freeform_tags = var.common_tags
}

resource "oci_core_network_security_group" "bastion" {
  count          = var.provision_bastion ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-bastion-nsg"

  freeform_tags = var.common_tags
}

# Note: OCI Bastion Service doesn't require subnet-based security rules
# Access is managed through the bastion service itself

# NSG Security Rules for Workers - VCN internal traffic
resource "oci_core_network_security_group_security_rule" "worker_ingress" {
  for_each = toset(["22", "80", "443", "6443", "10250", "10255"])

  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = var.vcn_cidr
  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

# Data source to find bastion subnet after it's created (should be in public subnet)
data "oci_core_subnets" "bastion_subnet" {
  count          = var.provision_bastion ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id

  filter {
    name   = "route_table_id"
    values = [oci_core_route_table.public.id]
  }

  filter {
    name   = "display_name"
    values = ["*bastion*"]
    regex  = true
  }
}

# Note: OCI Bastion Service manages SSH access directly through the service
# No explicit NSG rules needed for bastion subnet access

# NSG Security Rules for Bastion - Allow SSH egress to worker nodes
resource "oci_core_network_security_group_security_rule" "bastion_egress_ssh" {
  count = var.provision_bastion ? 1 : 0

  network_security_group_id = oci_core_network_security_group.bastion[0].id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = var.vcn_cidr
  description               = "Allow SSH to all VCN resources"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# NSG Security Rules for Bastion - Allow general egress
resource "oci_core_network_security_group_security_rule" "bastion_egress_all" {
  count = var.provision_bastion ? 1 : 0

  network_security_group_id = oci_core_network_security_group.bastion[0].id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  description               = "Allow all outbound traffic"
}

# NSG Security Rules for Bastion - Allow ICMP egress to worker nodes
resource "oci_core_network_security_group_security_rule" "bastion_egress_icmp" {
  count = var.provision_bastion ? 1 : 0

  network_security_group_id = oci_core_network_security_group.bastion[0].id
  direction                 = "EGRESS"
  protocol                  = "1" # ICMP
  destination               = var.vcn_cidr
  description               = "Allow ICMP to all VCN resources"
}

# NSG Security Rules for Worker - Allow ingress from bastion NSG
resource "oci_core_network_security_group_security_rule" "worker_ingress_bastion_nsg" {
  count = var.provision_bastion ? 1 : 0

  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.bastion[0].id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow all traffic from bastion NSG"
}

# NSG Security Rules for Worker - Allow egress to bastion NSG
resource "oci_core_network_security_group_security_rule" "worker_egress_bastion_nsg" {
  count = var.provision_bastion ? 1 : 0

  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = oci_core_network_security_group.bastion[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow all traffic to bastion NSG"
}

resource "oci_core_network_security_group_security_rule" "worker_egress" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
}

# NSG Security Rules for API Endpoint
resource "oci_core_network_security_group_security_rule" "api_endpoint_ingress" {
  # Only attach public ingress rules when the cluster API endpoint is public.
  # control_plane_allowed_cidrs is enforced at the root via validation.tf when endpoint_public_access=true.
  for_each = var.endpoint_public_access ? toset(var.control_plane_allowed_cidrs) : toset([])

  network_security_group_id = oci_core_network_security_group.api_endpoint.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = each.value
  description               = "Allow Kubernetes API (6443) from ${each.value}"
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_ingress_bastion" {
  network_security_group_id = oci_core_network_security_group.api_endpoint.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = var.vcn_cidr
  description               = "Allow Kubernetes API (6443) from within the VCN"
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "api_endpoint_egress" {
  network_security_group_id = oci_core_network_security_group.api_endpoint.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
}

# Subnet for cluster endpoint
# Uses public route table when endpoint_public_access=true and bastion is disabled,
# otherwise uses private route table (bastion provides private access via tunnel)
resource "oci_core_subnet" "cluster_endpoint_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.cluster_endpoint_subnet_cidr
  display_name               = "${var.cluster_name}-cluster-endpoint-subnet"
  dns_label                  = "clusterep"
  prohibit_public_ip_on_vnic = !var.endpoint_public_access
  route_table_id             = var.endpoint_public_access && !var.provision_bastion ? oci_core_route_table.public.id : oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "Subnet"
    "Purpose"      = "ClusterEndpoint"
  })
}

# Subnet for load balancer
resource "oci_core_subnet" "lb_subnet" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = var.lb_subnet_cidr
  display_name      = "${var.cluster_name}-lb-subnet"
  dns_label         = "lbsubnet"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "Subnet"
    "Purpose"      = "LoadBalancer"
  })
}

# Subnet for node pools
resource "oci_core_subnet" "node_pool_subnet" {
  for_each = var.ad_and_subnets

  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = each.value.subnet_cidr
  display_name      = "${var.cluster_name}-node-pool-${each.key}"
  dns_label         = "nodepool${each.key}"
  route_table_id    = oci_core_route_table.private.id
  security_list_ids = [oci_core_security_list.private.id]

  # Keep worker nodes private
  prohibit_public_ip_on_vnic = true

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType"       = "Subnet"
    "Purpose"            = "NodePool"
    "AvailabilityDomain" = each.value.ad
  })
}

# Regional pod subnet for VCN-native pod networking
resource "oci_core_subnet" "pod_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.pods_cidr
  display_name               = "${var.cluster_name}-pod-subnet"
  dns_label                  = "pods"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]

  # Regional subnet (no availability_domain specified)

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "Subnet"
    "Purpose"      = "Pod"
  })
}

# Dedicated bastion subnet for OCI Bastion Service
# This subnet provides connectivity to all worker node subnets via VCN routing
resource "oci_core_subnet" "bastion_subnet" {
  count = var.provision_bastion ? 1 : 0

  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = cidrsubnet(var.vcn_cidr, 8, 250) # Create dedicated /24 subnet for bastion
  display_name      = "${var.cluster_name}-bastion-subnet"
  dns_label         = "bastion"
  route_table_id    = oci_core_route_table.bastion_enhanced[0].id
  security_list_ids = [oci_core_security_list.public.id]

  # Bastion subnet should be public for OCI Bastion Service access
  prohibit_public_ip_on_vnic = false

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "Subnet"
    "Purpose"      = "Bastion"
    "Service"      = "OCI-Bastion-Service"
  })
}

# Data source for fault domains in each availability domain
data "oci_identity_fault_domains" "fds" {
  for_each = var.ad_and_subnets

  availability_domain = each.value.ad
  compartment_id      = var.compartment_ocid
}

# Additional security rules for OKE node registration

# Allow OKE control plane to reach worker nodes on kubelet port
resource "oci_core_network_security_group_security_rule" "worker_ingress_oke_control_plane" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "SERVICE_CIDR_BLOCK"
  source                    = data.oci_core_services.all_services.services[0].cidr_block
  description               = "Allow OKE control plane to reach worker nodes kubelet"
  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

# Allow OKE control plane to reach worker nodes on additional ports
resource "oci_core_network_security_group_security_rule" "worker_ingress_oke_control_plane_extended" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "SERVICE_CIDR_BLOCK"
  source                    = data.oci_core_services.all_services.services[0].cidr_block
  description               = "Allow OKE control plane extended port access"
  tcp_options {
    destination_port_range {
      min = 10255
      max = 10255
    }
  }
}

# Allow worker nodes to reach OKE control plane via Service Gateway
resource "oci_core_network_security_group_security_rule" "worker_egress_oke_service" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination_type          = "SERVICE_CIDR_BLOCK"
  destination               = data.oci_core_services.all_services.services[0].cidr_block
  description               = "Allow worker nodes to reach OKE services"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# Allow worker nodes to reach OKE control plane API
resource "oci_core_network_security_group_security_rule" "worker_egress_oke_api" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = "0.0.0.0/0"
  description               = "Allow worker nodes to reach OKE API endpoints"
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

# Allow worker nodes to reach package repositories
resource "oci_core_network_security_group_security_rule" "worker_egress_package_repos" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = "0.0.0.0/0"
  description               = "Allow worker nodes to reach package repositories"
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

# Allow ICMP for path discovery from OKE control plane
resource "oci_core_network_security_group_security_rule" "worker_ingress_icmp_oke" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source_type               = "SERVICE_CIDR_BLOCK"
  source                    = data.oci_core_services.all_services.services[0].cidr_block
  description               = "Allow ICMP from OKE control plane"
  icmp_options {
    type = 3
    code = 4
  }
}

# Allow ICMP for general path discovery
resource "oci_core_network_security_group_security_rule" "worker_ingress_icmp_general" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source                    = var.vcn_cidr
  description               = "Allow ICMP within VCN for path discovery"
  icmp_options {
    type = 3
    code = 4
  }
}

# Note: OCI Bastion Service manages ICMP ping through the managed service

# Note: OCI Bastion Service doesn't require ICMP rules for bastion subnet

# Note: OCI Bastion Service handles ICMP traffic through the managed service

# Additional security rule for worker-to-worker communication
resource "oci_core_network_security_group_security_rule" "worker_ingress_internal" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.worker.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow all traffic between worker nodes"
}

# Allow DNS resolution
resource "oci_core_network_security_group_security_rule" "worker_egress_dns" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "EGRESS"
  protocol                  = "17" # UDP
  destination               = "0.0.0.0/0"
  description               = "Allow DNS resolution"
  udp_options {
    destination_port_range {
      min = 53
      max = 53
    }
  }
}

# Allow worker nodes to reach OKE installation services
resource "oci_core_network_security_group_security_rule" "worker_egress_oke_installation" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination_type          = "SERVICE_CIDR_BLOCK"
  destination               = data.oci_core_services.all_services.services[0].cidr_block
  description               = "Allow worker nodes to reach OKE installation services"
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

# Allow worker nodes to reach OKE installation services over HTTPS
resource "oci_core_network_security_group_security_rule" "worker_egress_oke_installation_https" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination_type          = "SERVICE_CIDR_BLOCK"
  destination               = data.oci_core_services.all_services.services[0].cidr_block
  description               = "Allow worker nodes to reach OKE installation services over HTTPS"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# Allow OKE control plane to initiate installation on worker nodes
resource "oci_core_network_security_group_security_rule" "worker_ingress_oke_installation" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "SERVICE_CIDR_BLOCK"
  source                    = data.oci_core_services.all_services.services[0].cidr_block
  description               = "Allow OKE control plane to initiate installation on worker nodes"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# Allow NTP for time synchronization
resource "oci_core_network_security_group_security_rule" "worker_egress_ntp" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "EGRESS"
  protocol                  = "17" # UDP
  destination               = "0.0.0.0/0"
  description               = "Allow NTP for time synchronization"
  udp_options {
    destination_port_range {
      min = 123
      max = 123
    }
  }
}

# Enhanced route table for bastion with worker node routes
resource "oci_core_route_table" "bastion_enhanced" {
  count          = var.provision_bastion ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-bastion-enhanced-rt"

  # Default route to Internet Gateway
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
    description       = "Default route to Internet Gateway"
  }

  # Note: Intra-VCN routes are handled automatically by OCI's Local Gateway
  # No explicit route rules needed for communication within the same VCN
  # The bastion can reach worker nodes through the VCN's implicit routing

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "Purpose" = "Bastion-Enhanced-Routing"
  })
}

# =============================================================================
# Public Load Balancer NSG
# =============================================================================

# Network Security Group for public load balancers (nginx-ingress)
resource "oci_core_network_security_group" "public_lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.cluster_name}-public-lb-nsg"

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "NSG"
    "Purpose"      = "PublicLoadBalancer"
  })
}

# Allow HTTPS ingress from public_lb_cidrs
resource "oci_core_network_security_group_security_rule" "public_lb_ingress_https" {
  for_each = toset(var.public_lb_cidrs)

  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = each.value
  description               = "Allow HTTPS from ${each.value}"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# Allow HTTP ingress from public_lb_cidrs (for redirects)
resource "oci_core_network_security_group_security_rule" "public_lb_ingress_http" {
  for_each = toset(var.public_lb_cidrs)

  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = each.value
  description               = "Allow HTTP from ${each.value}"
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

# Allow egress to worker nodes on NodePort range
resource "oci_core_network_security_group_security_rule" "public_lb_egress_nodeport" {
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = oci_core_network_security_group.worker.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow egress to worker nodes on NodePort range"
  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

# Allow egress to worker nodes for health checks
resource "oci_core_network_security_group_security_rule" "public_lb_egress_health" {
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = oci_core_network_security_group.worker.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow health check to worker nodes"
  tcp_options {
    destination_port_range {
      min = 10256
      max = 10256
    }
  }
}

# Allow ICMP for path MTU discovery
resource "oci_core_network_security_group_security_rule" "public_lb_egress_icmp" {
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                 = "EGRESS"
  protocol                  = "1" # ICMP
  destination               = oci_core_network_security_group.worker.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow ICMP for path MTU discovery"
}

# Worker NSG ingress rules from LB NSG
resource "oci_core_network_security_group_security_rule" "worker_ingress_lb_nodeport" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = oci_core_network_security_group.public_lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow NodePort traffic from public LB NSG"
  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "worker_ingress_lb_health" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = oci_core_network_security_group.public_lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow health check from public LB NSG"
  tcp_options {
    destination_port_range {
      min = 10256
      max = 10256
    }
  }
}

resource "oci_core_network_security_group_security_rule" "worker_ingress_lb_icmp" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source                    = oci_core_network_security_group.public_lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow ICMP Type 3 Code 4 (PMTUD) from public LB NSG"
}

# Allow UDP NodePort traffic from LB NSG (for UDP services)
resource "oci_core_network_security_group_security_rule" "worker_ingress_lb_nodeport_udp" {
  network_security_group_id = oci_core_network_security_group.worker.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = oci_core_network_security_group.public_lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow UDP NodePort traffic from public LB NSG"
}
