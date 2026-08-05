/**
 * ## Module: oci/storage
 * This module creates OCI Object Storage resources for LogScale data persistence.
 */

locals {
  # Common tags for all storage resources
  common_tags = {
    "Environment" = terraform.workspace
    "ManagedBy"   = "Terraform"
    "Application" = "LogScale"
  }

  # Storage bucket naming
  bucket_name = "${var.resource_name_prefix}-logscale-data"

  # OKE-specific TopoLVM / NVMe configuration
  # Exposed here so that worker-node storage behaviour can be aligned with
  # other clouds without embedding provider-specific logic in the shared
  # logscale-kubernetes module.
  topo_lvm_disk_pattern = "nvme*n*"

  lvm_setup_extra_volume_mounts = [
    {
      name       = "dev"
      mount_path = "/dev"
      read_only  = false
    },
    {
      name       = "run-lock-lvm"
      mount_path = "/run/lock/lvm"
      read_only  = false
    },
    {
      name       = "etc-lvm"
      mount_path = "/etc/lvm"
      read_only  = false
    },
  ]

  lvm_setup_extra_volumes = [
    {
      name      = "dev"
      host_path = "/dev"
    },
    {
      name      = "run-lock-lvm"
      host_path = "/run/lock/lvm"
    },
    {
      name      = "etc-lvm"
      host_path = "/etc/lvm"
    },
  ]
}

# Create Object Storage namespace (if not using default)
data "oci_objectstorage_namespace" "logscale_namespace" {
  compartment_id = var.compartment_ocid
}

# Object Storage bucket for LogScale data
resource "oci_objectstorage_bucket" "logscale_data" {
  compartment_id = var.compartment_ocid
  name           = local.bucket_name
  namespace      = data.oci_objectstorage_namespace.logscale_namespace.namespace

  access_type           = "NoPublicAccess"
  object_events_enabled = false
  versioning            = "Disabled"
  auto_tiering          = "InfrequentAccess"

  # Storage tier management
  retention_rules {
    display_name = "LogScale-Retention"

    duration {
      time_amount = var.data_retention_days
      time_unit   = "DAYS"
    }
  }

  freeform_tags = merge(local.common_tags, {
    "StorageType" = "LogScaleData"
  })

  lifecycle {
    ignore_changes = [
      freeform_tags,
      retention_rules,
      namespace
    ]
  }
}

# Destroy-time cleanup: removes retention rules and objects so the bucket can be deleted
resource "null_resource" "bucket_cleanup" {
  triggers = {
    bucket_name = oci_objectstorage_bucket.logscale_data.name
    namespace   = data.oci_objectstorage_namespace.logscale_namespace.namespace
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      #!/bin/bash
      set -e
      BUCKET="${self.triggers.bucket_name}"
      NAMESPACE="${self.triggers.namespace}"

      echo "=== Cleaning bucket '$BUCKET' for destruction ==="

      # 1. Delete all retention rules
      echo "Listing retention rules..."
      RULES=$(oci os retention-rule list \
        --bucket-name "$BUCKET" \
        --namespace-name "$NAMESPACE" \
        --all 2>/dev/null || echo '{"data":{"items":[]}}')

      RULE_IDS=$(echo "$RULES" | jq -r '.data.items[]?.id // empty')

      if [ -n "$RULE_IDS" ]; then
        for RULE_ID in $RULE_IDS; do
          echo "  Deleting retention rule: $RULE_ID"
          oci os retention-rule delete \
            --bucket-name "$BUCKET" \
            --namespace-name "$NAMESPACE" \
            --retention-rule-id "$RULE_ID" \
            --force 2>/dev/null || true
        done
        echo "  Waiting 15s for retention rule deletion to propagate..."
        sleep 15
      else
        echo "  No retention rules found."
      fi

      # 2. Bulk-delete all objects
      echo "Bulk-deleting all objects..."
      oci os object bulk-delete \
        --bucket-name "$BUCKET" \
        --namespace-name "$NAMESPACE" \
        --force 2>/dev/null || true

      echo "=== Bucket cleanup complete ==="
    EOT
  }

  depends_on = [oci_objectstorage_bucket.logscale_data]
}

# Pre-authenticated request for LogScale access (optional backup method)
resource "oci_objectstorage_preauthrequest" "logscale_par" {
  namespace    = data.oci_objectstorage_namespace.logscale_namespace.namespace
  bucket       = oci_objectstorage_bucket.logscale_data.name
  name         = "${var.resource_name_prefix}-logscale-par"
  access_type  = "AnyObjectReadWrite"
  time_expires = var.par_expiration_time

  lifecycle {
    ignore_changes = [
      time_expires
    ]
  }
}

# OCI Customer Secret Key for S3-compatible API access
# This creates the AWS-compatible credentials that LogScale needs
# Must be created in the home region
resource "oci_identity_customer_secret_key" "logscale_s3_credentials" {
  provider     = oci.home
  user_id      = var.user_ocid
  display_name = "${var.resource_name_prefix}-logscale-s3-key"

  lifecycle {
    create_before_destroy = true
  }
}

# Object lifecycle policy for cost optimization
# Temporarily commented out due to insufficient service permissions
# resource "oci_objectstorage_object_lifecycle_policy" "logscale_lifecycle" {
#   namespace = data.oci_objectstorage_namespace.logscale_namespace.namespace
#   bucket    = oci_objectstorage_bucket.logscale_data.name
#
#   rules {
#     name               = "LogScale-Archive-Rule"
#     action             = "ARCHIVE"
#     is_enabled         = true
#     object_name_filter {
#       inclusion_patterns = ["logs/*"]
#     }
#
#     time_amount = var.archive_after_days
#     time_unit   = "DAYS"
#     target      = "objects"
#   }
#
#   rules {
#     name               = "LogScale-Delete-Rule"
#     action             = "DELETE"
#     is_enabled         = true
#     object_name_filter {
#       inclusion_patterns = ["temp/*", "cache/*"]
#     }
#
#     time_amount = var.temp_data_retention_days
#     time_unit   = "DAYS"
#     target      = "objects"
#   }
#
#   # depends_on = [oci_identity_policy.object_storage_lifecycle_policy]
# }
