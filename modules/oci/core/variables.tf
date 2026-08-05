# Core Network Module Variables

# General OCI Variables
variable "compartment_ocid" {
  description = "The OCID of the compartment where resources will be created"
  type        = string
}

variable "cluster_name" {
  description = "Name of the OKE cluster (used for resource naming)"
  type        = string
}

# VCN Configuration
variable "vcn_cidr" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.1.0.0/16"
}

# Subnet Configuration
variable "cluster_endpoint_subnet_cidr" {
  description = "CIDR block for the cluster endpoint subnet"
  type        = string
  default     = "10.1.1.0/28"
}

variable "lb_subnet_cidr" {
  description = "CIDR block for the load balancer subnet"
  type        = string
  default     = "10.1.2.0/24"
}

variable "pods_cidr" {
  description = "CIDR block for the pods subnet (used with VCN-native pod networking)"
  type        = string
  default     = "10.0.64.0/18"
}

variable "services_cidr" {
  description = "CIDR block for Kubernetes services"
  type        = string
  default     = "10.96.0.0/16"
}

# Availability Domain and Subnet Mapping
variable "ad_and_subnets" {
  description = "Map of availability domains and their corresponding subnet CIDRs"
  type = map(object({
    ad          = string
    subnet_cidr = string
  }))
}

# Endpoint Configuration
variable "endpoint_public_access" {
  description = "Whether the cluster API endpoint should be publicly accessible"
  type        = bool
  default     = false
}

# Bastion Configuration (for security group rules)
variable "provision_bastion" {
  description = "Whether a bastion service is provisioned (affects security rules)"
  type        = bool
  default     = false
}

variable "bastion_client_allow_list" {
  description = "List of CIDR blocks allowed to connect to the bastion service"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Tagging Variables
variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "mandatory_tags" {
  description = "Mandatory tags required by organization policies"
  type        = map(string)
  default     = {}
}

variable "public_lb_cidrs" {
  description = "List of CIDR blocks allowed to access the public load balancer (HTTPS port 443)"
  type        = list(string)
  default     = []
}

variable "control_plane_allowed_cidrs" {
  description = "List of CIDR blocks allowed to access the Kubernetes API endpoint (port 6443). If empty, defaults to VCN CIDR only for security."
  type        = list(string)
  default     = []
}