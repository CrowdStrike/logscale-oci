variable "tenancy_ocid" {
  description = "The OCID of the tenancy"
  type        = string
}

variable "compartment_ocid" {
  description = "The OCID of the compartment where resources will be created"
  type        = string
}

variable "user_ocid" {
  description = "The OCID of the user"
  type        = string
}

variable "user_fingerprint" {
  description = "The fingerprint for the user's API key"
  type        = string
}

variable "private_key_path" {
  description = "Path to the user's API private key"
  type        = string
}

variable "region" {
  description = "The OCI region"
  type        = string
}

variable "cluster_name" {
  description = "Name of the OKE cluster"
  type        = string

  validation {
    condition     = length(var.cluster_name) >= 1 && length(var.cluster_name) <= 255
    error_message = "The cluster_name must be between 1 and 255 characters."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster"
  type        = string

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.kubernetes_version))
    error_message = "The kubernetes_version must be in the format vX.Y.Z (e.g., v1.28.2)."
  }
}

variable "worker_image_id" {
  description = "The OCID of the image to use for worker nodes"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key file"
  type        = string
}

variable "public_lb_cidrs" {
  description = "List of CIDR blocks allowed to access public load balancer"
  type        = list(string)
}

variable "ad_and_subnets" {
  description = "Map of availability domains and their subnet configurations"
  type = map(object({
    ad          = string
    subnet_cidr = string
    name        = string
  }))
}

# Network inputs from core module
variable "vcn_id" {
  description = "The OCID of the VCN (from core module)"
  type        = string
}

variable "cluster_endpoint_subnet_id" {
  description = "The OCID of the cluster endpoint subnet (from core module)"
  type        = string
}

variable "lb_subnet_id" {
  description = "The OCID of the load balancer subnet (from core module)"
  type        = string
}

variable "pod_subnet_id" {
  description = "The OCID of the pod subnet (from core module)"
  type        = string
}

variable "node_pool_subnets" {
  description = "Map of node pool subnets (from core module)"
  type = map(object({
    id         = string
    cidr_block = string
    ad         = string
  }))
}

variable "worker_nsg_id" {
  description = "The OCID of the worker NSG (from core module)"
  type        = string
}

variable "api_endpoint_nsg_id" {
  description = "The OCID of the API endpoint NSG (from core module)"
  type        = string
}

variable "fault_domains" {
  description = "Fault domains for each availability domain (from core module)"
  type        = map(list(string))
}

variable "node_group_definitions" {
  description = "Node group definitions from cluster size template"
  type        = any
}

variable "logscale_cluster_type" {
  description = "LogScale cluster type (basic, ingress, dedicated-ui, advanced)"
  type        = string
  default     = "basic"
}

variable "resource_name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0))
    error_message = "The vcn_cidr must be a valid CIDR block."
  }
}

variable "pods_cidr" {
  description = "CIDR block for Kubernetes pods"
  type        = string
  default     = "10.0.64.0/18"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "The pods_cidr must be a valid CIDR block."
  }
}

variable "services_cidr" {
  description = "CIDR block for Kubernetes services"
  type        = string
  default     = "10.96.0.0/16"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "The services_cidr must be a valid CIDR block."
  }
}

variable "cluster_endpoint_subnet_cidr" {
  description = "CIDR block for the cluster endpoint subnet"
  type        = string
  default     = "10.0.0.0/28"

  validation {
    condition     = can(cidrhost(var.cluster_endpoint_subnet_cidr, 0))
    error_message = "The cluster_endpoint_subnet_cidr must be a valid CIDR block."
  }
}

variable "lb_subnet_cidr" {
  description = "CIDR block for the load balancer subnet"
  type        = string
  default     = "10.0.1.0/24"

  validation {
    condition     = can(cidrhost(var.lb_subnet_cidr, 0))
    error_message = "The lb_subnet_cidr must be a valid CIDR block."
  }
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "create_iam_resources" {
  description = "Whether to create IAM resources (policies, groups, dynamic groups)"
  type        = bool
  default     = true
}


# Bastion plugin configuration
variable "enable_bastion_plugin" {
  description = "Whether to enable the Bastion plugin on worker nodes for OCI Bastion Service"
  type        = bool
  default     = true
}

variable "create_bastion_sessions" {
  description = "Create managed bastion sessions for all worker nodes"
  type        = bool
  default     = false
}


variable "cluster_type" {
  description = "Type of OKE cluster (BASIC_CLUSTER or ENHANCED_CLUSTER)"
  type        = string
  default     = "BASIC_CLUSTER"

  validation {
    condition     = contains(["BASIC_CLUSTER", "ENHANCED_CLUSTER"], var.cluster_type)
    error_message = "The cluster_type must be either BASIC_CLUSTER or ENHANCED_CLUSTER."
  }
}

variable "cni_type" {
  description = "CNI type for the cluster (OCI_VCN_IP_NATIVE or FLANNEL_OVERLAY)"
  type        = string
  default     = "OCI_VCN_IP_NATIVE"

  validation {
    condition     = contains(["OCI_VCN_IP_NATIVE", "FLANNEL_OVERLAY"], var.cni_type)
    error_message = "The cni_type must be either OCI_VCN_IP_NATIVE or FLANNEL_OVERLAY."
  }
}

variable "is_kubernetes_dashboard_enabled" {
  description = "Enable Kubernetes Dashboard addon"
  type        = bool
  default     = false
}

variable "is_tiller_enabled" {
  description = "Enable Tiller addon (deprecated)"
  type        = bool
  default     = false
}

variable "enable_pod_security_policy" {
  description = "Enable Pod Security Policy"
  type        = bool
  default     = false
}

variable "max_pods_per_node" {
  description = "Maximum number of pods per node (only for FLANNEL_OVERLAY CNI)"
  type        = number
  default     = 31

  validation {
    condition     = var.max_pods_per_node >= 1 && var.max_pods_per_node <= 110
    error_message = "The max_pods_per_node must be between 1 and 110."
  }
}

variable "endpoint_public_access" {
  description = "Enable public access to the Kubernetes API endpoint"
  type        = bool
  default     = false
}

variable "enable_cluster_autoscaler" {
  description = "Enable cluster autoscaler"
  type        = bool
  default     = false
}

variable "mandatory_tags" {
  description = "Mandatory tags that will be applied to all resources"
  type = object({
    Environment = string
    ManagedBy   = string
    Owner       = string
    Project     = string
  })
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
    Owner       = "platform-team"
    Project     = "logscale"
  }
}

variable "oci_profile" {
  description = "OCI CLI profile to use for authentication"
  type        = string
  default     = "DEFAULT"
}

variable "kubernetes_api_host" {
  description = "Override for the Kubernetes API host (e.g., for bastion tunnel). If empty, uses the cluster endpoint."
  type        = string
  default     = ""
}

variable "provision_bastion" {
  description = "Whether a bastion is provisioned for tunnel access"
  type        = bool
  default     = false
}

variable "dr" {
  description = "Disaster Recovery status - 'active' for active cluster, 'standby' for standby cluster, '' (empty) for non-DR mode (treated as active)"
  type        = string
  default     = "active"

  validation {
    condition     = var.dr == "" || contains(["active", "standby"], var.dr)
    error_message = "dr must be either 'active', 'standby', or empty string (non-DR mode)"
  }
}

variable "enable_ingest_dns_steering_policy" {
  description = "Enable OCI DNS Traffic Management FAILOVER steering policy and HTTP health check for the LogScale ingest endpoint"
  type        = bool
  default     = false
}

variable "ingest_dns_zone_id" {
  description = "OCID of the existing OCI DNS zone that will host the LogScale ingest failover record. Required when enable_ingest_dns_steering_policy is true."
  type        = string
  default     = ""
}

variable "ingest_dns_domain_name" {
  description = "Fully qualified domain name (FQDN) for the LogScale ingest endpoint managed by the FAILOVER steering policy (for example, logscale-ingest.example.com)"
  type        = string
  default     = ""
}

variable "primary_ingest_lb_ip" {
  description = "IPv4 address of the primary LogScale ingest load balancer used as the primary target in the FAILOVER steering policy"
  type        = string
  default     = ""
}

variable "secondary_ingest_lb_ip" {
  description = "IPv4 address of the secondary LogScale ingest load balancer used as the secondary target in the FAILOVER steering policy"
  type        = string
  default     = ""
}

variable "ingest_dns_ttl" {
  description = "TTL (seconds) for the LogScale ingest DNS FAILOVER steering policy answers"
  type        = number
  default     = 30
}

variable "ingest_health_check_path" {
  description = "HTTP path used by the OCI Health Checks monitor to validate the primary LogScale ingest load balancer"
  type        = string
  default     = "/health"
}

variable "ingest_health_check_port" {
  description = "TCP port used by the OCI Health Checks HTTP monitor when probing the primary LogScale ingest load balancer"
  type        = number
  default     = 80
}
