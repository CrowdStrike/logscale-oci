locals {
  primary_ingest_fqdn = (
    var.primary_logscale_hostname != "" ?
    "${var.primary_logscale_hostname}.${var.zone_name}" :
    null
  )

  secondary_ingest_fqdn = (
    var.secondary_logscale_hostname != "" ?
    "${var.secondary_logscale_hostname}.${var.zone_name}" :
    null
  )

  global_ingest_fqdn = (
    var.global_logscale_hostname != "" ?
    "${var.global_logscale_hostname}.${var.zone_name}" :
    null
  )

  # Use created zone ID if creating, otherwise use provided zone ID
  effective_zone_id = var.create_dns_zone ? oci_dns_zone.global_dns[0].id : var.zone_id
}

# create oke cluster


# Create DNS zone for global DR failover (optional - only when create_dns_zone=true)
resource "oci_dns_zone" "global_dns" {
  count = var.create_dns_zone ? 1 : 0

  compartment_id = var.compartment_ocid
  name           = var.zone_name
  zone_type      = "PRIMARY"
  scope          = "GLOBAL"

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "DnsZone"
    "Component"    = "LogScaleGlobalDNS"
  })
}

# Health check monitor for LogScale ingest endpoints (primary and secondary)
# OCI steering policies only support ONE health check monitor, so we include
# both IPs as targets. The HEALTH rule marks answers healthy/unhealthy based
# on whether their rdata matches a healthy target in this monitor.
#
# NOTE: This resource is only created when use_external_health_check=true.
# When false, the steering policy relies on is_disabled flag controlled by
# the DR failover function, which monitors LB backend health internally.
resource "oci_health_checks_http_monitor" "logscale_global_primary" {
  count          = var.manage_global_dns && var.use_external_health_check ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${local.global_ingest_fqdn}-https-monitor"

  protocol = "HTTPS"
  # Include both primary and secondary IPs so the steering policy HEALTH rule
  # can evaluate both answers. Without secondary in targets, it would be
  # considered "healthy by default" but may cause UI confusion.
  targets = compact([
    var.primary_ingest_lb_ip,
    trimspace(var.secondary_ingest_lb_ip) != "" ? var.secondary_ingest_lb_ip : null,
  ])
  method = "GET"
  path   = var.health_check_path
  port   = var.health_check_port

  # Host header is required for SNI - without it, the OCI Load Balancer
  # receives requests to the IP directly and returns 404 because it doesn't
  # know which backend to route to without the hostname.
  headers = {
    "Host" = local.global_ingest_fqdn
  }

  interval_in_seconds = var.health_check_interval_seconds
  timeout_in_seconds  = var.health_check_timeout_seconds
  is_enabled          = true

  # Specify vantage points if provided, otherwise OCI auto-selects
  vantage_point_names = length(var.health_check_vantage_point_names) > 0 ? var.health_check_vantage_point_names : null

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "HealthCheckMonitor"
    "Component"    = "LogScaleGlobalDNS"
  })

  lifecycle {
    precondition {
      condition     = trimspace(var.primary_ingest_lb_ip) != ""
      error_message = "manage_global_dns=true requires primary_ingest_lb_ip to be set. For dr=active, ensure the nginx-ingress LoadBalancer service exists and has an external IP. For dr=standby, ensure the primary cluster's remote state exports primary_ingest_lb_ip."
    }
  }
}

# Secondary health check monitor (TCP check when dr=active for standby readiness)
# This health check is optional - only created when secondary_ingest_lb_ip is available.
# In standby mode, the secondary cluster may not have an active LB (operator scaled to 0).
# The DR failover steering policy uses only the primary health check for failover decisions.
#
# NOTE: Only created when use_external_health_check=true.
resource "oci_health_checks_ping_monitor" "logscale_global_secondary" {
  count          = var.manage_global_dns && var.use_external_health_check && var.dr == "active" && trimspace(var.secondary_ingest_lb_ip) != "" ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${local.global_ingest_fqdn}-secondary-ping-monitor"

  protocol = "TCP"
  targets  = [var.secondary_ingest_lb_ip]
  port     = 8080

  interval_in_seconds = 60
  timeout_in_seconds  = 30
  is_enabled          = true

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "HealthCheckMonitor"
    "Component"    = "LogScaleGlobalDNSSecondary"
  })
}

# DNS Traffic Management Steering Policy for failover
#
# Rule chain: FILTER → PRIORITY → LIMIT (all modes)
#
# The HEALTH rule is intentionally NOT used, even when health check monitors
# exist. This prevents automatic failback to the primary cluster after a
# failover event. Without the HEALTH rule, DNS stays on whichever cluster
# the DR function has directed traffic to, ensuring an operator must
# explicitly verify primary readiness (data sync, LogScale caught up, etc.)
# before manually failing back.
#
# Health check monitors (controlled by use_external_health_check) remain
# for observability, OCI console dashboards, and DR function pre-validation
# — they just don't influence DNS routing directly.
#
# Failover is controlled by the DR failover function setting is_disabled
# on steering policy answers. Failback requires manual operator action.
#
resource "oci_dns_steering_policy" "logscale_global_failover" {
  count          = var.manage_global_dns ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${local.global_ingest_fqdn}-failover-policy"
  template       = "CUSTOM"
  ttl            = var.dns_record_ttl

  # Primary LogScale ingest endpoint
  answers {
    name        = "primary-ingest"
    rtype       = "A"
    rdata       = var.primary_ingest_lb_ip
    pool        = "primary"
    is_disabled = false
  }

  # Secondary LogScale ingest endpoint (optional - only when secondary LB IP is available)
  # In DR standby mode, the secondary may not have an active LB until failover occurs
  dynamic "answers" {
    for_each = trimspace(var.secondary_ingest_lb_ip) != "" ? [1] : []
    content {
      name        = "secondary-ingest"
      rtype       = "A"
      rdata       = var.secondary_ingest_lb_ip
      pool        = "secondary"
      is_disabled = false
    }
  }

  # Filter rule - keep answers that are not disabled
  # The DR failover function controls is_disabled on each answer to direct traffic
  rules {
    rule_type = "FILTER"

    default_answer_data {
      answer_condition = "answer.isDisabled != true"
      should_keep      = true
    }
  }

  # Priority rule - primary gets value 1 (highest), secondary gets 99 (lowest)
  rules {
    rule_type = "PRIORITY"

    default_answer_data {
      answer_condition = "answer.name == 'primary-ingest'"
      value            = 1
    }

    dynamic "default_answer_data" {
      for_each = trimspace(var.secondary_ingest_lb_ip) != "" ? [1] : []
      content {
        answer_condition = "answer.name == 'secondary-ingest'"
        value            = 99
      }
    }
  }

  # Limit rule ensures only one A record is returned to clients at a time
  rules {
    rule_type     = "LIMIT"
    default_count = 1
  }

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "DnsSteeringPolicy"
    "Component"    = "LogScaleGlobalDNS"
  })

  lifecycle {
    precondition {
      condition     = trimspace(var.primary_ingest_lb_ip) != ""
      error_message = "manage_global_dns=true requires primary_ingest_lb_ip to be set. For dr=active, ensure the nginx-ingress LoadBalancer service exists and has an external IP. For dr=standby, ensure the primary cluster's remote state exports primary_ingest_lb_ip."
    }
    # Ignore changes to 'answers' to prevent unnecessary steering policy replacements.
    # The 'answers' block contains 'rdata' (IP addresses) which are discovered dynamically
    # from Kubernetes Service status. When the data source is refreshed during terraform plan,
    # the IP shows as "(known after apply)" which triggers a "forces replacement" even when
    # the actual IP hasn't changed. This causes unnecessary DNS disruption.
    #
    # If LB IP actually changes (e.g., after LB recreation):
    # 1. Run: terraform taint 'module.global-dns[0].oci_dns_steering_policy.logscale_global_failover[0]'
    # 2. Then: terraform apply
    # Or use OCI CLI: oci dns steering-policy update --steering-policy-id <id> --answers '<json>'
    #
    # DR failover (is_disabled changes) is handled by the DR failover function, not Terraform.
    ignore_changes = [answers]
  }
}

# Attach the steering policy to the DNS zone
resource "oci_dns_steering_policy_attachment" "logscale_global_failover" {
  count = var.manage_global_dns ? 1 : 0

  steering_policy_id = oci_dns_steering_policy.logscale_global_failover[0].id
  zone_id            = local.effective_zone_id
  domain_name        = local.global_ingest_fqdn
  display_name       = "${local.global_ingest_fqdn}-failover-attachment"
}

# Cluster-level CNAME record (cluster_name.zone_name -> logscale_public_fqdn)
# This creates a stable alias for the cluster pointing to the LogScale public FQDN.
# Only created when manage_global_dns=true, cluster_name is provided, and zone exists.
resource "oci_dns_rrset" "cluster_cname_record" {
  count           = var.manage_global_dns && var.cluster_name != "" && var.logscale_public_fqdn != "" ? 1 : 0
  zone_name_or_id = local.effective_zone_id
  domain          = "${var.cluster_name}.${var.zone_name}"
  rtype           = "CNAME"

  items {
    domain = "${var.cluster_name}.${var.zone_name}"
    rtype  = "CNAME"
    ttl    = 60
    rdata  = var.logscale_public_fqdn
  }
}
