# Bastion Module Variables

# General OCI Variables
variable "tenancy_ocid" {
  description = "The OCID of the tenancy"
  type        = string
}

variable "compartment_ocid" {
  description = "The OCID of the compartment where resources will be created"
  type        = string
}

variable "resource_name_prefix" {
  description = "Resource name prefix for naming resources"
  type        = string
}

# Network Variables
variable "vcn_id" {
  description = "The OCID of the VCN where the bastion will be created"
  type        = string
}

variable "target_subnet_id" {
  description = "The OCID of the dedicated bastion subnet that can reach all worker node subnets"
  type        = string
}

variable "node_pool_subnets" {
  description = "Map of all node pool subnets for enhanced bastion connectivity"
  type = map(object({
    id         = string
    cidr_block = string
    ad         = string
  }))
  default = {}
}

# Bastion Service Configuration Variables
variable "provision_bastion" {
  description = "Whether to provision the OCI Bastion Service"
  type        = bool
  default     = false
}

variable "bastion_client_allow_list" {
  description = "List of CIDR blocks allowed to connect to the bastion service"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "max_session_ttl" {
  description = "Maximum session TTL in seconds (1800 to 10800 seconds, i.e., 30 minutes to 3 hours)"
  type        = number
  default     = 10800
}

variable "enable_dns_proxy" {
  description = "Whether to enable DNS proxy for the bastion service"
  type        = bool
  default     = false
}

# SSH Key Configuration (for creating bastion sessions)
variable "ssh_public_key_path" {
  description = "Path to the SSH public key file (used when creating bastion sessions)"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
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

variable "defined_tags" {
  description = "Defined tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "Name of the OKE cluster (used for tagging)"
  type        = string
}