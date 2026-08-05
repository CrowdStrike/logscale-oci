# =============================================================================
# Main Resources for cert-manager OCI DNS Webhook
# =============================================================================

# -----------------------------------------------------------------------------
# OCI Credentials Secret
# Stores OCI API credentials for the webhook to authenticate with OCI DNS
# -----------------------------------------------------------------------------
resource "kubernetes_secret" "oci_profile" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = var.profile_secret_name
    namespace = var.namespace
    labels    = local.common_labels
  }

  type = "Opaque"

  # Note: kubernetes_secret.data block automatically base64 encodes values
  # Do NOT use base64encode() here - it causes double encoding
  data = {
    tenancy              = var.tenancy_ocid
    user                 = var.user_ocid
    region               = var.region
    fingerprint          = var.fingerprint
    privateKey           = var.private_key
    privateKeyPassphrase = var.private_key_passphrase
  }
}

# -----------------------------------------------------------------------------
# Service
# Exposes the webhook to cert-manager within the cluster
# -----------------------------------------------------------------------------
resource "kubernetes_service" "webhook" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = var.release_name
    namespace = var.namespace
    labels    = local.common_labels
  }

  spec {
    type = "ClusterIP"

    port {
      port        = 443
      target_port = "https"
      protocol    = "TCP"
      name        = "https"
    }

    selector = {
      "app.kubernetes.io/name"     = var.release_name
      "app.kubernetes.io/instance" = var.release_name
    }
  }
}

# -----------------------------------------------------------------------------
# Deployment
# Runs the webhook server pod
# -----------------------------------------------------------------------------
resource "kubernetes_deployment" "webhook" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = var.release_name
    namespace = var.namespace
    labels    = local.common_labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name"     = var.release_name
        "app.kubernetes.io/instance" = var.release_name
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = var.release_name
          "app.kubernetes.io/instance" = var.release_name
        }
      }

      spec {
        service_account_name = kubernetes_service_account.webhook[0].metadata[0].name

        container {
          name              = "webhook"
          image             = "${var.image_repository}:${var.image_tag}"
          image_pull_policy = var.image_pull_policy

          args = [
            "--tls-cert-file=/tls/tls.crt",
            "--tls-private-key-file=/tls/tls.key"
          ]

          env {
            name  = "GROUP_NAME"
            value = var.group_name
          }

          port {
            name           = "https"
            container_port = 443
            protocol       = "TCP"
          }

          liveness_probe {
            http_get {
              scheme = "HTTPS"
              path   = "/healthz"
              port   = "https"
            }
          }

          readiness_probe {
            http_get {
              scheme = "HTTPS"
              path   = "/healthz"
              port   = "https"
            }
          }

          volume_mount {
            name       = "certs"
            mount_path = "/tls"
            read_only  = true
          }

          resources {
            requests = var.resources != null && var.resources.requests != null ? {
              cpu    = var.resources.requests.cpu
              memory = var.resources.requests.memory
            } : {}
            limits = var.resources != null && var.resources.limits != null ? {
              cpu    = var.resources.limits.cpu
              memory = var.resources.limits.memory
            } : {}
          }
        }

        volume {
          name = "certs"
          secret {
            secret_name = local.serving_certificate_name
          }
        }
      }
    }
  }

  depends_on = [
    data.kubernetes_secret.serving_certificate_secret,
    kubernetes_secret.oci_profile
  ]
}

# -----------------------------------------------------------------------------
# APIService
# Registers the webhook as an aggregated API server with Kubernetes
# -----------------------------------------------------------------------------
resource "kubernetes_api_service" "webhook" {
  count = var.enabled ? 1 : 0

  metadata {
    name   = "v1alpha1.${var.group_name}"
    labels = local.common_labels
    annotations = {
      "cert-manager.io/inject-ca-from" = "${var.namespace}/${local.serving_certificate_name}"
    }
  }

  spec {
    # Explicitly set ca_bundle from the root CA certificate secret to prevent Terraform
    # from removing the value that cert-manager's cainjector injects.
    # Without this, every terraform apply would remove the ca_bundle, breaking
    # the webhook's TLS verification and causing TLS handshake failures.
    #
    # The root CA secret (${release_name}-ca) contains the CA certificate as tls.crt,
    # which is the certificate that signs the webhook's serving certificate.
    ca_bundle = data.kubernetes_secret.root_ca_certificate_secret[0].data["tls.crt"]

    group                  = var.group_name
    version                = "v1alpha1"
    group_priority_minimum = 1000
    version_priority       = 15

    service {
      name      = var.release_name
      namespace = var.namespace
    }
  }

  depends_on = [kubernetes_service.webhook, data.kubernetes_secret.root_ca_certificate_secret, data.kubernetes_secret.serving_certificate_secret]
}

# -----------------------------------------------------------------------------
# ClusterIssuer
# ACME issuer configured to use DNS-01 validation via the OCI webhook
# -----------------------------------------------------------------------------
resource "kubernetes_manifest" "dns01_cluster_issuer" {
  count = var.enabled ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = var.cert_issuer_name
    }
    spec = {
      acme = {
        email = var.cert_issuer_email
        privateKeySecretRef = {
          name = var.cert_issuer_private_key
        }
        server = var.cert_ca_server
        solvers = [
          {
            dns01 = {
              webhook = {
                groupName  = var.group_name
                solverName = var.solver_name
                config = {
                  ociProfileSecretName = var.profile_secret_name
                  compartmentOCID      = var.compartment_ocid
                }
              }
            }
          }
        ]
      }
    }
  }

  timeouts {
    create = "5m"
    update = "5m"
    delete = "5m"
  }

  depends_on = [
    kubernetes_api_service.webhook,
    kubernetes_deployment.webhook
  ]
}
