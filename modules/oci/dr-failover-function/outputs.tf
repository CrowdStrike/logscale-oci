output "notification_topic_id" {
  description = "Notification topic used by the failover alarm."
  value       = local.enabled ? oci_ons_notification_topic.failover[0].id : null
}

output "function_name" {
  description = "Name of the failover function."
  value       = local.enabled ? oci_functions_function.failover[0].display_name : null
}

output "function_application_id" {
  description = "Function application ID for the failover function."
  value       = local.enabled ? oci_functions_application.failover[0].id : null
}

output "dynamic_group_id" {
  description = "Dynamic group ID used by the failover function."
  value       = local.enabled ? oci_identity_dynamic_group.function[0].id : null
}

output "alarm_id" {
  description = "Monitoring alarm ID for primary health check failure."
  value       = local.enabled ? oci_monitoring_alarm.primary_unhealthy[0].id : null
}

output "primary_health_check_id" {
  description = "Effective PRIMARY Health Checks monitor OCID used by the alarm/function (created in-region when enabled)."
  value       = local.enabled ? local.effective_primary_health_check_id : null
}

output "ocir_repository_id" {
  description = "OCIR container repository ID for the function image."
  value       = local.enabled ? oci_artifacts_container_repository.function[0].id : null
}

output "ocir_image_uri" {
  description = "Full OCIR image URI for the function (region.ocir.io/namespace/repo:tag)."
  value       = local.enabled ? local.ocir_image_uri : null
}

output "function_config_ids" {
  description = "Steering policy identifiers passed into the function for DNS updates."
  value = local.enabled ? {
    steering_policy_id            = var.steering_policy_id
    steering_policy_attachment_id = var.steering_policy_attachment_id
  } : null
}

output "log_group_id" {
  description = "Log group ID for the DR failover function logs."
  value       = local.enabled ? oci_logging_log_group.function[0].id : null
}

output "log_id" {
  description = "Log ID for function invocation logs."
  value       = local.enabled ? oci_logging_log.function_invoke[0].id : null
}

output "monitoring_mode" {
  description = "Monitoring mode used by the DR alarm: 'lb_health' or 'health_check'."
  value       = local.enabled ? (var.use_lb_health_metrics ? "lb_health" : "health_check") : null
}
