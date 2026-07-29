# OCI LoadBalancer Module
#
# Creates the OCI LoadBalancer Service and Let's Encrypt Certificate for LogScale.
# This module runs AFTER cert-manager and the OCI DNS webhook are deployed,
# ensuring the ClusterIssuer exists before the Certificate is requested.

# Certificate for the public FQDN - issued by cert-manager via DNS-01 (OCI webhook)
resource "kubernetes_manifest" "logscale_public_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "${var.cluster_name}-public-tls"
      namespace = var.logscale_namespace
    }
    spec = {
      secretName = "${var.cluster_name}-public-tls"
      issuerRef = {
        name = "letsencrypt-cluster-issuer"
        kind = "ClusterIssuer"
      }
      dnsNames = [var.logscale_public_fqdn]
    }
  }
}

resource "kubernetes_service_v1" "logscale_lb" {
  metadata {
    name      = "${var.cluster_name}-lb"
    namespace = var.logscale_namespace
    annotations = {
      # OCI Classic Flexible Load Balancer
      "oci.oraclecloud.com/load-balancer-type"                                     = "lb"
      "service.beta.kubernetes.io/oci-load-balancer-subnet1"                       = var.lb_subnet_id
      "service.beta.kubernetes.io/oci-load-balancer-security-list-management-mode" = "All"
      "oci.oraclecloud.com/oci-network-security-groups"                            = var.lb_nsg_id
      "service.beta.kubernetes.io/oci-load-balancer-shape"                         = "flexible"
      "service.beta.kubernetes.io/oci-load-balancer-shape-flex-min"                = "10"
      "service.beta.kubernetes.io/oci-load-balancer-shape-flex-max"                = "100"

      # Frontend TLS termination - Let's Encrypt cert
      "service.beta.kubernetes.io/oci-load-balancer-ssl-ports"             = "443"
      "service.beta.kubernetes.io/oci-load-balancer-tls-secret"            = "${var.logscale_namespace}/${var.cluster_name}-public-tls"

      # Backend re-encryption - humio-operator auto-generates this CA keypair
      "service.beta.kubernetes.io/oci-load-balancer-tls-backendset-secret" = "${var.logscale_namespace}/${var.cluster_name}-ca-keypair"

      # L7 backend protocol
      "service.beta.kubernetes.io/oci-load-balancer-backend-protocol" = "HTTP"

      # Health check: use HTTP so kube-proxy 200/503 responses are interpreted
      # (TCP only checks connectivity, can't detect pod-level failures)
      "service.beta.kubernetes.io/oci-load-balancer-health-check-protocol" = "HTTP"

      # Only add nodes running LogScale pods as LB backends.
      # With externalTrafficPolicy: Local, nodes without pods always fail HC.
      "oci.oraclecloud.com/node-label-selector" = "oke.oraclecloud.com/pool.name in (logscale-digest,logscale-ingest,logscale-ui)"

      # External DNS
      "external-dns.alpha.kubernetes.io/hostname" = var.logscale_public_fqdn
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Local"
    selector                = { "app.kubernetes.io/name" = "humio" }

    port {
      name        = "https"
      port        = 443
      target_port = 8080
      protocol    = "TCP"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_manifest.logscale_public_cert]
}
