# Local variables for OKE module

locals {
  # Increased timeouts for node registration
  node_pool_timeouts = {
    create = "120m" # Increased from 60m to handle slow initialization
    update = "3h"   # Increased from 2h
    delete = "3h"   # Increased from 2h
  }

  # Alternative instance shapes for capacity issues
  alternative_shapes = {
    "VM.Standard.E5.Flex" = [
      "VM.Standard.E6.Flex",
      "VM.Standard.E4.Flex",
      "VM.Standard3.Flex",
      "VM.Standard.A1.Flex"
    ]
  }

  # Calculate node distribution across ADs
  # This ensures even distribution of nodes across availability domains
  node_distribution = {
    for pool_name, node_count in {
      "logscale_digest"    = try(var.node_group_definitions["logscale_digest_desired_node_count"], 3)
      "logscale_ingest"    = try(var.node_group_definitions["logscale_ingest_desired_node_count"], 0)
      "logscale_ui"        = try(var.node_group_definitions["logscale_ui_desired_node_count"], 0)
      "strimzi_broker"     = try(var.node_group_definitions["strimzi_node_desired_node_count"], 3)
      "strimzi_controller" = try(var.node_group_definitions["strimzi_node_desired_node_count"], 3)
      } : pool_name => {
      total_nodes     = node_count
      nodes_per_ad    = floor(node_count / length(var.ad_and_subnets))
      remaining_nodes = node_count % length(var.ad_and_subnets)
      # Distribute remaining nodes across first ADs
      ad_node_counts = {
        for idx, ad_key in keys(var.ad_and_subnets) : ad_key =>
        floor(node_count / length(var.ad_and_subnets)) + (idx < (node_count % length(var.ad_and_subnets)) ? 1 : 0)
      }
    }
  }
}
