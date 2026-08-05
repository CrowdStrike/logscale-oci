# Use data source to get existing cluster to avoid circular dependency
# This prevents the provider from depending on module outputs
# Filter by compartment, name, state, AND VCN to disambiguate multiple clusters with same name
data "oci_containerengine_clusters" "existing" {
  compartment_id = var.compartment_ocid
  name           = var.cluster_name
  state          = ["ACTIVE"]
}

# Get the cluster details to match by VCN
data "oci_containerengine_cluster" "existing" {
  count      = length(data.oci_containerengine_clusters.existing.clusters)
  cluster_id = data.oci_containerengine_clusters.existing.clusters[count.index].id
}

# Configure the OCI Provider with API Key Authentication for regular resources
provider "oci" {
  auth             = "ApiKey"
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.user_fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

provider "oci" {
  alias            = "home"
  auth             = "ApiKey"
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.user_fingerprint
  private_key_path = var.private_key_path
  region           = var.home_region
}

# Determine if we should use public endpoint directly (no bastion tunnel needed)
# Override: if kubernetes_api_host is explicitly set (not default), use it even with public endpoint enabled
# This allows using a bastion tunnel even when provision_bastion=false
locals {
  kubernetes_api_host_override = var.kubernetes_api_host != "https://127.0.0.1:6443"
  use_public_endpoint          = var.endpoint_public_access && !var.provision_bastion && !local.kubernetes_api_host_override
}

# Data source to get the kubeconfig
# When public endpoint is enabled and bastion is disabled, request PUBLIC_ENDPOINT kubeconfig
data "oci_containerengine_cluster_kube_config" "oke" {
  cluster_id    = local.cluster_id
  token_version = "2.0.0"
  endpoint      = local.use_public_endpoint ? "PUBLIC_ENDPOINT" : null
}

locals {
  kubeconfig = yamldecode(data.oci_containerengine_cluster_kube_config.oke.content)
  # When using public endpoint directly, get host from kubeconfig
  # When using bastion tunnel, use the kubernetes_api_host variable
  kubernetes_host = local.use_public_endpoint ? local.kubeconfig.clusters[0].cluster.server : trimspace(var.kubernetes_api_host)

  # Context name for the logscale module - uses cluster_name for consistent naming
  oci_kubeconfig_context = var.cluster_name
}

# Kubernetes provider using kubeconfig file with API key authentication
provider "kubernetes" {
  host                   = local.kubernetes_host
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
  exec {
    api_version = local.kubeconfig.users[0].user.exec.apiVersion
    command     = local.kubeconfig.users[0].user.exec.command
    args        = concat(["--profile", local.oci_profile, "--auth", "api_key"], local.kubeconfig.users[0].user.exec.args)
  }
}

# Helm provider using kubeconfig file with API key authentication
provider "helm" {
  kubernetes {
    host                   = local.kubernetes_host
    cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
    exec {
      api_version = local.kubeconfig.users[0].user.exec.apiVersion
      command     = local.kubeconfig.users[0].user.exec.command
      args        = concat(["--profile", local.oci_profile, "--auth", "api_key"], local.kubeconfig.users[0].user.exec.args)
    }
  }
}
