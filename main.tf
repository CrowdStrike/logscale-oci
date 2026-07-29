# LogScale OCI Reference Architecture
# Main Terraform configuration file

# Deploy oci-core networking infrastructure
module "oci-core" {
  source = "./modules/oci/core"

  # OCI configuration
  compartment_ocid = var.compartment_ocid
  cluster_name     = var.cluster_name

  # VCN Configuration
  vcn_cidr                     = var.vcn_cidr
  cluster_endpoint_subnet_cidr = var.cluster_endpoint_subnet_cidr
  lb_subnet_cidr               = var.lb_subnet_cidr
  pods_cidr                    = var.pods_cidr
  services_cidr                = var.services_cidr

  # Availability Domain and Subnet Mapping (Dynamic)
  ad_and_subnets = local.dynamic_ad_and_subnets

  # Endpoint Configuration
  endpoint_public_access = var.endpoint_public_access

  # Bastion Configuration (for security rules)
  provision_bastion         = var.provision_bastion
  bastion_client_allow_list = var.bastion_client_allow_list

  # Load Balancer access CIDRs (for HTTPS ingress)
  public_lb_cidrs = var.public_lb_cidrs

  # Kubernetes API endpoint access CIDRs (security hardening)
  control_plane_allowed_cidrs = var.control_plane_allowed_cidrs

  # Tagging
  common_tags    = merge(var.common_tags, { dr = var.dr })
  mandatory_tags = var.mandatory_tags

}

# Deploy oci-bastion service (optional)
module "oci-bastion" {
  count  = var.provision_bastion ? 1 : 0
  source = "./modules/oci/bastion"

  providers = {
    oci      = oci
    oci.home = oci.home
  }

  # General OCI parameters
  tenancy_ocid         = var.tenancy_ocid
  compartment_ocid     = var.compartment_ocid
  resource_name_prefix = local.resource_name_prefix

  # Network parameters - Using dedicated bastion subnet
  vcn_id           = module.oci-core.vcn_id
  target_subnet_id = module.oci-core.bastion_subnet_id

  # Enhanced bastion configuration with all worker node subnets
  node_pool_subnets = module.oci-core.node_pool_subnets

  # Bastion Service Configuration
  provision_bastion         = var.provision_bastion
  bastion_client_allow_list = var.bastion_client_allow_list
  max_session_ttl           = var.max_session_ttl
  enable_dns_proxy          = var.enable_dns_proxy

  # Tagging
  common_tags    = merge(var.common_tags, { dr = var.dr })
  mandatory_tags = var.mandatory_tags
  cluster_name   = var.cluster_name

  depends_on = [module.oci-core]
}

# Deploy object storage
module "oci-logscale-storage" {
  source = "./modules/oci/storage"

  providers = {
    oci      = oci
    oci.home = oci.home
  }

  # OCI configuration
  tenancy_ocid     = var.tenancy_ocid
  compartment_ocid = var.compartment_ocid
  region           = var.region

  # Storage configuration - uses the same user_ocid for S3-compatible API access
  user_ocid = var.user_ocid

  # Data retention
  data_retention_days      = var.data_retention_days
  archive_after_days       = var.archive_after_days
  temp_data_retention_days = var.temp_data_retention_days

  # Resource naming
  resource_name_prefix = local.resource_name_prefix

  # PAR expiration time
  par_expiration_time = var.par_expiration_time

  # Note: Storage module is independent of OKE - no dependency needed
  # depends_on = [module.oke]  # Removed to allow independent deployment
}


# Deploy OKE cluster
module "oke" {
  source = "./modules/oci/oke"

  providers = {
    oci      = oci
    oci.home = oci.home
  }

  # Basic configuration
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  cluster_type       = var.oke_cluster_type

  # OCI configuration
  tenancy_ocid     = var.tenancy_ocid #
  compartment_ocid = var.compartment_ocid
  user_ocid        = var.user_ocid
  user_fingerprint = var.user_fingerprint
  private_key_path = var.private_key_path
  region           = var.region

  # OCI Profile configuration
  oci_profile = local.oci_profile

  # SSH configuration
  ssh_public_key_path  = var.ssh_public_key_path
  ssh_private_key_path = var.ssh_private_key_path

  # Network configuration
  public_lb_cidrs = var.public_lb_cidrs
  ad_and_subnets  = local.dynamic_ad_and_subnets

  # Bastion plugin configuration for worker nodes
  enable_bastion_plugin   = var.enable_bastion_plugin
  create_bastion_sessions = var.create_bastion_sessions

  # Node configuration
  worker_image_id = var.worker_image_id

  # Resource naming
  resource_name_prefix = local.resource_name_prefix

  # Node group definitions
  node_group_definitions = local.node_group_definitions

  # LogScale cluster type
  logscale_cluster_type = var.logscale_cluster_type

  # IAM resource creation control
  create_iam_resources = true

  # DR mode
  dr = var.dr

  # Network resources from oci-core module
  vcn_id                     = module.oci-core.vcn_id
  cluster_endpoint_subnet_id = module.oci-core.cluster_endpoint_subnet_id
  lb_subnet_id               = module.oci-core.lb_subnet_id
  pod_subnet_id              = module.oci-core.pod_subnet_id
  node_pool_subnets          = module.oci-core.node_pool_subnets
  worker_nsg_id              = module.oci-core.worker_nsg_id
  api_endpoint_nsg_id        = module.oci-core.api_endpoint_nsg_id
  fault_domains              = module.oci-core.fault_domains

  # Endpoint configuration
  endpoint_public_access = var.endpoint_public_access

  # Kubeconfig configuration for bastion tunnel support
  provision_bastion   = var.provision_bastion
  kubernetes_api_host = var.kubernetes_api_host

  # LogScale ingest DNS FAILOVER configuration moved to root level
  # to avoid circular dependencies with primary_ingest_lb_ip

  depends_on = [
    data.oci_identity_availability_domains.ads,
    module.oci-core
  ]
}

# Pre-install module for OCI - creates namespace, external-dns, and OCI storage encryption secret
module "pre-install" {

  providers = {
    kubernetes = kubernetes
    random     = random
    helm       = helm
  }

  source = "./modules/kubernetes/pre-install"

  cluster_name = var.cluster_name

  logscale_namespace = var.logscale_namespace

  storage_bucket_name      = module.oci-logscale-storage.bucket_name
  storage_bucket_namespace = module.oci-logscale-storage.bucket_namespace

  # DR: Pass primary encryption key for standby clusters (from remote state)
  existing_storage_encryption_key = local.remote_primary_encryption_key

  # External DNS configuration for automatic DNS management (optional)
  external_dns_enabled        = var.external_dns_enabled
  external_dns_chart_version  = var.external_dns_chart_version
  external_dns_repository     = var.external_dns_repository
  external_dns_domain_filters = var.external_dns_domain_filters

  # Cluster-level DNS CNAME record (cluster_name.dns_zone_name) pointing at logscale_public_fqdn
  dns_zone_name        = var.dns_zone_name
  logscale_public_fqdn = var.logscale_public_fqdn

  dr = var.dr

  # OCI credentials for external-dns authentication
  oci_region          = var.region
  tenancy_ocid        = var.tenancy_ocid
  user_ocid           = var.user_ocid
  user_fingerprint    = var.user_fingerprint
  private_key_content = file(var.private_key_path)
  compartment_ocid    = var.compartment_ocid

  # LoadBalancer Service configuration - moved to module.loadbalancer (post-logscale)
}

module "logscale" {
  source = "git::https://github.com/CrowdStrike/logscale-kubernetes.git?ref=main"

  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  k8s_cluster_name    = var.cluster_name
  kubeconfig_path     = module.oke.kubeconfig_path
  k8s_cluster_context = local.oci_kubeconfig_context

  topo_lvm_chart_version       = var.topo_lvm_chart_version
  topo_lvm_controller_replicas = var.topo_lvm_controller_replicas

  # Gateway API disabled - using OCI LoadBalancer Service in pre-install for external access
  deploy_gateway_api  = false
  gateway_api_version = null

  # OCI/OKE requires extra host paths for lvmd to discover LVM volume groups.
  # LVM metadata and lock files reside in /run/lock/lvm and /etc/lvm on Oracle Linux;
  # without these mounts the lvmd container cannot find VGs created by lvm-setup.
  lvm_extra_host_paths = [
    {
      name       = "run-lock-lvm"
      host_path  = "/run/lock/lvm"
      mount_path = "/run/lock/lvm"
      type       = "DirectoryOrCreate"
    },
    {
      name       = "etc-lvm"
      host_path  = "/etc/lvm"
      mount_path = "/etc/lvm"
      type       = "DirectoryOrCreate"
    },
  ]

  # Kafka - OCI uses Strimzi (provision_kafka_servers)
  byo_kafka_connection_string    = var.byo_kafka_connection_string
  provision_kafka_servers        = var.provision_kafka_servers
  strimzi_operator_version       = var.strimzi_operator_version
  strimzi_operator_chart_version = var.strimzi_operator_chart_version

  # cert manager
  cm_version                      = var.cm_version
  cert_issuer_email               = var.cert_issuer_email
  use_own_certificate_for_ingress = var.use_own_certificate_for_ingress

  # logscale
  logscale_cluster_size = var.logscale_cluster_size
  logscale_cluster_type = var.logscale_cluster_type
  logscale_license      = var.logscale_license
  logscale_public_fqdn  = local.effective_logscale_public_fqdn
  k8s_namespace_prefix  = var.logscale_namespace
  # OCI pre-install module creates the namespace, skip creation in logscale-prereqs
  existing_logscale_namespace  = true
  logscale_image_version       = var.logscale_image_version
  image_pull_secret            = var.image_pull_secret
  humio_operator_chart_version = var.humio_operator_chart_version
  humio_operator_version       = var.humio_operator_version
  humio_operator_extra_values  = var.humio_operator_extra_values

  node_group_definitions = local.node_group_definitions

  dr = var.dr

  # Two-phase DR promotion: controls when to switch to dedicated pool routing
  dr_use_dedicated_routing = var.dr_use_dedicated_routing

  # Avoid duplicate issuer creation when OCI repo manages DNS-01 issuer via webhook
  # Skip HTTP-01 issuer when DNS-01 is enabled (for any cluster, not just standby)
  skip_cluster_issuer = local.enable_cert_manager_dns01

  # DR: Pass primary encryption key for standby clusters (from remote state)
  primary_encryption_key_value = local.remote_primary_encryption_key

  # OCI Object Storage configuration
  user_logscale_envvars = concat(
    # Base environment variables (all clusters)
    [
      {
        "name"      = "S3_STORAGE_BUCKET"
        "value"     = module.oci-logscale-storage.bucket_name
        "valueFrom" = null
      },
      {
        "name"      = "S3_STORAGE_REGION"
        "value"     = var.region
        "valueFrom" = null
      },
      {
        "name"      = "S3_STORAGE_ENDPOINT_BASE"
        "value"     = "https://${module.oci-logscale-storage.bucket_namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
        "valueFrom" = null
      },
      {
        "name"      = "S3_STORAGE_PATH_STYLE_ACCESS"
        "value"     = "true"
        "valueFrom" = null
      },
      {
        "name"      = "AWS_ACCESS_KEY_ID"
        "value"     = module.oci-logscale-storage.s3_access_key_id
        "valueFrom" = null
      },
      {
        "name"      = "AWS_SECRET_ACCESS_KEY"
        "value"     = module.oci-logscale-storage.s3_secret_access_key
        "valueFrom" = null
      },
      {
        "name"  = "S3_STORAGE_ENCRYPTION_KEY"
        "value" = null
        "valueFrom" = {
          "secretKeyRef" = {
            "key"  = module.pre-install.oci_storage_encryption_key_secret_key
            "name" = module.pre-install.oci_storage_encryption_key_secret_name
          }
        }
      },
      {
        "name"      = "S3_STORAGE_PREFERRED_COPY_SOURCE"
        "value"     = var.dr == "standby" ? "true" : "false"
        "valueFrom" = null
      },
    ],
    # DR recovery, active, and common environment variables
    local.logscale_dr_envvars,
    # User-provided extra environment variables
    var.extra_user_logscale_envvars
  )

  # DR: Null out nodePools for standby to avoid humio-operator reconciliation loop
  extra_humio_cluster_spec = var.dr == "standby" ? { nodePools = null } : {}

  # DR: Add global failover hostname to ingress
  ingress_extra_hostnames = var.dr != "" && var.global_logscale_hostname != "" && var.dns_zone_name != "" ? [
    "${var.global_logscale_hostname}.${var.dns_zone_name}"
  ] : []

}

# Global DNS failover (optional - primary only, requires dr to be set)
module "global-dns" {
  count  = var.manage_global_dns && var.dr != "" ? 1 : 0
  source = "./modules/oci/global-dns"

  compartment_ocid            = var.compartment_ocid
  cluster_name                = var.cluster_name
  logscale_public_fqdn        = var.logscale_public_fqdn
  create_dns_zone             = var.create_global_dns_zone
  zone_id                     = var.global_dns_zone_id
  zone_name                   = var.dns_zone_name
  dns_record_ttl              = var.global_dns_record_ttl
  manage_global_dns           = var.manage_global_dns
  global_logscale_hostname    = var.global_logscale_hostname
  primary_logscale_hostname   = var.primary_logscale_hostname
  secondary_logscale_hostname = var.secondary_logscale_hostname
  primary_ingest_lb_ip        = local.final_primary_ingest_lb_ip
  secondary_ingest_lb_ip      = local.final_secondary_ingest_lb_ip
  # Mirror AWS global DNS health check behavior
  health_check_path = "/api/v1/status"
  health_check_port = 443
  # Don't specify vantage_point_names - let OCI auto-manage with existing config (azr-dub, goo-cbf, aws-icn)
  dr             = var.dr
  common_tags    = merge(var.common_tags, { dr = var.dr })
  mandatory_tags = var.mandatory_tags

  # Control whether steering policy uses external health checks or function-controlled failover
  # When false: steering policy has no health check attached, failover is controlled by DR function
  # setting is_disabled=true on primary answer. This works with restricted firewalls.
  use_external_health_check = var.use_external_health_check

  providers = {
    oci = oci
  }
}

# DR failover automation (standby only, requires dr="standby")
module "dr-failover-function" {
  count = var.dr_failover_function_enabled && var.dr == "standby" ? 1 : 0

  source = "./modules/oci/dr-failover-function"

  providers = {
    oci      = oci
    oci.home = oci.home
  }

  enabled                               = true
  compartment_ocid                      = var.compartment_ocid
  root_tenancy_ocid                     = var.root_tenancy_ocid
  cluster_id                            = module.oke.cluster_id
  cluster_region                        = var.region
  cluster_namespace                     = var.logscale_namespace
  operator_target_replicas              = var.dr_failover_function_target_node_count
  primary_health_check_id               = local.final_primary_health_check_id
  secondary_health_check_id             = local.final_secondary_health_check_id
  create_primary_health_check_monitor   = var.dr_failover_function_create_primary_health_check_monitor
  primary_ingest_lb_ip                  = local.final_primary_ingest_lb_ip
  primary_health_check_host_header      = (trimspace(var.global_logscale_hostname) != "" && trimspace(var.dns_zone_name) != "") ? "${var.global_logscale_hostname}.${var.dns_zone_name}" : ""
  primary_health_check_path             = var.dr_failover_function_primary_health_check_path
  primary_health_check_port             = var.dr_failover_function_primary_health_check_port
  primary_health_check_interval_seconds = var.dr_failover_function_primary_health_check_interval_seconds
  primary_health_check_timeout_seconds  = var.dr_failover_function_primary_health_check_timeout_seconds
  function_timeout_seconds              = var.dr_failover_function_timeout
  function_memory_mb                    = var.dr_failover_function_memory_mb
  log_retention_days                    = var.dr_failover_function_log_retention_days
  skip_secondary_health_check           = var.dr_failover_function_skip_secondary_health_check
  pre_failover_failure_seconds          = var.dr_failover_function_pre_failover_failure_seconds
  alarm_pending_duration                = var.dr_failover_function_alarm_pending_duration
  alarm_repeat_notification_duration    = var.dr_failover_function_alarm_repeat_notification_duration
  absent_detection_period               = var.dr_failover_function_absent_detection_period
  steering_policy_id                    = local.final_steering_policy_id
  steering_policy_attachment_id         = local.final_steering_policy_attachment_id
  secondary_pool_name                   = "secondary"
  ingress_namespace                     = var.logscale_namespace
  ingress_service_name                  = "${var.cluster_name}-lb"
  certificate_secret_name               = var.dr == "standby" ? (var.use_own_certificate_for_ingress ? "${var.cluster_name}-tls-certificate" : var.logscale_public_fqdn) : ""
  certificate_secret_namespace          = var.logscale_namespace
  cert_wait_timeout_seconds             = 120
  name_prefix                           = "${var.cluster_name}-dr-failover"
  subnets                               = length(var.function_subnet_ids) > 0 ? var.function_subnet_ids : [for k in sort(keys(module.oci-core.node_pool_subnets)) : module.oci-core.node_pool_subnets[k].id]
  vcn_id                                = module.oci-core.vcn_id
  common_tags                           = merge(var.common_tags, { dr = var.dr })
  mandatory_tags                        = var.mandatory_tags

  # OCIR image build configuration (namespace and username fetched automatically)
  auto_build_image = var.dr_failover_function_auto_build_image
  ocir_user_ocid   = var.user_ocid

  # LB backend health monitoring (recommended)
  use_lb_health_metrics = var.dr_failover_function_use_lb_health_metrics
  primary_lb_ocid       = local.final_primary_lb_ocid
  lb_backend_set_name   = var.dr_failover_function_lb_backend_set_name

  # TLS secret cleanup (prevents CA certificate mismatch on failover)
  humiocluster_name = module.logscale.cluster_name_prefix

  # Pod readiness wait (ensures pods are ready before DNS update)
  pod_ready_timeout_seconds = var.dr_failover_function_pod_ready_timeout
  pod_ready_target_count    = var.dr_failover_function_pod_ready_count

  # NSG configuration for function to access OKE API endpoint
  worker_nsg_id       = module.oci-core.worker_nsg_id
  api_endpoint_nsg_id = module.oci-core.api_endpoint_nsg_id
}

# Native Terraform module for cert-manager OCI DNS webhook (no external Helm dependency)
module "cert-manager-oci-webhook" {
  # Deploy DNS-01 webhook (and ClusterIssuer) when enabled and needed.
  # This is intentionally decoupled from DR so DNS-01 can be used on non-DR clusters.
  count  = local.enable_cert_manager_dns01 ? 1 : 0
  source = "./modules/kubernetes/cert-manager-oci-webhook"

  enabled             = true
  namespace           = local.cert_manager_namespace
  release_name        = "cert-manager-webhook-oci"
  group_name          = var.cert_dns01_group_name
  solver_name         = var.cert_dns01_solver_name
  profile_secret_name = var.cert_dns01_secret_name
  image_repository    = var.cert_dns01_webhook_image_repo
  image_tag           = var.cert_dns01_webhook_image_tag

  tenancy_ocid           = var.tenancy_ocid
  user_ocid              = var.user_ocid
  fingerprint            = var.user_fingerprint
  region                 = var.region
  private_key            = file(var.private_key_path)
  private_key_passphrase = ""
  compartment_ocid       = var.compartment_ocid

  cert_manager_namespace            = local.cert_manager_namespace
  cert_manager_service_account_name = "cert-manager"

  cert_issuer_name        = "letsencrypt-cluster-issuer"
  cert_issuer_email       = var.cert_issuer_email
  cert_issuer_private_key = "letsencrypt-cluster-issuer-key"
  cert_ca_server          = "https://acme-v02.api.letsencrypt.org/directory"

  # kubectl context for local-exec commands (wait for certificate Ready status)
  # Uses the context from the Terraform-generated kubeconfig
  kubectl_context = var.kubectl_context

  # The webhook depends on module.logscale because it needs:
  # 1. cert-manager to be installed (from logscale-prereqs) to process PKI certificates
  # 2. The cert-manager namespace to exist
  # Note: The Ingress in logscale references this ClusterIssuer before it exists,
  # but cert-manager handles this gracefully by retrying until the issuer is available.
  depends_on = [module.logscale]
}

# OCI LoadBalancer + Let's Encrypt Certificate (runs after cert-manager and ClusterIssuer exist)
module "loadbalancer" {
  source = "./modules/kubernetes/loadbalancer"

  providers = {
    kubernetes = kubernetes
  }

  cluster_name         = var.cluster_name
  logscale_namespace   = var.logscale_namespace
  logscale_public_fqdn = var.logscale_public_fqdn
  lb_subnet_id         = module.oci-core.lb_subnet_id
  lb_nsg_id            = module.oci-core.lb_nsg_id

  depends_on = [module.cert-manager-oci-webhook, module.pre-install]
}
