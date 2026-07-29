# OCI Storage Encryption Secret
# Following the same pattern as AWS and GCP cloud providers:
# - AWS: ${cluster_name}-s3-storage-encryption with key s3-storage-encryption-key
# - GCP: ${cluster_name}-gcp-storage-encryption-key with key gcp-storage-encryption-key
# - OCI: ${cluster_name}-oci-storage-encryption with key oci-storage-encryption-key

# Generate encryption key for primary/active clusters
# For standby clusters, the key is passed from primary via existing_storage_encryption_key
resource "random_password" "oci_storage_encryption_password" {
  count   = var.existing_storage_encryption_key == null ? 1 : 0
  length  = 64
  special = false
}

locals {
  # Use primary's key if provided (standby), otherwise use generated key (active/primary)
  effective_oci_encryption_key = var.existing_storage_encryption_key != null ? var.existing_storage_encryption_key : random_password.oci_storage_encryption_password[0].result
}

# Create the OCI-specific storage encryption secret
resource "kubernetes_secret" "oci_storage_encryption_key" {
  metadata {
    name      = "${var.cluster_name}-oci-storage-encryption"
    namespace = var.logscale_namespace
  }
  data = {
    oci-storage-encryption-key = local.effective_oci_encryption_key
  }

  depends_on = [kubernetes_namespace_v1.logscale]
}
