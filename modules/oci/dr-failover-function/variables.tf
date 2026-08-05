variable "enabled" {
  description = "Enable the DR failover function. Expects OCI health checks to be managed and an accessible OKE cluster."
  type        = bool
  default     = false
}

variable "primary_health_check_id" {
  description = "OCI health check ID for the primary ingest endpoint."
  type        = string
  default     = null
}

variable "create_primary_health_check_monitor" {
  description = "When true, create a dedicated PRIMARY HTTP health check monitor in the same region as the alarm/function (recommended for cross-region DR). When false, use primary_health_check_id."
  type        = bool
  default     = false
}

variable "primary_ingest_lb_ip" {
  description = "Primary ingest load balancer IP to probe when create_primary_health_check_monitor=true."
  type        = string
  default     = ""
}

variable "primary_health_check_host_header" {
  description = "HTTP Host header to send to the primary ingest endpoint (required for HTTPS SNI when probing an IP target). Used when create_primary_health_check_monitor=true."
  type        = string
  default     = ""
}

variable "primary_health_check_path" {
  description = "HTTP path probed on the primary ingest endpoint when create_primary_health_check_monitor=true."
  type        = string
  default     = "/api/v1/status"
}

variable "primary_health_check_port" {
  description = "TCP port probed on the primary ingest endpoint when create_primary_health_check_monitor=true."
  type        = number
  default     = 443
}

variable "primary_health_check_interval_seconds" {
  description = "Probe interval for the primary health check monitor created by this module."
  type        = number
  default     = 60
}

variable "primary_health_check_timeout_seconds" {
  description = "Probe timeout for the primary health check monitor created by this module."
  type        = number
  default     = 30
}

variable "secondary_health_check_id" {
  description = "OCI health check ID for the secondary ingest endpoint."
  type        = string
  default     = null
}

variable "compartment_ocid" {
  description = "Compartment OCID for OCI resources"
  type        = string
}

variable "root_tenancy_ocid" {
  description = "Root tenancy OCID (required for dynamic group creation)"
  type        = string
}

variable "cluster_id" {
  description = "OKE cluster OCID to access for operator scaling."
  type        = string
}

variable "cluster_region" {
  description = "OCI region for the standby OKE cluster."
  type        = string
}

variable "cluster_namespace" {
  description = "Namespace containing the HumioCluster."
  type        = string
  default     = "logging"
}

variable "operator_target_replicas" {
  description = "Humio operator replica count to enforce on failover (set to 1 to bring operator online)."
  type        = number
  default     = 1
}

variable "name_prefix" {
  description = "Prefix for created resources (notifications topic, function, alarm). Typically set to cluster_name. The function will be named {name_prefix}-dr-failover-handler to match AWS/GCP naming."
  type        = string
  default     = "logscale"
}

variable "common_tags" {
  description = "Common tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "mandatory_tags" {
  description = "Mandatory tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "function_timeout_seconds" {
  description = "Function timeout in seconds."
  type        = number
  default     = 300
}

variable "function_memory_mb" {
  description = "Function memory size in MB."
  type        = number
  default     = 256
}

variable "log_retention_days" {
  description = "Log retention for the function logs. Must be 30, 60, 90, 120, 150, or 180 days per OCI API requirements."
  type        = number
  default     = 30

  validation {
    condition     = contains([30, 60, 90, 120, 150, 180], var.log_retention_days)
    error_message = "log_retention_days must be 30, 60, 90, 120, 150, or 180 days (OCI API requirement)."
  }
}

variable "skip_secondary_health_check" {
  description = "Skip secondary health check gating; useful for DR simulations where the standby cluster is intentionally scaled to 0."
  type        = bool
  default     = false
}

variable "pre_failover_failure_seconds" {
  description = "Minimum consecutive seconds primary must be failing before failover. Set to 0 for immediate failover (testing only). Default 180 seconds prevents false failovers from transient issues."
  type        = number
  default     = 180

  validation {
    condition     = var.pre_failover_failure_seconds >= 0 && var.pre_failover_failure_seconds <= 600
    error_message = "pre_failover_failure_seconds must be between 0 and 600 seconds."
  }
}

variable "failover_cooldown_seconds" {
  description = "Minimum time between failovers to prevent flapping. Default 300 seconds (5 minutes)."
  type        = number
  default     = 300

  validation {
    condition     = var.failover_cooldown_seconds >= 0 && var.failover_cooldown_seconds <= 3600
    error_message = "failover_cooldown_seconds must be between 0 and 3600 seconds."
  }
}

variable "persist_failover_cooldown" {
  description = "Persist cooldown state on the humio-operator Deployment annotation so it survives function cold starts."
  type        = bool
  default     = true
}

variable "cooldown_annotation_key" {
  description = "Annotation key used to persist DR failover cooldown state on the humio-operator Deployment."
  type        = string
  default     = "logscale.dr/last-failover-epoch"
}

variable "max_retries" {
  description = "Retry attempts for K8s API calls on transient errors."
  type        = number
  default     = 3

  validation {
    condition     = var.max_retries >= 0 && var.max_retries <= 10
    error_message = "max_retries must be between 0 and 10."
  }
}

variable "base_delay_seconds" {
  description = "Base delay for exponential backoff between retries."
  type        = number
  default     = 1.0

  validation {
    condition     = var.base_delay_seconds >= 0.1 && var.base_delay_seconds <= 10
    error_message = "base_delay_seconds must be between 0.1 and 10."
  }
}

variable "max_delay_seconds" {
  description = "Maximum delay cap between retries."
  type        = number
  default     = 30.0

  validation {
    condition     = var.max_delay_seconds >= 1 && var.max_delay_seconds <= 60
    error_message = "max_delay_seconds must be between 1 and 60."
  }
}

variable "steering_policy_id" {
  description = "OCI DNS steering policy OCID to update during failover (global LogScale ingest)."
  type        = string
  default     = ""
}

variable "steering_policy_attachment_id" {
  description = "OCI DNS steering policy attachment OCID (optional) to refresh after updates."
  type        = string
  default     = ""
}

variable "secondary_pool_name" {
  description = "Pool name used for the secondary answer within the steering policy (default: secondary)."
  type        = string
  default     = "secondary"
}

variable "ingress_namespace" {
  description = "Kubernetes namespace where the nginx ingress service runs (used to discover LB IP)."
  type        = string
  default     = "logging-ingress"
}

variable "ingress_service_name" {
  description = "Kubernetes service name for the nginx ingress controller (used to discover LB IP)."
  type        = string
  default     = "nginx-ingress-nginx-controller"
}

variable "certificate_secret_name" {
  description = "TLS secret name that should be ready before DNS flip (optional). When empty, no cert readiness wait is performed."
  type        = string
  default     = ""
}

variable "certificate_secret_namespace" {
  description = "Namespace of the TLS secret to check before DNS flip."
  type        = string
  default     = "logging-ingress"
}

variable "cert_wait_timeout_seconds" {
  description = "Maximum seconds to wait for the certificate secret to exist and contain tls.crt before updating DNS. 0 disables waiting."
  type        = number
  default     = 0
}

variable "humiocluster_name" {
  description = <<-EOT
    Name of the HumioCluster CR. Used for TLS secret cleanup before scaling operator.

    When the operator is scaled from 0 to 1, cert-manager may regenerate the CA keypair
    but the cluster TLS secret (named after the HumioCluster) retains the old CA.
    Deleting this secret before scaling allows cert-manager to recreate it with the
    correct CA, preventing TLS verification failures.

    Leave empty to skip TLS secret cleanup.
  EOT
  type        = string
  default     = ""
}

variable "pod_ready_timeout_seconds" {
  description = <<-EOT
    Maximum time to wait for LogScale pods to become ready after scaling operator.

    This ensures the failover is truly complete before DNS is updated, preventing
    traffic from being routed to pods that aren't ready to serve requests.

    Set to 0 to disable pod readiness waiting (not recommended for production).
    Default 300 seconds (5 minutes) allows time for pods to pull images and start.
  EOT
  type        = number
  default     = 300

  validation {
    condition     = var.pod_ready_timeout_seconds >= 0 && var.pod_ready_timeout_seconds <= 900
    error_message = "pod_ready_timeout_seconds must be between 0 and 900 seconds (15 minutes)."
  }
}

variable "pod_ready_target_count" {
  description = <<-EOT
    Minimum number of LogScale pods that must be ready before DNS is updated.

    Default 1 ensures at least one pod is serving traffic before DNS failover.
    For higher availability, set to match your expected pod count.
    Set to 0 to disable pod readiness waiting.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.pod_ready_target_count >= 0 && var.pod_ready_target_count <= 100
    error_message = "pod_ready_target_count must be between 0 and 100."
  }
}

variable "notification_endpoint_protocol" {
  description = "Protocol for notification endpoint (ORACLE_FUNCTIONS for OCI Functions invocation)"
  type        = string
  default     = "ORACLE_FUNCTIONS"
}

variable "subnets" {
  description = "List of subnet OCIDs for the function"
  type        = list(string)
}

variable "vcn_id" {
  description = "VCN OCID for function networking"
  type        = string
}

variable "ocir_repo_name" {
  description = "OCIR repository name for the function image"
  type        = string
  default     = "dr-failover-function"
}

variable "function_image_tag" {
  description = "Tag for the function container image"
  type        = string
  default     = "latest"
}

# =============================================================================
# OCIR Image Build Variables
# =============================================================================

variable "auto_build_image" {
  description = "Automatically build and push the function Docker image to OCIR. Requires Docker to be installed and running locally."
  type        = bool
  default     = true
}

variable "ocir_user_ocid" {
  description = "OCID of the OCI user for OCIR authentication. Terraform will create an auth token for this user automatically."
  type        = string
}



variable "absent_detection_period" {
  description = "Absence detection period for the alarm. Valid values: 1m to 3d. Shorter values trigger faster but may cause false positives."
  type        = string
  default     = "2m"

  validation {
    condition     = can(regex("^[0-9]+(m|h|d)$", var.absent_detection_period))
    error_message = "absent_detection_period must be in format: <number><unit> where unit is m (minutes), h (hours), or d (days). Example: 2m, 1h, 3d"
  }
}

variable "alarm_pending_duration" {
  description = "Time alarm must be in firing state before triggering. ISO 8601 duration format. Default PT1M (1 minute). Set to PT30S or PT0S for faster testing."
  type        = string
  default     = "PT1M"

  validation {
    condition     = can(regex("^PT[0-9]+(S|M|H)$", var.alarm_pending_duration))
    error_message = "alarm_pending_duration must be in ISO 8601 duration format: PT<number><unit> where unit is S (seconds), M (minutes), or H (hours). Example: PT30S, PT1M, PT5M"
  }
}

variable "alarm_repeat_notification_duration" {
  description = "How often to re-send notifications while alarm is firing. ISO 8601 duration format. Default PT10M (10 minutes)."
  type        = string
  default     = "PT10M"

  validation {
    condition     = can(regex("^PT[0-9]+(S|M|H)$", var.alarm_repeat_notification_duration))
    error_message = "alarm_repeat_notification_duration must be in ISO 8601 duration format: PT<number><unit> where unit is S (seconds), M (minutes), or H (hours). Example: PT5M, PT10M"
  }
}

# =============================================================================
# Kubernetes RBAC Variables
# =============================================================================

variable "create_kubernetes_rbac" {
  description = "Create Kubernetes RBAC resources (ClusterRole and ClusterRoleBinding) to allow the function's dynamic group to manage deployments. Requires the kubernetes provider to be configured."
  type        = bool
  default     = true
}

# =============================================================================
# Load Balancer Health Monitoring Variables (Recommended)
# =============================================================================

variable "use_lb_health_metrics" {
  description = <<-EOT
    Use OCI Classic Load Balancer backend health metrics instead of OCI Health Checks Service.

    When true (RECOMMENDED):
    - Uses oci_lbaas namespace with unhealthyBackendServers metric
    - Health checks run from within OCI (LB to backends)
    - Not blocked by security list restrictions
    - More reliable for firewall-restricted environments

    When false (legacy):
    - Uses oci_healthchecks namespace with HTTP.isHealthy metric
    - Health checks run from external vantage points (AWS, Azure, GCP)
    - May be blocked by public_lb_cidrs security list
    - Alarm may fire even when LB backends are healthy
  EOT
  type        = bool
  default     = true
}

variable "primary_lb_ocid" {
  description = "OCID of the primary cluster's Classic Load Balancer. Required when use_lb_health_metrics=true."
  type        = string
  default     = ""
}

variable "lb_backend_set_name" {
  description = "Name of the LB backend set to monitor for health. Typically 'TCP-443' for nginx-ingress."
  type        = string
  default     = "TCP-443"
}

# =============================================================================
# Network Security Group Variables
# =============================================================================

variable "worker_nsg_id" {
  description = <<-EOT
    OCID of the worker node NSG. Required for function networking to allow:
    1. Function to access OKE API endpoint (port 6443)
    2. Proper network isolation within the VCN

    The function is placed in the same subnets as worker nodes, so it needs
    the worker NSG for egress to the API endpoint.
  EOT
  type        = string
}

variable "api_endpoint_nsg_id" {
  description = <<-EOT
    OCID of the OKE API endpoint NSG. Required to add an ingress rule allowing
    the function (from worker NSG) to access the Kubernetes API on port 6443.
  EOT
  type        = string
}
