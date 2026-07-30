# =============================================================================
# RBAC Resources for cert-manager OCI DNS Webhook
# =============================================================================
# Note: common_labels local is defined in locals.tf

# -----------------------------------------------------------------------------
# ServiceAccount for the webhook
# -----------------------------------------------------------------------------
resource "kubernetes_service_account" "webhook" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = var.release_name
    namespace = var.namespace
    labels    = local.common_labels
  }
}

# -----------------------------------------------------------------------------
# RoleBinding to read extension-apiserver-authentication ConfigMap
# This ConfigMap is automatically created by the Kubernetes apiserver
# -----------------------------------------------------------------------------
resource "kubernetes_role_binding" "webhook_auth_reader" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "${var.release_name}:webhook-authentication-reader"
    namespace = "kube-system"
    labels    = local.common_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = "extension-apiserver-authentication-reader"
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.release_name
    namespace = var.namespace
  }
}

# -----------------------------------------------------------------------------
# ClusterRoleBinding for auth-delegator
# Allows the webhook to delegate auth decisions to the core apiserver
# -----------------------------------------------------------------------------
resource "kubernetes_cluster_role_binding" "webhook_auth_delegator" {
  count = var.enabled ? 1 : 0

  metadata {
    name   = "${var.release_name}:auth-delegator"
    labels = local.common_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.release_name
    namespace = var.namespace
  }
}

# -----------------------------------------------------------------------------
# ClusterRole for domain-solver
# Grants cert-manager permission to validate using our webhook apiserver
# -----------------------------------------------------------------------------
resource "kubernetes_cluster_role" "domain_solver" {
  count = var.enabled ? 1 : 0

  metadata {
    name   = "${var.release_name}:domain-solver"
    labels = local.common_labels
  }

  rule {
    api_groups = [var.group_name]
    resources  = ["*"]
    verbs      = ["create"]
  }
}

# -----------------------------------------------------------------------------
# ClusterRoleBinding for domain-solver
# Binds the domain-solver role to cert-manager's ServiceAccount
# -----------------------------------------------------------------------------
resource "kubernetes_cluster_role_binding" "domain_solver" {
  count = var.enabled ? 1 : 0

  metadata {
    name   = "${var.release_name}:domain-solver"
    labels = local.common_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.domain_solver[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.cert_manager_service_account_name
    namespace = var.cert_manager_namespace
  }
}

# -----------------------------------------------------------------------------
# Role for secret-reader
# Allows the webhook to read OCI credential secrets
# -----------------------------------------------------------------------------
resource "kubernetes_role" "secret_reader" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "${var.release_name}:secret-reader"
    namespace = var.namespace
    labels    = local.common_labels
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [var.profile_secret_name]
    verbs          = ["get", "watch"]
  }
}

# -----------------------------------------------------------------------------
# RoleBinding for secret-reader
# Binds the secret-reader role to the webhook's ServiceAccount
# -----------------------------------------------------------------------------
resource "kubernetes_role_binding" "secret_reader" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "${var.release_name}:secret-reader"
    namespace = var.namespace
    labels    = local.common_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.secret_reader[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.release_name
    namespace = var.namespace
  }
}
