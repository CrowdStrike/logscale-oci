# =============================================================================
# Outputs for cert-manager OCI DNS Webhook
# =============================================================================

output "webhook_service_name" {
  description = "Name of the webhook service"
  value       = var.enabled ? kubernetes_service.webhook[0].metadata[0].name : null
}

output "webhook_namespace" {
  description = "Namespace where the webhook is deployed"
  value       = var.enabled ? var.namespace : null
}

output "cluster_issuer_name" {
  description = "Name of the ClusterIssuer created"
  value       = var.enabled ? var.cert_issuer_name : null
}

output "api_service_name" {
  description = "Name of the APIService registration"
  value       = var.enabled ? "v1alpha1.${var.group_name}" : null
}

output "oci_profile_secret_name" {
  description = "Name of the secret containing OCI credentials"
  value       = var.enabled ? kubernetes_secret.oci_profile[0].metadata[0].name : null
}

output "serving_certificate_name" {
  description = "Name of the serving certificate"
  value       = var.enabled ? local.serving_certificate_name : null
}

output "cluster_issuer_ready" {
  description = "Marker output indicating the ClusterIssuer is ready. Use this as a dependency for resources that need the ClusterIssuer to exist (e.g., Ingress with cert-manager annotation)."
  value       = var.enabled ? kubernetes_manifest.dns01_cluster_issuer[0].manifest.metadata.name : null
}
