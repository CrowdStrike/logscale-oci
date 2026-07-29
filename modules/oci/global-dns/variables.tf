variable "compartment_ocid" {
  description = "Compartment OCID for OCI DNS resources"
  type        = string
}

variable "cluster_name" {
  description = "Name of the cluster, used for the cluster CNAME record (cluster_name.zone_name)"
  type        = string
  default     = ""
}

variable "logscale_public_fqdn" {
  description = "Public FQDN for the LogScale cluster, used as the target for the cluster CNAME record"
  type        = string
  default     = ""
}

variable "create_dns_zone" {
  description = "When true, creates a new OCI DNS zone. When false, uses an existing zone specified by zone_id."
  type        = bool
  default     = false
}

variable "zone_id" {
  description = "OCI DNS Zone OCID for the hosted zone (used when create_dns_zone=false)"
  type        = string
  default     = ""
}

variable "zone_name" {
  description = "OCI DNS zone domain name (e.g., example.com)"
  type        = string
}

variable "dns_record_ttl" {
  description = "TTL of the global LogScale DNS records"
  type        = number
  default     = 30
}

variable "manage_global_dns" {
  description = "When true, this module manages the global LogScale failover DNS records."
  type        = bool
}

variable "global_logscale_hostname" {
  description = "Short hostname (record name) for the global LogScale FQDN within the hosted zone (for example: \"logscale-dr\")."
  type        = string
}

variable "primary_logscale_hostname" {
  description = "Short hostname (record name) for the primary LogScale cluster within the hosted zone (for example: \"logscale-dr-primary\")."
  type        = string
}

variable "secondary_logscale_hostname" {
  description = "Short hostname (record name) for the secondary LogScale cluster within the hosted zone (for example: \"logscale-dr-secondary\")."
  type        = string
}

variable "primary_ingest_lb_ip" {
  description = "Load balancer IP address for the primary LogScale ingest endpoint (required when manage_global_dns=true)"
  type        = string
  default     = ""
}

variable "secondary_ingest_lb_ip" {
  description = "Load balancer IP address for the secondary LogScale ingest endpoint"
  type        = string
}

variable "dr" {
  description = "DR mode: 'active', 'standby', or '' (empty for non-DR mode, treated as active)"
  type        = string
  default     = "active"

  validation {
    condition     = var.dr == "" || contains(["active", "standby"], var.dr)
    error_message = "dr must be either 'active', 'standby', or empty string (non-DR mode)"
  }
}

variable "health_check_path" {
  description = "Health check path for LogScale status endpoint"
  type        = string
  default     = "/api/v1/status"
}

variable "health_check_port" {
  description = "Health check port for LogScale ingest endpoint"
  type        = number
  default     = 443
}

variable "health_check_interval_seconds" {
  description = "Interval between health checks in seconds"
  type        = number
  default     = 30
}

variable "health_check_timeout_seconds" {
  description = "Timeout for health checks in seconds"
  type        = number
  default     = 10
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

variable "health_check_vantage_point_names" {
  description = "List of OCI Health Check vantage point names to use for probing. If empty, OCI auto-selects vantage points."
  type        = list(string)
  default     = []
}

variable "use_external_health_check" {
  description = "Create OCI Health Check monitors for observability, dashboards, and DR function pre-validation. Does NOT affect DNS routing — the steering policy always uses FILTER → PRIORITY → LIMIT without a HEALTH rule, preventing automatic failback. Failover/failback is always controlled by the DR function via is_disabled flag."
  type        = bool
  default     = true
}
