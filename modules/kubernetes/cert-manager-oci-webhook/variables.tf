# =============================================================================
# Module Enable/Disable
# =============================================================================

variable "enabled" {
  description = "Enable or disable the webhook deployment"
  type        = bool
  default     = true
}

# =============================================================================
# Namespace and Naming
# =============================================================================

variable "namespace" {
  description = "Kubernetes namespace for webhook deployment"
  type        = string
  default     = "cert-manager"
}

variable "release_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "cert-manager-webhook-oci"
}

variable "labels" {
  description = "Common labels to apply to all resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# OCI Credentials
# =============================================================================

variable "tenancy_ocid" {
  description = "OCI tenancy OCID"
  type        = string
}

variable "user_ocid" {
  description = "OCI user OCID"
  type        = string
}

variable "fingerprint" {
  description = "OCI API key fingerprint"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
}

variable "private_key" {
  description = "OCI API private key content"
  type        = string
  sensitive   = true
}

variable "private_key_passphrase" {
  description = "OCI API private key passphrase (optional)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "compartment_ocid" {
  description = "OCI compartment OCID where DNS zones reside"
  type        = string
}

variable "profile_secret_name" {
  description = "Name of the Kubernetes secret for OCI credentials"
  type        = string
  default     = "oci-dns-credentials"
}

# =============================================================================
# Webhook Configuration
# =============================================================================

variable "group_name" {
  description = "API group name for the webhook (must be unique)"
  type        = string
  default     = "acme.d-n.be"
}

variable "solver_name" {
  description = "DNS solver name"
  type        = string
  default     = "oci"
}

variable "image_repository" {
  description = "Container image repository"
  type        = string
  default     = "registry.gitlab.com/dn13/cert-manager-webhook-oci"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
  default     = "1.4.1"
}

variable "image_pull_policy" {
  description = "Image pull policy"
  type        = string
  default     = "IfNotPresent"
}

variable "replicas" {
  description = "Number of webhook replicas"
  type        = number
  default     = 1
}

variable "resources" {
  description = "Resource requests and limits for webhook container"
  type = object({
    requests = optional(object({
      cpu    = optional(string)
      memory = optional(string)
    }))
    limits = optional(object({
      cpu    = optional(string)
      memory = optional(string)
    }))
  })
  default = null
}

# =============================================================================
# cert-manager Integration
# =============================================================================

variable "cert_manager_namespace" {
  description = "Namespace where cert-manager is installed"
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_service_account_name" {
  description = "cert-manager ServiceAccount name"
  type        = string
  default     = "cert-manager"
}

# =============================================================================
# ClusterIssuer Configuration
# =============================================================================

variable "cert_issuer_name" {
  description = "Name of the ClusterIssuer to create"
  type        = string
  default     = "letsencrypt-cluster-issuer"
}

variable "cert_issuer_email" {
  description = "Email address for ACME registration"
  type        = string
}

variable "cert_issuer_private_key" {
  description = "Secret name for ACME account private key"
  type        = string
  default     = "letsencrypt-cluster-issuer-key"
}

variable "cert_ca_server" {
  description = "ACME server URL"
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

# =============================================================================
# PKI Configuration
# =============================================================================

variable "root_ca_duration" {
  description = "Duration for root CA certificate (e.g., '43800h0m0s' for 5 years)"
  type        = string
  default     = "43800h0m0s"
}

variable "serving_cert_duration" {
  description = "Duration for serving certificate (e.g., '8760h0m0s' for 1 year)"
  type        = string
  default     = "8760h0m0s"
}

# =============================================================================
# kubectl Configuration
# =============================================================================

variable "kubectl_context" {
  description = "kubectl context for local-exec commands (optional)"
  type        = string
  default     = ""
}
