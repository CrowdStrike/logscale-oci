output "logscale_namespace" {
  description = "The kubernetes namespace used by logscale resources"
  value       = kubernetes_namespace_v1.logscale
}

# OCI Storage Encryption Key outputs
output "oci_storage_encryption_key_secret_name" {
  description = "Name of the Kubernetes secret containing OCI storage encryption key"
  value       = kubernetes_secret.oci_storage_encryption_key.metadata[0].name
}

output "oci_storage_encryption_key_secret_key" {
  description = "Key within the Kubernetes secret containing the OCI storage encryption key"
  value       = "oci-storage-encryption-key"
}

output "oci_storage_encryption_key_value" {
  description = "OCI storage encryption key value (for remote state access by DR standby clusters)"
  value       = local.effective_oci_encryption_key
  sensitive   = true
}


