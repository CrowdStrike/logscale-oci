output "global_ingest_fqdn" {
  description = "Global LogScale ingest FQDN configured with OCI DNS Traffic Management failover between primary and secondary clusters. Returns null when manage_global_dns is false."
  value       = var.manage_global_dns && local.global_ingest_fqdn != null ? local.global_ingest_fqdn : null
}

output "primary_health_check_id" {
  description = "OCI Health Check ID for the primary ingest endpoint. Null when manage_global_dns is false or use_external_health_check is false."
  value       = var.manage_global_dns && var.use_external_health_check ? oci_health_checks_http_monitor.logscale_global_primary[0].id : null
}

output "secondary_health_check_id" {
  description = "OCI Health Check ID for the secondary (TCP ping when dr=active for standby mode). Null when manage_global_dns is false, use_external_health_check is false, dr=standby, or secondary_ingest_lb_ip is not set."
  value       = var.manage_global_dns && var.use_external_health_check && var.dr == "active" && trimspace(var.secondary_ingest_lb_ip) != "" ? oci_health_checks_ping_monitor.logscale_global_secondary[0].id : null
}

output "steering_policy_id" {
  description = "OCI DNS Steering Policy ID for the global failover policy. Null when manage_global_dns is false."
  value       = var.manage_global_dns ? oci_dns_steering_policy.logscale_global_failover[0].id : null
}

output "steering_policy_attachment_id" {
  description = "OCI DNS Steering Policy Attachment ID for the global failover policy. Null when manage_global_dns is false."
  value       = var.manage_global_dns ? oci_dns_steering_policy_attachment.logscale_global_failover[0].id : null
}

output "dns_zone_id" {
  description = "OCI DNS Zone ID. Returns the created zone ID if create_dns_zone=true, otherwise returns the provided zone_id."
  value       = (var.create_dns_zone || var.manage_global_dns) ? local.effective_zone_id : null
}

output "dns_zone_nameservers" {
  description = "OCI DNS Zone nameservers. Only populated when create_dns_zone=true. These must be configured at your domain registrar for DNS delegation."
  value       = var.create_dns_zone ? oci_dns_zone.global_dns[0].nameservers[*].hostname : null
}

output "use_external_health_check" {
  description = "Whether the steering policy uses external health checks (true) or function-controlled failover (false)."
  value       = var.use_external_health_check
}
