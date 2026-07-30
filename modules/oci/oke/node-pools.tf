# Consolidated Node Pools Configuration
# This file dynamically creates node pools based on cluster type

# Local configuration for node pool definitions based on cluster type
locals {
  # Node pool configuration mapping based on cluster type
  node_pool_configs = {
    # Always created node pools
    "system" = {
      enabled           = true
      name              = "system"
      k8s_label         = "system"
      instance_type_key = "system_node_instance_type"
      ocpus_key         = "system_node_ocpus"
      memory_key        = "system_node_memory_in_gbs"
      size_key          = "system_node_desired_node_count"
      root_disk_key     = "system_node_root_disk_size"
    }

    "logscale-digest" = {
      enabled           = true
      name              = "logscale-digest"
      k8s_label         = "logscale-digest"
      instance_type_key = "logscale_digest_instance_type"
      ocpus_key         = "logscale_digest_ocpus"
      memory_key        = "logscale_digest_memory_in_gbs"
      size_key          = "logscale_digest_desired_node_count"
      root_disk_key     = "logscale_digest_root_disk_size"
    }

    "strimzi" = {
      enabled           = var.node_group_definitions["strimzi_node_desired_node_count"] > 0
      name              = "strimzi"
      k8s_label         = "strimzi"
      instance_type_key = "strimzi_node_instance_type"
      ocpus_key         = "strimzi_node_ocpus"
      memory_key        = "strimzi_node_memory_in_gbs"
      size_key          = "strimzi_node_desired_node_count"
      root_disk_key     = "strimzi_node_root_disk_size"
    }

    # Conditionally created node pools based on cluster type and desired count
    # These pools are disabled when dr == "standby"
    "logscale-ui" = {
      enabled           = var.dr != "standby" && contains(["dedicated-ui", "advanced"], var.logscale_cluster_type) && var.node_group_definitions["logscale_ui_desired_node_count"] > 0
      name              = "logscale-ui"
      k8s_label         = "logscale-ui"
      instance_type_key = "logscale_ui_instance_type"
      ocpus_key         = "logscale_ui_ocpus"
      memory_key        = "logscale_ui_memory_in_gbs"
      size_key          = "logscale_ui_desired_node_count"
      root_disk_key     = "logscale_ui_root_disk_size"
    }

    "logscale-ingest" = {
      enabled           = var.dr != "standby" && var.logscale_cluster_type == "advanced" && var.node_group_definitions["logscale_ingest_desired_node_count"] > 0
      name              = "logscale-ingest"
      k8s_label         = "logscale-ingest"
      instance_type_key = "logscale_ingest_instance_type"
      ocpus_key         = "logscale_ingest_ocpus"
      memory_key        = "logscale_ingest_memory_in_gbs"
      size_key          = "logscale_ingest_desired_node_count"
      root_disk_key     = "logscale_ingest_root_disk_size"
    }

    "logscale-ingress" = {
      enabled           = contains(["ingress", "dedicated-ui", "advanced"], var.logscale_cluster_type) && var.node_group_definitions["logscale_ingress_desired_node_count"] > 0
      name              = "logscale-ingress"
      k8s_label         = "logscale-ingress"
      instance_type_key = "logscale_ingress_instance_type"
      ocpus_key         = "logscale_ingress_ocpus"
      memory_key        = "logscale_ingress_memory_in_gbs"
      size_key          = "logscale_ingress_desired_node_count"
      root_disk_key     = "logscale_ingress_root_disk_size"
    }
  }

  # Filter enabled node pools
  enabled_node_pools = {
    for k, v in local.node_pool_configs : k => v if v.enabled
  }
}

# Dynamic node pool creation
resource "oci_containerengine_node_pool" "node_pools" {
  for_each = local.enabled_node_pools

  cluster_id         = oci_containerengine_cluster.logscale_cluster.id
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = each.value.name

  node_shape = var.node_group_definitions[each.value.instance_type_key]

  node_shape_config {
    ocpus         = var.node_group_definitions[each.value.ocpus_key]
    memory_in_gbs = var.node_group_definitions[each.value.memory_key]
  }

  node_config_details {
    # Distribute nodes across availability domains
    dynamic "placement_configs" {
      for_each = var.ad_and_subnets
      content {
        availability_domain = placement_configs.value.ad
        subnet_id           = var.node_pool_subnets[placement_configs.key].id

        # Distribute nodes across all available fault domains in each AD
        fault_domains = var.fault_domains[placement_configs.key]
      }
    }

    # Pod network options to match cluster CNI configuration
    node_pool_pod_network_option_details {
      cni_type       = "OCI_VCN_IP_NATIVE"
      pod_subnet_ids = [var.pod_subnet_id]
    }

    size = var.node_group_definitions[each.value.size_key]

    nsg_ids = [var.worker_nsg_id]

    # Node pool specific configuration
    is_pv_encryption_in_transit_enabled = true


    freeform_tags = merge(var.common_tags, {
      "NodePoolType" = each.value.name
      "Application"  = "LogScale"
    })
  }


  node_source_details {
    image_id                = var.worker_image_id
    source_type             = "IMAGE"
    boot_volume_size_in_gbs = var.node_group_definitions[each.value.root_disk_key]
  }

  # Standard labels
  initial_node_labels {
    key   = "oke.oraclecloud.com/pool.name"
    value = each.value.name
  }

  initial_node_labels {
    key   = "k8s-app"
    value = each.value.k8s_label
  }

  # Additional labels for node affinity
  initial_node_labels {
    key   = "node.kubernetes.io/purpose"
    value = each.value.k8s_label
  }

  ssh_public_key = file(pathexpand(var.ssh_public_key_path))

  # Node eviction details for better pod management
  # Use PT1H format (not PT60M) to match OCI API response and avoid perpetual drift
  node_eviction_node_pool_settings {
    eviction_grace_duration              = "PT1H"
    is_force_delete_after_grace_duration = false
  }

  lifecycle {
    # Prevent accidental deletion
    prevent_destroy = false

    # Freeze image + shape after initial create.
    #
    # Why: OKE worker images are built per shape family (E4/E5/DenseIO2/A1).
    # A single var.worker_image_id is applied to every pool regardless of
    # each pool's shape, so any subsequent apply that would push an
    # incompatible image/shape combination fails at UpdateNodePool with
    # "400-InvalidParameter: Node shape and image are not compatible".
    # Ignoring these attributes keeps existing pools stable across applies.
    #
    # These are only ignored on UPDATE, not CREATE. Green-field applies
    # still use whatever image/shape is configured. Fix the underlying
    # per-shape image discovery separately.
    #
    # To rotate any of these attributes on an existing pool, force a
    # replacement:
    #   terraform apply -replace='module.oke.oci_containerengine_node_pool.node_pools["logscale-digest"]'
    ignore_changes = [
      node_source_details,
      node_shape,
      node_shape_config,
      kubernetes_version,
    ]
  }

  timeouts {
    create = local.node_pool_timeouts.create
    update = local.node_pool_timeouts.update
    delete = local.node_pool_timeouts.delete
  }

  # Dependencies for proper resource creation order
  depends_on = [
    # Subnets are managed by core module
    # Network resources are managed by core module
  ]
}

data "oci_core_instances" "all_worker_nodes" {
  count = var.create_bastion_sessions ? 1 : 0

  compartment_id = var.compartment_ocid

  # Filter by state to get only running instances
  filter {
    name   = "state"
    values = ["RUNNING"]
  }

  # Filter by display name to get only OKE nodes
  filter {
    name   = "display-name"
    values = ["oke-*"]
    regex  = true
  }

  depends_on = [oci_containerengine_node_pool.node_pools]
}

# Create a map of worker nodes for bastion sessions
locals {
  worker_nodes_for_bastion = var.create_bastion_sessions && length(data.oci_core_instances.all_worker_nodes) > 0 ? {
    for instance in data.oci_core_instances.all_worker_nodes[0].instances :
    instance.display_name => {
      instance_ocid = instance.id
      private_ip    = instance.private_ip
    }
  } : {}
}
