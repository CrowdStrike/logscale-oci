# =============================================================================
# Workspace Validation
# =============================================================================
variable "workspace_name" {
  description = "Expected Terraform workspace name. Must match terraform.workspace to prevent applying wrong tfvars to wrong workspace."
  type        = string
}

# Core OCI Configuration
variable "tenancy_ocid" {
  description = "OCID of the tenancy"
  type        = string
}

variable "root_tenancy_ocid" {
  description = "OCID of the root tenancy (required for dynamic group creation)"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the compartment"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
}

variable "home_region" {
  description = "OCI home region for tenancy operations (typically us-phoenix-1)"
  type        = string
  default     = "us-phoenix-1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+-[0-9]+$", var.home_region))
    error_message = "Home region must be in format like 'us-phoenix-1'."
  }
}

variable "kubernetes_api_host" {
  description = <<-EOT
    Kubernetes API server host. Only required when using bastion tunnel access
    (provision_bastion=true). When endpoint_public_access=true and provision_bastion=false,
    this is ignored and the public endpoint is automatically discovered from the kubeconfig.
  EOT
  type        = string
  default     = "https://127.0.0.1:6443"

  validation {
    condition     = can(regex("^https?://[a-zA-Z0-9.-]+:[0-9]+\\s*$", var.kubernetes_api_host))
    error_message = "Kubernetes API host must be a valid URL with port (e.g., https://127.0.0.1:6443)."
  }
}

variable "user_fingerprint" {
  description = "Fingerprint for the user's API key"
  type        = string
}

variable "private_key_path" {
  description = "Path to the user's API private key"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the user"
  type        = string
}

variable "config_file_profile" {
  description = "OCI CLI config file profile name (deprecated - use API key authentication instead)"
  type        = string
  default     = ""
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}



variable "dr" {
  description = <<-EOT
    Disaster Recovery mode:
    - 'active': Primary/active cluster with full DR infrastructure (global-dns, health checks). Used for production clusters.
      IMPORTANT: Only 'active' makes the cluster part of a DR strategy with health monitoring and automated failover.
    - 'standby': DR standby cluster with failover automation (dr-failover-function). Humio operator scaled to 0, S3_RECOVER_FROM_* env vars configured.
    - '' (empty): Non-DR mode. No DR-specific components deployed. Cluster operates standalone without DR infrastructure.

    To promote a standby cluster, change from 'standby' to 'active' (or '') and apply.
    Note: Setting 'active' maintains DR capabilities; setting '' removes DR infrastructure entirely.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.dr == "" || contains(["active", "standby"], var.dr)
    error_message = "dr must be either 'active', 'standby', or empty string (non-DR mode)"
  }
}

variable "dr_use_dedicated_routing" {
  description = <<-EOT
    Enable dedicated pool routing for DR clusters after promotion is complete.

    Two-phase DR promotion workflow for zero-downtime:
    1. First apply: Set dr="active" with dr_use_dedicated_routing=false (default)
       - Service selectors use { "app.kubernetes.io/name" = "humio" } to match ALL pods
       - Traffic continues to existing digest pod during UI/Ingest pod scale-up
       - Zero-downtime guaranteed

    2. Second apply: Set dr_use_dedicated_routing=true after UI/Ingest pods are ready
       - Service selectors switch to pool-specific routing
       - UI traffic routes to UI pods (humio.com/node-pool=<prefix>-ui)
       - Ingest traffic routes to Ingest pods (humio.com/node-pool=<prefix>-ingest-only)
       - Optimized traffic distribution like non-DR clusters

    For non-DR clusters (dr=""), this variable is ignored - pool-specific routing is always used.
  EOT
  type        = bool
  default     = false
}

variable "dr_primary_bucket_name" {
  description = "DR peer cluster's Object Storage bucket name for cross-region read access. For secondary cluster, this is the primary bucket. For primary cluster, this is the secondary bucket."
  type        = string
  default     = null
}

variable "primary_remote_state_config" {
  description = "Optional terraform_remote_state backend configuration used by standby clusters to read the primary's outputs. Supports any backend (e.g., OCI Object Storage or S3). When unset, the legacy dr_remote_state_* variables are used."
  type = object({
    backend   = string
    workspace = optional(string)
    config    = map(any)
  })
  default = null
}

variable "secondary_remote_state_config" {
  description = "Optional terraform_remote_state backend configuration used by primary clusters to read the secondary's outputs (e.g., secondary_ingest_lb_ip for health check monitoring). Only used when dr=\"active\" and manage_global_dns=true."
  type = object({
    backend   = string
    workspace = optional(string)
    config    = map(any)
  })
  default = null
}

variable "dr_failover_function_enabled" {
  description = "Enable OCI Function-based DR failover automation (only used when dr=\"standby\")."
  type        = bool
  default     = true
}

variable "dr_failover_function_target_node_count" {
  description = "Target humio-operator replica count to enforce during failover (typically 1 on standby)."
  type        = number
  default     = 1
}

variable "dr_failover_function_timeout" {
  description = "OCI Function timeout in seconds for the DR failover handler."
  type        = number
  default     = 300
}

variable "dr_failover_function_memory_mb" {
  description = "Memory allocation in MB for the DR failover function."
  type        = number
  default     = 256
}

variable "dr_failover_function_log_retention_days" {
  description = "OCI Logging retention (in days) for the DR failover function."
  type        = number
  default     = 30
}

variable "dr_failover_function_skip_secondary_health_check" {
  description = "Skip the secondary health check gate in the failover function (useful for DR simulations when standby is scaled to 0)."
  type        = bool
  default     = false
}

variable "dr_failover_function_create_primary_health_check_monitor" {
  description = "When true (recommended), the standby workspace creates a dedicated PRIMARY HTTP monitor in the standby region for DR automation (avoids cross-region Health Checks metrics/probe results limitations)."
  type        = bool
  default     = true
}

variable "dr_failover_function_primary_health_check_path" {
  description = "HTTP path used by the standby-created primary health check monitor (when dr_failover_function_create_primary_health_check_monitor=true)."
  type        = string
  default     = "/api/v1/status"
}

variable "dr_failover_function_primary_health_check_port" {
  description = "TCP port used by the standby-created primary health check monitor (when dr_failover_function_create_primary_health_check_monitor=true)."
  type        = number
  default     = 443
}

variable "dr_failover_function_primary_health_check_interval_seconds" {
  description = "Probe interval for the standby-created primary health check monitor."
  type        = number
  default     = 60
}

variable "dr_failover_function_primary_health_check_timeout_seconds" {
  description = "Probe timeout for the standby-created primary health check monitor."
  type        = number
  default     = 30
}

variable "dr_failover_function_pre_failover_failure_seconds" {
  description = "Minimum consecutive seconds primary must be failing before failover. Set to 0 for immediate failover (testing only). Default 180 seconds prevents false failovers from transient issues."
  type        = number
  default     = 180

  validation {
    condition     = var.dr_failover_function_pre_failover_failure_seconds >= 0 && var.dr_failover_function_pre_failover_failure_seconds <= 600
    error_message = "dr_failover_function_pre_failover_failure_seconds must be between 0 and 600 seconds."
  }
}

variable "dr_failover_function_alarm_pending_duration" {
  description = "Time alarm must be in firing state before triggering the function. ISO 8601 duration format. Default PT1M (1 minute). Set to PT30S for faster testing."
  type        = string
  default     = "PT1M"

  validation {
    condition     = can(regex("^PT[0-9]+(S|M|H)$", var.dr_failover_function_alarm_pending_duration))
    error_message = "dr_failover_function_alarm_pending_duration must be in ISO 8601 duration format: PT<number><unit> where unit is S (seconds), M (minutes), or H (hours). Example: PT30S, PT1M"
  }
}

variable "dr_failover_function_alarm_repeat_notification_duration" {
  description = "How often to re-send notifications while alarm is firing. ISO 8601 duration format. Default PT10M (10 minutes)."
  type        = string
  default     = "PT10M"

  validation {
    condition     = can(regex("^PT[0-9]+(S|M|H)$", var.dr_failover_function_alarm_repeat_notification_duration))
    error_message = "dr_failover_function_alarm_repeat_notification_duration must be in ISO 8601 duration format: PT<number><unit>. Example: PT5M, PT10M"
  }
}

variable "dr_failover_function_absent_detection_period" {
  description = "Absence detection period for the alarm (used when health check is disabled). Valid values: 1m to 3d. Shorter values trigger faster but may cause false positives."
  type        = string
  default     = "2m"

  validation {
    condition     = can(regex("^[0-9]+(m|h|d)$", var.dr_failover_function_absent_detection_period))
    error_message = "dr_failover_function_absent_detection_period must be in format: <number><unit> where unit is m (minutes), h (hours), or d (days). Example: 1m, 2m, 1h"
  }
}

variable "dr_primary_health_check_id" {
  description = "Primary cluster health check ID (used by standby for DR failover automation when remote state is unavailable)."
  type        = string
  default     = ""
}

variable "dr_secondary_health_check_id" {
  description = "Secondary cluster health check ID (used by standby for DR failover automation when remote state is unavailable)."
  type        = string
  default     = ""
}

variable "function_subnet_ids" {
  description = "Optional list of subnet OCIDs for deploying the DR failover function. Defaults to the node pool subnets when unset."
  type        = list(string)
  default     = []
}

# =============================================================================
# OCIR Image Build Configuration
# =============================================================================

variable "dr_failover_function_auto_build_image" {
  description = "Automatically build and push the DR failover function Docker image to OCIR during terraform apply. Requires Docker to be installed and running locally."
  type        = bool
  default     = true
}

variable "dr_failover_function_use_lb_health_metrics" {
  description = <<-EOT
    Use OCI Classic Load Balancer backend health metrics instead of OCI Health Checks Service for DR failover alarm.

    When true (RECOMMENDED):
    - Uses oci_lbaas namespace with unhealthyBackendServers metric
    - Health checks run from within OCI (LB to backends)
    - Not blocked by public_lb_cidrs security list restrictions
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

variable "dr_failover_function_lb_backend_set_name" {
  description = "Name of the LB backend set to monitor for health. Typically 'TCP-443' for nginx-ingress."
  type        = string
  default     = "TCP-443"
}

variable "dr_failover_function_pod_ready_timeout" {
  description = <<-EOT
    Maximum seconds to wait for LogScale pods to become ready after scaling operator.

    This ensures the failover is truly complete before DNS is updated, preventing
    traffic from being routed to pods that aren't ready to serve requests.

    Set to 0 to disable pod readiness waiting (not recommended for production).
    Default 300 seconds (5 minutes) allows time for pods to pull images and start.
  EOT
  type        = number
  default     = 300

  validation {
    condition     = var.dr_failover_function_pod_ready_timeout >= 0 && var.dr_failover_function_pod_ready_timeout <= 900
    error_message = "dr_failover_function_pod_ready_timeout must be between 0 and 900 seconds (15 minutes)."
  }
}

variable "dr_failover_function_pod_ready_count" {
  description = <<-EOT
    Minimum number of LogScale pods that must be ready before DNS is updated.

    Default 1 ensures at least one pod is serving traffic before DNS failover.
    For higher availability, set to match your expected pod count.
    Set to 0 to disable pod readiness waiting.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.dr_failover_function_pod_ready_count >= 0 && var.dr_failover_function_pod_ready_count <= 100
    error_message = "dr_failover_function_pod_ready_count must be between 0 and 100."
  }
}

variable "use_external_health_check" {
  description = "Create OCI Health Check monitors for observability, dashboards, and DR function pre-validation. Does NOT affect DNS routing — the steering policy always uses FILTER → PRIORITY → LIMIT without a HEALTH rule, preventing automatic failback. Set to false for firewall-restricted environments where external vantage points cannot reach endpoints."
  type        = bool
  default     = false
}



variable "mandatory_tags" {
  description = "Mandatory tags required by organization policies"
  type        = map(string)
  default     = {}
}

variable "pods_cidr" {
  description = "CIDR block for Kubernetes pods"
  type        = string
  default     = "10.0.64.0/18"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "Pods CIDR must be a valid CIDR block."
  }
}

variable "services_cidr" {
  description = "CIDR block for Kubernetes services"
  type        = string
  default     = "10.96.0.0/16"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "Services CIDR must be a valid CIDR block."
  }
}

variable "endpoint_public_access" {
  description = "Whether the cluster API endpoint should be publicly accessible. When true, control_plane_allowed_cidrs is required."
  type        = bool
  default     = false
}

variable "cluster_endpoint_subnet_cidr" {
  description = "CIDR block for the cluster endpoint subnet"
  type        = string
  default     = "10.0.1.0/28"
}

variable "lb_subnet_cidr" {
  description = "CIDR block for the load balancer subnet"
  type        = string
  default     = "10.0.2.0/24"
}

# Resource Naming
variable "resource_name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "logscale"
}

# Node Group Definitions
variable "node_group_definitions" {
  description = "Map of node group definitions including instance types"
  type        = map(string)
  default = {
    logscale_ui_instance_type = "VM.Standard.E4.Flex"
  }
}

# Storage Configuration
variable "data_retention_days" {
  description = "Number of days to retain data"
  type        = number
  default     = 30
}

variable "archive_after_days" {
  description = "Number of days after which to archive data"
  type        = number
  default     = 30
}

variable "temp_data_retention_days" {
  description = "Number of days to retain temporary data"
  type        = number
  default     = 7
}


# Cluster Configuration
variable "cluster_name" {
  description = "Name of the OKE cluster"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}[a-z0-9]$", var.cluster_name))
    error_message = "Cluster name must start with a letter, contain only lowercase letters, numbers, and hyphens, and be 2-64 characters long."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster"
  type        = string
  default     = "v1.28.0"
}
variable "logscale_cluster_size" {
  description = "Size of the LogScale cluster"
  type        = string
  default     = "small"
}

variable "logscale_cluster_type" {
  description = "Type of the LogScale cluster"
  type        = string
  default     = "basic"
}

variable "oke_cluster_type" {
  description = "OKE cluster tier (BASIC_CLUSTER or ENHANCED_CLUSTER)"
  type        = string
  default     = "BASIC_CLUSTER"

  validation {
    condition     = contains(["BASIC_CLUSTER", "ENHANCED_CLUSTER"], var.oke_cluster_type)
    error_message = "oke_cluster_type must be BASIC_CLUSTER or ENHANCED_CLUSTER."
  }
}

variable "logscale_image_version" {
  description = "Version of LogScale image"
  type        = string
  default     = "latest"
}

variable "image_pull_secret" {
  description = "The Kubernetes secret containing credentials to access the image repository (e.g., Docker Hub). Required to avoid rate limiting when pulling humio/humio-core images."
  type        = string
  default     = "regcred"
}
variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  type        = string
}

# Network Configuration
variable "vcn_cidr" {
  description = "CIDR block for VCN"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0))
    error_message = "VCN CIDR must be a valid CIDR block."
  }

  validation {
    condition     = tonumber(split("/", var.vcn_cidr)[1]) <= 16
    error_message = "VCN CIDR prefix must be /16 or larger (smaller prefix number) for sufficient address space."
  }
}

variable "public_lb_cidrs" {
  description = "List of CIDR blocks allowed to access public load balancer"
  type        = list(string)
  default     = [] # Force explicit configuration

  validation {
    condition = alltrue([
      for cidr in var.public_lb_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "All public load balancer CIDR entries must be valid CIDR blocks."
  }
}

variable "control_plane_allowed_cidrs" {
  description = "List of CIDR blocks allowed to access the Kubernetes API endpoint (port 6443). Required when endpoint_public_access=true. 0.0.0.0/0 is not allowed."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.control_plane_allowed_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "All control plane allowed CIDR entries must be valid CIDR blocks."
  }
}

# Node Configuration

variable "enable_cluster_autoscaler" {
  description = "Enable cluster autoscaler"
  type        = bool
  default     = true
}
# Additional Configuration

# Worker and Bastion Configuration
variable "worker_image_id" {
  description = "The OCID of the image to use for worker nodes"
  type        = string
}
variable "provision_bastion" {
  description = "Whether to provision a bastion host. When true, bastion_client_allow_list is required."
  type        = bool
  default     = true
}

variable "enable_bastion_plugin" {
  description = "Whether to enable the Bastion plugin on worker nodes for OCI Bastion Service"
  type        = bool
  default     = true
}

variable "bastion_client_allow_list" {
  description = "List of CIDR blocks allowed to connect to the OCI Bastion Service. Required when provision_bastion=true. 0.0.0.0/0 is not allowed."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.bastion_client_allow_list : can(cidrhost(cidr, 0))
    ])
    error_message = "All bastion client allow list entries must be valid CIDR blocks."
  }

  validation {
    condition     = !contains(var.bastion_client_allow_list, "0.0.0.0/0")
    error_message = "Bastion access cannot be open to the entire internet (0.0.0.0/0). Specify specific CIDR blocks."
  }
}

variable "max_session_ttl" {
  description = "Maximum session TTL in seconds for OCI Bastion Service (1800-10800)"
  type        = number
  default     = 10800
}

variable "enable_dns_proxy" {
  description = "Whether to enable DNS proxy for the OCI Bastion Service"
  type        = bool
  default     = false
}
variable "target_replication_factor" {
  description = "Target replication factor for data"
  type        = number
  default     = 2
}

# Kubernetes Configuration

variable "kubectl_context" {
  description = "kubectl context for local-exec commands (e.g., 'oci-primary' or 'oci-secondary' from kubeconfig-dr.yaml). Required for DR standby to ensure humio-operator replica patch targets the correct cluster."
  type        = string
  default     = ""
}

variable "logscale_namespace" {
  description = "Kubernetes namespace for LogScale deployment"
  type        = string
  default     = "logging"
}

# DNS and Ingress
variable "external_dns_enabled" {
  description = "Whether to deploy external-dns for automatic DNS record management for the LogScale ingress hostname"
  type        = bool
  default     = false
}

variable "external_dns_chart_version" {
  description = "Helm chart version for external-dns"
  type        = string
  default     = "1.14.5"
}

variable "external_dns_repository" {
  description = "Helm repository URL for the external-dns chart"
  type        = string
  default     = "https://kubernetes-sigs.github.io/external-dns/"
}

variable "external_dns_domain_filters" {
  description = "Optional list of domain filters for external-dns (for example, \"mi-arch-oci-logscale.example.com\"). When empty, all accessible OCI DNS zones are considered."
  type        = list(string)
  default     = []
}

variable "dns_zone_name" {
  description = "Base DNS zone name in OCI DNS (for example, oci-ref-arch.com) used when creating cluster-level A records."
  type        = string
  default     = ""
}

variable "manage_global_dns" {
  description = "When true, manage global DNS failover records for LogScale using OCI DNS Traffic Management."
  type        = bool
  default     = false
}

variable "global_dns_zone_id" {
  description = "OCID of the OCI DNS zone where global LogScale records (primary/secondary/global) will be created. Used when create_global_dns_zone=false."
  type        = string
  default     = ""
}

variable "create_global_dns_zone" {
  description = "When true, creates a new OCI DNS zone for global LogScale DR failover. When false, uses an existing zone specified by global_dns_zone_id."
  type        = bool
  default     = false
}

variable "global_dns_record_ttl" {
  description = "TTL (seconds) for the global LogScale DNS steering policy records."
  type        = number
  default     = 30
}

variable "global_logscale_hostname" {
  description = "Short hostname for the global LogScale FQDN within the hosted zone (for example: \"logscale-dr\")."
  type        = string
  default     = ""
}

variable "primary_logscale_hostname" {
  description = "Short hostname for the primary LogScale cluster within the hosted zone (for example: \"logscale-dr-primary\")."
  type        = string
  default     = ""
}

variable "secondary_logscale_hostname" {
  description = "Short hostname for the secondary LogScale cluster within the hosted zone (for example: \"logscale-dr-secondary\")."
  type        = string
  default     = ""
}

variable "enable_ingest_dns_steering_policy" {
  description = "Enable OCI DNS Traffic Management FAILOVER steering policy and HTTP health check for the LogScale ingest endpoint (active DR cluster only)."
  type        = bool
  default     = false
}

variable "ingest_dns_zone_id" {
  description = "OCID of the existing OCI DNS zone that will host the LogScale ingest FAILOVER record."
  type        = string
  default     = ""
}

variable "ingest_dns_domain_name" {
  description = "Fully qualified domain name (FQDN) for the LogScale ingest endpoint managed by the FAILOVER steering policy (for example, logscale-ingest.example.com)."
  type        = string
  default     = ""
}

variable "primary_ingest_lb_ip" {
  description = "IPv4 address of the primary LogScale ingest load balancer used as the primary target in the FAILOVER steering policy."
  type        = string
  default     = ""
}

variable "secondary_ingest_lb_ip" {
  description = "IPv4 address of the secondary LogScale ingest load balancer used as the secondary target in the FAILOVER steering policy."
  type        = string
  default     = ""
}

variable "ingest_dns_ttl" {
  description = "TTL (seconds) for the LogScale ingest DNS FAILOVER steering policy answers."
  type        = number
  default     = 30
}

variable "ingest_health_check_path" {
  description = "HTTP path used by the OCI Health Checks monitor to validate the primary LogScale ingest load balancer."
  type        = string
  default     = "/health"
}

variable "ingest_health_check_port" {
  description = "TCP port used by the OCI Health Checks HTTP monitor when probing the primary LogScale ingest load balancer."
  type        = number
  default     = 80
}

# Strimzi and Operator Versions
variable "strimzi_operator_version" {
  description = "Version of Strimzi operator"
  type        = string
  default     = "0.47.0"
}

variable "strimzi_operator_chart_version" {
  description = "Helm chart version for Strimzi operator"
  type        = string
  default     = "0.47.0"
}

variable "provision_kafka_servers" {
  description = "Whether to provision Strimzi Kafka servers"
  type        = bool
  default     = true
}

variable "byo_kafka_connection_string" {
  description = "Bring your own Kafka connection string (leave empty to use Strimzi)"
  type        = string
  default     = ""
}


# LogScale Configuration
variable "logscale_license" {
  description = "LogScale license key"
  type        = string
  sensitive   = true
}

variable "logscale_public_fqdn" {
  description = "Public FQDN for LogScale cluster"
  type        = string
}

variable "humio_operator_version" {
  description = "Version of Humio operator"
  type        = string
  default     = "0.30.0"
}

variable "humio_operator_chart_version" {
  description = "Helm chart version for Humio operator"
  type        = string
  default     = "0.30.0"
}

variable "humio_operator_extra_values" {
  description = "Extra values for Humio operator Helm chart"
  type        = map(string)
  default     = {}
}

variable "topo_lvm_chart_version" {
  description = "Helm chart version for TopoLVM"
  type        = string
  default     = "15.5.2"
}

variable "topo_lvm_controller_replicas" {
  description = "Number of TopoLVM controller replicas"
  type        = number
  default     = 2
}

variable "nginx_ingress_helm_chart_version" {
  description = "DEPRECATED: nginx-ingress removed from upstream module. This variable is retained for tfvars compatibility but has no effect."
  type        = string
  default     = "4.12.1"
}

# Cert Manager Configuration
variable "cm_version" {
  description = "Cert-manager version"
  type        = string
  default     = "v1.15.1"
}

variable "cert_issuer_email" {
  description = "Email address for Let's Encrypt certificate issuer"
  type        = string
}

# =============================================================================
# DNS-01 ACME Challenge Configuration (OCI DNS Webhook)
# =============================================================================
# Note: DNS-01 reuses existing OCI credentials (tenancy_ocid, user_ocid,
# compartment_ocid, region, user_fingerprint, private_key_path)

variable "cert_dns01_webhook_enabled" {
  description = "Enable the OCI DNS webhook for cert-manager DNS-01 challenge (deployment behavior is controlled by cert_dns01_webhook_mode)."
  type        = bool
  default     = false
}

variable "cert_dns01_webhook_mode" {
  description = <<-EOT
    Controls when to deploy the native cert-manager OCI DNS-01 webhook and DNS-01 ClusterIssuer (only applies when cert_dns01_provider="oci" and cert_dns01_webhook_enabled=true):

    - auto: Deploy only when HTTP-01 is likely blocked (for example, public_lb_cidrs does not include 0.0.0.0/0, or DR standby using the global FQDN).
    - always: Always deploy DNS-01 webhook + ClusterIssuer.
  EOT
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "always"], var.cert_dns01_webhook_mode)
    error_message = "cert_dns01_webhook_mode must be either 'auto' or 'always'."
  }
}

variable "cert_dns01_webhook_repo_url" {
  description = "Git repository URL for the OCI DNS webhook Helm chart. Original: https://gitlab.com/dn13/cert-manager-webhook-oci.git"
  type        = string
  default     = "https://gitlab.com/dn13/cert-manager-webhook-oci.git"
}

variable "cert_dns01_webhook_git_ref" {
  description = "Git ref (branch/tag/commit) for the OCI DNS webhook Helm chart"
  type        = string
  default     = "master"
}

variable "cert_dns01_webhook_image_repo" {
  description = "Container image repository for the OCI DNS webhook"
  type        = string
  default     = "registry.gitlab.com/dn13/cert-manager-webhook-oci"
}

variable "cert_dns01_webhook_image_tag" {
  description = "Container image tag for the OCI DNS webhook"
  type        = string
  default     = "1.4.1"
}

variable "cert_dns01_provider" {
  description = "DNS-01 challenge provider. Set to 'oci' to use OCI DNS webhook, or empty string for HTTP-01."
  type        = string
  default     = ""
}

variable "cert_dns01_group_name" {
  description = "Webhook groupName for the OCI DNS-01 solver (must match the deployed OCI cert-manager webhook)."
  type        = string
  default     = "acme.d-n.be"
}

variable "cert_dns01_solver_name" {
  description = "Webhook solverName for the OCI DNS-01 solver."
  type        = string
  default     = "oci"
}

variable "cert_dns01_secret_name" {
  description = "Kubernetes secret name for OCI DNS credentials used by DNS-01 solver."
  type        = string
  default     = "oci-dns-credentials"
}

variable "use_native_webhook" {
  description = "Deprecated (no effect): cert-manager OCI DNS webhook is deployed using the native Terraform module only."
  type        = bool
  default     = true
}

variable "use_own_certificate_for_ingress" {
  description = "Use your own certificate for ingress instead of Let's Encrypt"
  type        = bool
  default     = false
}

# Password Rotation

variable "par_expiration_time" {
  description = "Pre-authenticated request expiration time in RFC3339 format. Set to a future date to avoid recreation."
  type        = string
  default     = "2026-12-31T23:59:59Z"

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.par_expiration_time))
    error_message = "PAR expiration time must be in valid RFC3339 format (e.g., 2026-12-31T23:59:59Z)."
  }
}
# Missing variables for logscale-prereqs module
# Missing Bastion Variables
variable "create_bastion_sessions" {
  description = "Whether to create bastion sessions via Terraform"
  type        = bool
  default     = false
}

# DR recovery configuration (mirrors AWS variables for LogScale)
variable "s3_recover_from_replace_region" {
  description = "Value for S3_RECOVER_FROM_REPLACE_REGION when configuring DR recovery. Format: <primary-region>/<secondary-region> (e.g., us-phoenix-1/us-ashburn-1)."
  type        = string
  default     = null
}

variable "s3_recover_from_replace_bucket" {
  description = "Value for S3_RECOVER_FROM_REPLACE_BUCKET. Format: <primary-bucket>/<secondary-bucket>."
  type        = string
  default     = null
}

variable "s3_recover_from_bucket" {
  description = "Value for S3_RECOVER_FROM_BUCKET (the PRIMARY cluster's Object Storage bucket)."
  type        = string
  default     = null
}

variable "s3_recover_from_region" {
  description = "Value for S3_RECOVER_FROM_REGION (the PRIMARY cluster's region)."
  type        = string
  default     = null
}

variable "s3_recover_from_encryption_key_secret_name" {
  description = "Secret name referenced by S3_RECOVER_FROM_ENCRYPTION_KEY (Kubernetes secret on the secondary cluster)."
  type        = string
  default     = null
}

variable "s3_recover_from_encryption_key_secret_key" {
  description = "Secret key referenced by S3_RECOVER_FROM_ENCRYPTION_KEY (usually 'ocs-storage-encryption-key')."
  type        = string
  default     = null
}

variable "s3_recover_from_endpoint_base" {
  description = "Value for S3_RECOVER_FROM_ENDPOINT_BASE. Required for OCI Object Storage S3-compatible API. Format: https://<namespace>.compat.objectstorage.<region>.oraclecloud.com"
  type        = string
  default     = null
}

variable "s3_recover_from_path_style_access" {
  description = "Value for S3_RECOVER_FROM_PATH_STYLE_ACCESS. Set to true for OCI Object Storage (uses path-style URLs, not virtual-hosted style)."
  type        = bool
  default     = true
}

variable "existing_s3_encryption_key" {
  description = "Optional S3/Object Storage encryption key reused by DR clusters (supplied from primary state when dr = 'standby')."
  type        = string
  default     = null
}

variable "dr_remote_state_bucket" {
  description = "OCI Object Storage bucket name for remote Terraform state (for DR standby to read primary state)"
  type        = string
  default     = ""
}

variable "dr_remote_state_namespace" {
  description = "OCI Object Storage namespace for remote Terraform state"
  type        = string
  default     = ""
}

variable "dr_remote_state_region" {
  description = "OCI region for remote Terraform state"
  type        = string
  default     = ""
}

variable "dr_remote_state_key" {
  description = "State file key/path for remote Terraform state"
  type        = string
  default     = "logscale-oci-oke.tfstate"
}

variable "dr_remote_state_profile" {
  description = "OCI CLI config file profile for remote state authentication"
  type        = string
  default     = ""
}

variable "extra_user_logscale_envvars" {
  type = list(object({
    name  = string,
    value = optional(string)
    valueFrom = optional(object({
      secretKeyRef = object({
        name = string
        key  = string
      })
    }))
  }))
  description = "Extra environment variables passed into the HumioCluster resource spec definition that will be used for all created logscale instances. Supports string values and kubernetes secret refs. Will override any values defined by default in the configuration."
  default     = []
}
