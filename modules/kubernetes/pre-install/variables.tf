variable "cluster_name" {
  description = "The name of the OKE cluster"
  type        = string
}

variable "logscale_namespace" {
  description = "The kubernetes namespace used by logscale resources"
  type        = string
}

variable "external_dns_enabled" {
  description = "Whether to deploy external-dns for automatic DNS record management"
  type        = bool
  default     = false
}

variable "external_dns_chart_version" {
  description = "Helm chart version for the external-dns Helm chart"
  type        = string
  default     = "1.14.5"
}

variable "external_dns_repository" {
  description = "Helm repository URL for the external-dns Helm chart"
  type        = string
  default     = "https://kubernetes-sigs.github.io/external-dns/"
}

variable "external_dns_domain_filters" {
  description = "Optional list of domain filters for external-dns (for example, \"mi-arch-oci-logscale.example.com\"). When empty, all accessible OCI DNS zones are considered."
  type        = list(string)
  default     = []
}

variable "dns_zone_name" {
  description = "Base DNS zone name in OCI DNS (for example, oci-ref-arch.com) used when creating cluster-level A records."
  type        = string
  default     = ""
}

variable "logscale_public_fqdn" {
  description = "Public FQDN for the LogScale cluster (used by LogScale deployment and external DNS tooling)."
  type        = string
}

variable "storage_bucket_name" {
  description = "OCI Object Storage bucket name for LogScale"
  type        = string
}

variable "storage_bucket_namespace" {
  description = "OCI Object Storage namespace"
  type        = string
}

variable "existing_storage_encryption_key" {
  description = "Existing OCI storage encryption key from primary cluster (for DR standby clusters). When null, a new key is generated."
  type        = string
  default     = null
  sensitive   = true
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

variable "oci_region" {
  description = "OCI region for external-dns authentication"
  type        = string
  default     = ""
}

variable "tenancy_ocid" {
  description = "OCI tenancy OCID for external-dns authentication"
  type        = string
  default     = ""
}

variable "user_ocid" {
  description = "OCI user OCID for external-dns authentication"
  type        = string
  default     = ""
}

variable "user_fingerprint" {
  description = "OCI user API key fingerprint for external-dns authentication"
  type        = string
  default     = ""
}

variable "private_key_content" {
  description = "OCI private key content for external-dns authentication"
  type        = string
  sensitive   = true
  default     = ""
}

variable "compartment_ocid" {
  description = "OCI compartment OCID for external-dns"
  type        = string
  default     = ""
}


