# OCI Pre-Install Module
#
# This module prepares the OKE cluster for LogScale deployment by:
# 1. Creating the LogScale namespace
# 2. (Optionally) deploying external-dns to automatically manage DNS records for the LogScale ingress hostname when enabled
#
# Note: Storage encryption secret is now created by logscale-kubernetes/modules/logscale-prereqs
# which creates ${cluster_name}-storage-encryption secret. The encryption key is passed to
# logscale-prereqs via primary_encryption_key_value variable for DR standby clusters.

resource "kubernetes_namespace_v1" "logscale" {
  metadata {
    name = var.logscale_namespace
  }
}
