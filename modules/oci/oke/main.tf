# OKE Cluster Resource
resource "oci_containerengine_cluster" "logscale_cluster" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = var.cluster_name
  vcn_id             = var.vcn_id

  endpoint_config {
    is_public_ip_enabled = var.endpoint_public_access
    subnet_id            = var.cluster_endpoint_subnet_id
    nsg_ids              = var.endpoint_public_access ? [var.api_endpoint_nsg_id] : []
  }

  options {
    service_lb_subnet_ids = [var.lb_subnet_id]

    kubernetes_network_config {
      pods_cidr     = var.pods_cidr
      services_cidr = var.services_cidr
    }

    add_ons {
      is_kubernetes_dashboard_enabled = var.is_kubernetes_dashboard_enabled
      is_tiller_enabled               = var.is_tiller_enabled
    }

    admission_controller_options {
      is_pod_security_policy_enabled = var.enable_pod_security_policy
    }
  }

  cluster_pod_network_options {
    cni_type = var.cni_type
  }

  type = var.cluster_type

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "OKECluster"
    "ClusterName"  = var.cluster_name
  })

  lifecycle {
    prevent_destroy = false
  }
}

# Write local kubeconfig file per cluster
resource "local_sensitive_file" "kubeconfig" {
  content         = yamlencode(local.kubeconfig_with_cluster_name)
  filename        = "${path.root}/kubeconfig-${var.cluster_name}.yaml"
  file_permission = "0600"
}
