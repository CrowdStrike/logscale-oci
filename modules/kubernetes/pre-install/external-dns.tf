# Create OCI config secret for external-dns authentication.
#
# In DR mode (var.dr != ""), global DNS failover is owned by Terraform via
# `modules/oci/global-dns` (steering policy for the global FQDN).
# external-dns is safe to run as long as it does NOT manage the global FQDN.
# We achieve this by using `source=service` and only creating records from
# explicitly annotated Services (for example, the nginx-ingress controller
# Service with a per-cluster hostname like `logscale-primary.<zone>`).
resource "kubernetes_secret" "external_dns_oci_config" {
  count = var.external_dns_enabled ? 1 : 0

  metadata {
    name      = "external-dns-oci-config"
    namespace = "kube-system"
  }

  data = {
    "oci.yaml" = yamlencode({
      auth = {
        region      = var.oci_region
        tenancy     = var.tenancy_ocid
        user        = var.user_ocid
        key         = var.private_key_content
        fingerprint = var.user_fingerprint
      }
      compartment = var.compartment_ocid
    })
  }
}

resource "helm_release" "external_dns" {
  count      = var.external_dns_enabled ? 1 : 0
  name       = "external-dns"
  repository = var.external_dns_repository
  chart      = "external-dns"
  namespace  = "kube-system"
  version    = var.external_dns_chart_version

  depends_on = [kubernetes_secret.external_dns_oci_config]

  set {
    name  = "provider"
    value = "oci"
  }

  set {
    name  = "source"
    value = "service"
  }

  set {
    name  = "rbac.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }

  set {
    name  = "txtOwnerId"
    value = var.cluster_name
  }

  set {
    name  = "extraVolumes[0].name"
    value = "oci-config"
  }

  set {
    name  = "extraVolumes[0].secret.secretName"
    value = "external-dns-oci-config"
  }

  set {
    name  = "extraVolumeMounts[0].name"
    value = "oci-config"
  }

  set {
    name  = "extraVolumeMounts[0].mountPath"
    value = "/etc/kubernetes"
  }

  set {
    name  = "extraVolumeMounts[0].readOnly"
    value = "true"
  }

  dynamic "set" {
    for_each = var.external_dns_domain_filters

    content {
      name  = "domainFilters[${set.key}]"
      value = set.value
    }
  }
}

# NOTE: The cluster CNAME record (cluster_name.dns_zone_name -> logscale_public_fqdn)
# has been moved to the global-dns module to avoid circular dependencies.
# The DNS zone must exist before this record can be created, and the zone is
# created by global-dns which depends on module.logscale.
