# =============================================================================
# Local Values for cert-manager OCI DNS Webhook
# =============================================================================

locals {
  # Common labels applied to all Kubernetes resources
  common_labels = merge(
    {
      "app.kubernetes.io/name"       = var.release_name
      "app.kubernetes.io/instance"   = var.release_name
      "app.kubernetes.io/managed-by" = "terraform"
    },
    var.labels
  )

  # Certificate and issuer names for PKI resources
  self_signed_issuer_name  = "${var.release_name}-selfsign"
  root_ca_certificate_name = "${var.release_name}-ca"
  ca_issuer_name           = "${var.release_name}-ca"
  serving_certificate_name = "${var.release_name}-webhook-tls"

  # Filter out null/empty resource values to avoid invalid maps
  container_resource_requests = var.resources != null && var.resources.requests != null ? {
    for k, v in var.resources.requests : k => v if v != null && trimspace(v) != ""
  } : {}
  container_resource_limits = var.resources != null && var.resources.limits != null ? {
    for k, v in var.resources.limits : k => v if v != null && trimspace(v) != ""
  } : {}
}
