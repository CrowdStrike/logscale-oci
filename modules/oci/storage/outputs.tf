output "bucket_name" {
  description = "Name of the LogScale data storage bucket"
  value       = oci_objectstorage_bucket.logscale_data.name
}

output "bucket_namespace" {
  description = "Object Storage namespace for the LogScale bucket"
  value       = data.oci_objectstorage_namespace.logscale_namespace.namespace
}

output "storage_endpoint_base" {
  description = "S3-compatible endpoint URL for Object Storage"
  value       = "https://${data.oci_objectstorage_namespace.logscale_namespace.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "bucket_url" {
  description = "URL to access the LogScale data bucket"
  value       = "https://objectstorage.${var.region}.oraclecloud.com/n/${data.oci_objectstorage_namespace.logscale_namespace.namespace}/b/${oci_objectstorage_bucket.logscale_data.name}"
}

output "par_access_uri" {
  description = "Pre-authenticated request URI for LogScale bucket access"
  value       = oci_objectstorage_preauthrequest.logscale_par.access_uri
  sensitive   = true
}

output "s3_access_key_id" {
  description = "S3-compatible access key ID for LogScale"
  value       = oci_identity_customer_secret_key.logscale_s3_credentials.id
  sensitive   = true
}

output "s3_secret_access_key" {
  description = "S3-compatible secret access key for LogScale"
  value       = oci_identity_customer_secret_key.logscale_s3_credentials.key
  sensitive   = true
}

output "topo_lvm_disk_pattern" {
  description = "Device glob pattern used by the TopoLVM lvm-setup DaemonSet to discover NVMe or local SSD disks on OKE worker nodes"
  value       = local.topo_lvm_disk_pattern
}

output "lvm_setup_extra_volume_mounts" {
  description = "Provider-specific extra volumeMounts for the lvm-setup DaemonSet container on OKE"
  value       = local.lvm_setup_extra_volume_mounts
}

output "lvm_setup_extra_volumes" {
  description = "Provider-specific extra volumes for the lvm-setup DaemonSet pod on OKE"
  value       = local.lvm_setup_extra_volumes
}
