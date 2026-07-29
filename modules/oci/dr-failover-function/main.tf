locals {
  has_primary_hc_input = var.primary_health_check_id != null && trimspace(var.primary_health_check_id) != ""
  # Only create external health check monitor when NOT using LB health metrics
  # When use_lb_health_metrics=true, we monitor LB backend health instead
  can_create_primary_hc = (
    var.create_primary_health_check_monitor
    && !var.use_lb_health_metrics
    && trimspace(var.primary_ingest_lb_ip) != ""
    && trimspace(var.primary_health_check_host_header) != ""
  )

  # Module is enabled if using LB health metrics OR has valid health check config
  enabled = var.enabled && (var.use_lb_health_metrics || local.has_primary_hc_input || local.can_create_primary_hc)

  name_prefix               = trimspace(var.name_prefix)
  secondary_hc_id           = var.secondary_health_check_id != null ? var.secondary_health_check_id : ""
  function_application_name = "${local.name_prefix}-dr-failover-app"
  function_name             = "${local.name_prefix}-dr-failover-handler"

  # OCIR image configuration
  # Format: <region>.ocir.io/<namespace>/<repo>:<tag>
  # Login username format: <namespace>/<username>
  # Reference: oci-idcs-monitoring uses ${local.namespace}/${var.ocir_user_name}
  ocir_registry   = "${var.cluster_region}.ocir.io"
  ocir_tenancy_ns = data.oci_objectstorage_namespace.tenancy.namespace
  ocir_image_name = "${local.ocir_registry}/${local.ocir_tenancy_ns}/${var.ocir_repo_name}"

  # OCIR login username: <namespace>/<username>
  # Auto-derived from user OCID — no manual input needed
  ocir_login_username = "${local.ocir_tenancy_ns}/${data.oci_identity_user.ocir.name}"

  # Source directory for the function
  src_dir = "${path.module}/src"

  # Generate a content-based image tag using the source hash
  # This ensures the function resource is updated when the source code changes
  # The tag format is: v<short-hash> (e.g., v-abc123def)
  # When auto_build_image is false, fall back to the user-specified tag
  source_content_hash = var.auto_build_image && local.enabled ? substr(data.archive_file.function_package[0].output_sha256, 0, 12) : ""
  ocir_image_tag      = var.auto_build_image && local.enabled ? "v-${local.source_content_hash}" : var.function_image_tag
  ocir_image_uri      = "${local.ocir_image_name}:${local.ocir_image_tag}"

  # Effective PRIMARY health check ID used by alarm + function:
  # - Prefer a monitor created in this region (recommended for cross-region DR),
  # - otherwise fall back to the caller-provided monitor ID (typically from primary state).
  effective_primary_health_check_id = (local.enabled && local.can_create_primary_hc) ? oci_health_checks_http_monitor.primary_for_failover[0].id : var.primary_health_check_id

  function_config = {
    CLUSTER_ID                    = var.cluster_id
    CLUSTER_REGION                = var.cluster_region
    CLUSTER_NAMESPACE             = var.cluster_namespace
    TARGET_OPERATOR_REPLICAS      = tostring(var.operator_target_replicas)
    PRIMARY_HEALTH_CHECK_ID       = local.effective_primary_health_check_id
    SECONDARY_HEALTH_CHECK_ID     = local.secondary_hc_id
    SKIP_SECONDARY_HEALTH_CHECK   = tostring(var.skip_secondary_health_check)
    COMPARTMENT_ID                = var.compartment_ocid
    PRE_FAILOVER_FAILURE_SECONDS  = tostring(var.pre_failover_failure_seconds)
    FAILOVER_COOLDOWN_SECONDS     = tostring(var.failover_cooldown_seconds)
    MAX_RETRIES                   = tostring(var.max_retries)
    BASE_DELAY_SECONDS            = tostring(var.base_delay_seconds)
    MAX_DELAY_SECONDS             = tostring(var.max_delay_seconds)
    LOG_LEVEL                     = "INFO"
    STEERING_POLICY_ID            = var.steering_policy_id
    STEERING_POLICY_ATTACHMENT_ID = var.steering_policy_attachment_id
    SECONDARY_POOL_NAME           = var.secondary_pool_name
    INGRESS_NAMESPACE             = var.ingress_namespace
    INGRESS_SERVICE_NAME          = var.ingress_service_name
    CERT_SECRET_NAME              = var.certificate_secret_name
    CERT_SECRET_NAMESPACE         = var.certificate_secret_namespace
    CERT_WAIT_TIMEOUT_SECONDS     = tostring(var.cert_wait_timeout_seconds)
    COOLDOWN_PERSISTENCE_ENABLED  = tostring(var.persist_failover_cooldown)
    COOLDOWN_ANNOTATION_KEY       = var.cooldown_annotation_key
    # LB backend health monitoring
    USE_LB_HEALTH_METRICS = tostring(var.use_lb_health_metrics)
    PRIMARY_LB_OCID       = var.primary_lb_ocid
    LB_BACKEND_SET_NAME   = var.lb_backend_set_name
    # TLS secret cleanup (prevents CA certificate mismatch on failover)
    HUMIOCLUSTER_NAME = var.humiocluster_name
    # Pod readiness wait (ensures pods are ready before DNS update)
    POD_READY_TIMEOUT_SECONDS = tostring(var.pod_ready_timeout_seconds)
    POD_READY_TARGET_COUNT    = tostring(var.pod_ready_target_count)
  }
}

data "oci_identity_regions" "current" {}

# Get the tenancy's Object Storage namespace (required for OCIR)
data "oci_objectstorage_namespace" "tenancy" {
  compartment_id = var.root_tenancy_ocid
}

# Look up username from user OCID for OCIR login
data "oci_identity_user" "ocir" {
  user_id = var.ocir_user_ocid
}

# =============================================================================
# OCIR Authentication Token (Terraform-managed)
# =============================================================================
# Create an auth token for OCIR Docker registry authentication.
# This token is managed by Terraform and automatically used for docker push.
# Note: OCI users are limited to 2 auth tokens. This resource will fail if the
# user already has 2 tokens - in that case, delete an unused token first.
resource "oci_identity_auth_token" "ocir" {
  count       = local.enabled && var.auto_build_image ? 1 : 0
  provider    = oci.home # Auth tokens must be created in home region
  user_id     = var.ocir_user_ocid
  description = "OCIR auth token for ${local.name_prefix} function (Terraform-managed)"

  # Lifecycle: create new token before destroying old one during updates
  lifecycle {
    create_before_destroy = true
  }
}

# Wait for auth token to propagate through OCI IAM before using it for OCIR login.
# OCI auth tokens require propagation time across OCI's distributed IAM infrastructure
# before they can be used for OCIR authentication. Without this delay, docker login
# fails with "Unauthorized" even though the token was successfully created and is ACTIVE.
# This is separate from the docker logout fix (which clears stale local credentials);
# both fixes are needed for reliable OCIR authentication during terraform apply.
resource "time_sleep" "wait_for_auth_token" {
  count = local.enabled && var.auto_build_image ? 1 : 0

  depends_on      = [oci_identity_auth_token.ocir]
  create_duration = "90s"

  triggers = {
    # Re-wait if auth token changes
    auth_token_id = oci_identity_auth_token.ocir[0].id
  }
}

# Notifications Topic for health check alarms
resource "oci_ons_notification_topic" "failover" {
  count          = local.enabled ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = "${local.name_prefix}-topic"
  description    = "Topic for LogScale DR failover notifications"

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "NotificationTopic"
    "Component"    = "LogScaleDRFailover"
  })
}

# Persist failover cooldown state in Object Storage (survives function cold starts)
# Dedicated PRIMARY monitor for DR automation (created in the same region as the alarm/function).
# This avoids cross-region limitations for Health Checks probe results/metrics retrieval and
# keeps DR automation operational even if the primary region experiences an outage.
#
# NOTE: This resource is NOT created when use_lb_health_metrics=true (Option B).
# When using LB backend health metrics, we don't need external health checks because
# they would be blocked by the public_lb_cidrs security list anyway.
resource "oci_health_checks_http_monitor" "primary_for_failover" {
  count          = local.enabled && local.can_create_primary_hc ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${local.name_prefix}-primary-dr-failover-https-monitor"

  protocol = "HTTPS"
  targets  = [var.primary_ingest_lb_ip]
  method   = "GET"
  path     = var.primary_health_check_path
  port     = var.primary_health_check_port

  # Host header required for HTTPS SNI when probing an IP target
  headers = {
    "Host" = var.primary_health_check_host_header
  }

  interval_in_seconds = var.primary_health_check_interval_seconds
  # Timeout must be <= interval; use min() to prevent validation errors when interval is reduced for testing
  timeout_in_seconds = min(var.primary_health_check_timeout_seconds, var.primary_health_check_interval_seconds)
  is_enabled         = true

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "HealthCheckMonitor"
    "Component"    = "LogScaleDRFailoverPrimaryMonitor"
  })

  lifecycle {
    ignore_changes = [vantage_point_names]

    precondition {
      condition     = trimspace(var.primary_ingest_lb_ip) != ""
      error_message = "primary_ingest_lb_ip must be set when create_primary_health_check_monitor=true."
    }

    precondition {
      condition     = trimspace(var.primary_health_check_host_header) != ""
      error_message = "primary_health_check_host_header must be set when create_primary_health_check_monitor=true."
    }
  }
}

# Monitoring Alarm: triggers when primary LogScale is unhealthy
#
# Two monitoring modes are supported:
#
# 1. Classic LB Backend Health (RECOMMENDED - use_lb_health_metrics=true):
#    - Uses oci_lbaas namespace with unhealthyBackendServers metric
#    - Monitors actual LB backend health from within OCI infrastructure
#    - Not affected by security list restrictions on external traffic
#    - Triggers when ANY backend server becomes unhealthy
#
# 2. External Health Check (legacy - use_lb_health_metrics=false):
#    - Uses oci_healthchecks namespace with HTTP.isHealthy metric
#    - Probes from external vantage points (AWS, Azure, GCP)
#    - May be blocked by public_lb_cidrs security list
#    - Use groupBy(resourceId) for alignment and absence detection
#
resource "oci_monitoring_alarm" "primary_unhealthy" {
  count                 = local.enabled ? 1 : 0
  compartment_id        = var.compartment_ocid
  display_name          = "${local.name_prefix}-primary-unhealthy"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid

  # Select namespace based on monitoring mode:
  # - Classic LB: oci_lbaas
  # - External health check: oci_healthchecks
  namespace = var.use_lb_health_metrics ? "oci_lbaas" : "oci_healthchecks"

  # Query differs based on monitoring mode:
  # - Classic LB mode: Zero healthy backends OR metrics absent (covers both full failure and regional outage)
  #   Formula: (BackendServers - UnHealthyBackendServers) < 1 means zero healthy backends.
  #   This is scale-independent — works regardless of node pool size changes.
  # - External mode: HTTP.isHealthy < 1 or absent means external probes are failing
  query = var.use_lb_health_metrics ? (
    # Classic LB: healthy backends == 0 (complete failure) OR metrics absent (regional outage)
    "(BackendServers[1m]{resourceId = \"${var.primary_lb_ocid}\", backendSetName = \"${var.lb_backend_set_name}\"}.min() - UnHealthyBackendServers[1m]{resourceId = \"${var.primary_lb_ocid}\", backendSetName = \"${var.lb_backend_set_name}\"}.max()) < 1 || UnHealthyBackendServers[1m]{resourceId = \"${var.primary_lb_ocid}\", backendSetName = \"${var.lb_backend_set_name}\"}.absent(${var.absent_detection_period})"
    ) : (
    "HTTP.isHealthy[1m]{resourceId = \"${local.effective_primary_health_check_id}\"}.groupBy(resourceId).absent(${var.absent_detection_period}) || HTTP.isHealthy[1m]{resourceId = \"${local.effective_primary_health_check_id}\"}.groupBy(resourceId).min() < 1"
  )

  severity = "CRITICAL"

  destinations = [oci_ons_notification_topic.failover[0].id]

  pending_duration             = var.alarm_pending_duration
  repeat_notification_duration = var.alarm_repeat_notification_duration
  resolution                   = "1m"

  body = var.use_lb_health_metrics ? (
    "Primary LogScale LB has zero healthy backends or metrics absent - triggering DR failover scaling"
    ) : (
    "Primary LogScale health check is unhealthy or disabled - triggering DR failover scaling"
  )

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "MonitoringAlarm"
    "Component"    = "LogScaleDRFailover"
  })
}

# Function Application
resource "oci_functions_application" "failover" {
  count          = local.enabled ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = local.function_application_name
  subnet_ids     = var.subnets

  # Attach to worker NSG for network access to OKE API endpoint
  # The function runs in the same subnets as worker nodes and needs
  # egress access to port 6443 on the API endpoint NSG
  network_security_group_ids = [var.worker_nsg_id]

  config = local.function_config

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "FunctionsApplication"
    "Component"    = "LogScaleDRFailover"
  })
}

# Package the function code
data "archive_file" "function_package" {
  count = local.enabled ? 1 : 0

  type             = "zip"
  source_dir       = "${path.module}/src"
  output_path      = "${path.module}/dr-failover-handler.zip"
  output_file_mode = "0644"
}

# =============================================================================
# OCIR Image Build and Push (Terraform-managed)
# =============================================================================

# Create OCIR repository for the function image
resource "oci_artifacts_container_repository" "function" {
  count = local.enabled ? 1 : 0

  compartment_id = var.compartment_ocid
  display_name   = var.ocir_repo_name
  is_public      = false
  is_immutable   = false

  readme {
    content = "LogScale DR Failover Function container image repository"
    format  = "text/plain"
  }
}

# Build and push Docker image to OCIR
# This uses null_resource with local-exec to build and push the image
# The image is rebuilt when source files change (tracked via archive hash)
# Authentication uses the Terraform-managed auth token (oci_identity_auth_token.ocir)
#
# IMPORTANT: The provisioner outputs the image digest to a local file which is then
# read by a data source. This ensures Terraform gets the ACTUAL digest of the pushed
# image, not a stale value from OCIR's API cache.
resource "null_resource" "docker_build_push" {
  count = local.enabled && var.auto_build_image ? 1 : 0

  # Rebuild when source files change or auth token changes
  triggers = {
    source_hash     = data.archive_file.function_package[0].output_sha256
    dockerfile_hash = filesha256("${local.src_dir}/Dockerfile")
    image_uri       = local.ocir_image_uri
    repo_created    = oci_artifacts_container_repository.function[0].id
    auth_token_id   = oci_identity_auth_token.ocir[0].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e

      echo "=== Building OCI Function Docker Image ==="
      echo "Image: ${local.ocir_image_uri}"
      echo "Source: ${local.src_dir}"

      # Build the Docker image for linux/amd64 (required for OCI Functions)
      # Using --provenance=false and --sbom=false to create a simple single-arch image
      # without attestation manifests that OCI Functions doesn't support
      docker build \
        --platform linux/amd64 \
        --provenance=false \
        --sbom=false \
        -t "${local.ocir_image_uri}" \
        "${local.src_dir}"

      echo "=== Logging into OCIR ==="
      echo "Using Terraform-managed auth token for OCIR authentication"
      echo "DEBUG: OCIR_AUTH_TOKEN length: $${#OCIR_AUTH_TOKEN}"
      if [ -z "$OCIR_AUTH_TOKEN" ]; then
        echo "ERROR: OCIR_AUTH_TOKEN is empty! Token was not passed to provisioner."
        exit 1
      fi

      # Clear any stale cached Docker credentials for OCIR
      # This is critical when destroy/apply cycles create new auth tokens -
      # Docker may cache the old (now-invalid) credentials and reject the new token
      echo "Clearing any cached OCIR credentials..."
      docker logout "${local.ocir_registry}" 2>/dev/null || true

      # Login to OCIR using format: <namespace>/<username>
      echo "Logging in as: ${local.ocir_login_username}"
      echo "$OCIR_AUTH_TOKEN" | docker login "${local.ocir_registry}" \
        -u "${local.ocir_login_username}" \
        --password-stdin

      echo "=== Pushing image to OCIR ==="
      docker push "${local.ocir_image_uri}"

      # Extract and save the image digest for Terraform to use
      # This ensures we get the ACTUAL digest of the pushed image
      IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${local.ocir_image_uri}" 2>/dev/null | cut -d'@' -f2 || echo "")
      if [ -z "$IMAGE_DIGEST" ]; then
        # Fallback: get digest from OCIR manifest
        IMAGE_DIGEST=$(docker manifest inspect "${local.ocir_image_uri}" 2>/dev/null | jq -r '.config.digest // .digest // empty' || echo "")
      fi

      echo "=== Image build/push complete ==="
      echo "Image URI: ${local.ocir_image_uri}"
      echo "Image Digest: $IMAGE_DIGEST"

      # Write digest to file for Terraform to read
      echo "$IMAGE_DIGEST" > "${path.module}/.image_digest"
    EOT

    environment = {
      OCIR_AUTH_TOKEN = oci_identity_auth_token.ocir[0].token
    }
  }

  depends_on = [
    oci_artifacts_container_repository.function,
    time_sleep.wait_for_auth_token,
    data.archive_file.function_package
  ]
}

# Read the image digest from local file written by docker_build_push
# This is more reliable than querying OCIR API which may have stale data
# Note: This file must exist before first terraform apply. Create it with:
# echo "" > modules/oci/dr-failover-function/.image_digest
data "local_file" "image_digest" {
  count    = local.enabled && var.auto_build_image && fileexists("${path.module}/.image_digest") ? 1 : 0
  filename = "${path.module}/.image_digest"

  depends_on = [null_resource.docker_build_push]
}

# Look up the specific image by version tag to get its digest (fallback)
# Used when local file doesn't exist yet or is empty
data "oci_artifacts_container_images" "function" {
  count          = local.enabled && var.auto_build_image ? 1 : 0
  compartment_id = var.compartment_ocid
  repository_id  = oci_artifacts_container_repository.function[0].id
  version        = local.ocir_image_tag

  depends_on = [null_resource.docker_build_push]
}

# Local to extract the image digest
locals {
  # Prefer digest from local file (written by docker push), fall back to OCIR API
  # The local file contains the actual digest of the image we just pushed
  digest_from_file = (
    local.enabled && var.auto_build_image &&
    length(data.local_file.image_digest) > 0
  ) ? trimspace(data.local_file.image_digest[0].content) : ""

  digest_from_ocir = (
    local.enabled && var.auto_build_image &&
    length(data.oci_artifacts_container_images.function) > 0 &&
    length(data.oci_artifacts_container_images.function[0].container_image_collection) > 0 &&
    length(data.oci_artifacts_container_images.function[0].container_image_collection[0].items) > 0
  ) ? data.oci_artifacts_container_images.function[0].container_image_collection[0].items[0].digest : ""

  # Use file-based digest if available and valid, otherwise fall back to OCIR
  pushed_image_digest = local.digest_from_file != "" ? local.digest_from_file : (local.digest_from_ocir != "" ? local.digest_from_ocir : null)
}

# Dynamic Group for Function to access OKE and health checks
resource "oci_identity_dynamic_group" "function" {
  count    = local.enabled ? 1 : 0
  provider = oci.home # Dynamic groups must be created in home region

  compartment_id = var.root_tenancy_ocid # Dynamic groups must be created in tenancy root
  name           = "${local.name_prefix}-function-dyn-group"
  description    = "Dynamic group for LogScale DR failover function"

  matching_rule = "ALL {resource.type = 'fnfunc', resource.compartment.id = '${var.compartment_ocid}'}"

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "DynamicGroup"
    "Component"    = "LogScaleDRFailover"
  })
}

# Policy for function to access required resources
resource "oci_identity_policy" "function_access" {
  count    = local.enabled ? 1 : 0
  provider = oci.home # Policies should also be created in home region

  compartment_id = var.compartment_ocid
  name           = "${local.name_prefix}-function-policy"
  description    = "Policy for LogScale DR failover function access"

  statements = [
    # OKE cluster access - required for generating kubeconfig and patching deployments
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to manage cluster-family in compartment id ${var.compartment_ocid}",

    # Health check access - required for checking primary/secondary health status
    # and (during failover) updating the DNS steering policy HTTP monitor targets
    # Using health-check-family aggregate which includes:
    # - health-check-monitor (for get_http_monitor API)
    # - health-check-results (for list_http_probe_results API - requires HEALTH_CHECK_RESULTS_INSPECT)
    # - on-demand-probe, vantage-points
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to manage health-check-family in compartment id ${var.compartment_ocid}",

    # Monitoring metrics access - required for pre-failover validation (consecutive failure duration)
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to read metrics in compartment id ${var.compartment_ocid}",

    # ONS topic access - required for receiving alarm notifications
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use ons-topics in compartment id ${var.compartment_ocid}",

    # Logging access - required for function logging
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use log-content in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use log-groups in compartment id ${var.compartment_ocid}"

    # DNS steering policy update during failover
    , "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to manage dns-steering-policies in compartment id ${var.compartment_ocid}"
    , "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to manage dns in compartment id ${var.compartment_ocid}"
  ]

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "Policy"
    "Component"    = "LogScaleDRFailover"
  })
}

# Policy for Functions service to access OCIR (must be at tenancy level)
resource "oci_identity_policy" "functions_service_access" {
  count    = local.enabled ? 1 : 0
  provider = oci.home

  compartment_id = var.root_tenancy_ocid
  name           = "${local.name_prefix}-functions-service-policy"
  description    = "Policy for Functions service to access container registry"

  statements = [
    "Allow service FaaS to read repos in tenancy"
  ]

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "Policy"
    "Component"    = "LogScaleDRFailover"
  })
}

# Policy for ONS to invoke the function (required for alarm -> ONS -> function flow)
# This allows the ONS subscription to trigger the function when alarm notifications are published
resource "oci_identity_policy" "ons_invoke_function" {
  count    = local.enabled ? 1 : 0
  provider = oci.home

  compartment_id = var.compartment_ocid
  name           = "${local.name_prefix}-ons-invoke-function-policy"
  description    = "Policy for ONS to invoke the DR failover function"

  statements = [
    # Allow ONS subscriptions to invoke functions in this compartment
    "Allow any-user to use functions-family in compartment id ${var.compartment_ocid} where all {request.principal.type='onssubscription', request.principal.compartment.id='${var.compartment_ocid}'}"
  ]

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "Policy"
    "Component"    = "LogScaleDRFailover"
  })
}

# Function
# IMPORTANT: Per OCI docs, image and image_digest must be updated together.
# The function is configured to replace when the docker_build_push resource changes,
# ensuring the new image is deployed.
resource "oci_functions_function" "failover" {
  count          = local.enabled ? 1 : 0
  application_id = oci_functions_application.failover[0].id
  display_name   = local.function_name
  # OCIR image format: <region-key>.ocir.io/<namespace>/<repo>:<tag>
  # The tag includes a content hash, so it changes when source code changes
  image              = local.ocir_image_uri
  memory_in_mbs      = var.function_memory_mb
  timeout_in_seconds = var.function_timeout_seconds

  # Explicitly set image_digest to ensure function updates when image changes
  # Per OCI docs: "This field must be updated if image is updated"
  # When image_digest is null, OCI will use the current digest in OCIR
  image_digest = local.pushed_image_digest

  # Also set config at the Function level so values are visible in the Function UI and
  # so the function has a self-contained configuration even if Application config is edited.
  config = local.function_config

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "Function"
    "Component"    = "LogScaleDRFailover"
  })

  # Force function update when docker image is rebuilt
  lifecycle {
    replace_triggered_by = [
      null_resource.docker_build_push
    ]
  }

  depends_on = [
    oci_identity_policy.function_access,
    null_resource.docker_build_push
  ]
}

# Notification Subscription to invoke the function
resource "oci_ons_subscription" "function" {
  count          = local.enabled ? 1 : 0
  compartment_id = var.compartment_ocid
  topic_id       = oci_ons_notification_topic.failover[0].id
  # For ORACLE_FUNCTIONS protocol, endpoint must be the function OCID
  endpoint = oci_functions_function.failover[0].id
  protocol = var.notification_endpoint_protocol

  depends_on = [oci_functions_function.failover]
}

# =============================================================================
# OCI Logging for Function Invocations
# =============================================================================

# Log Group for DR failover function logs
resource "oci_logging_log_group" "function" {
  count          = local.enabled ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${local.name_prefix}-dr-failover-logs"
  description    = "Log group for LogScale DR failover function invocation logs"

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "LogGroup"
    "Component"    = "LogScaleDRFailover"
  })
}

# Function invocation log - captures all function executions
resource "oci_logging_log" "function_invoke" {
  count        = local.enabled ? 1 : 0
  display_name = "${local.name_prefix}-dr-failover-invoke"
  log_group_id = oci_logging_log_group.function[0].id
  log_type     = "SERVICE"

  configuration {
    source {
      category    = "invoke"
      resource    = oci_functions_application.failover[0].id
      service     = "functions"
      source_type = "OCISERVICE"
    }
    compartment_id = var.compartment_ocid
  }

  is_enabled         = true
  retention_duration = var.log_retention_days

  freeform_tags = merge(var.common_tags, var.mandatory_tags, {
    "ResourceType" = "Log"
    "Component"    = "LogScaleDRFailover"
  })
}

# =============================================================================
# Kubernetes RBAC for DR Failover Function
# =============================================================================
# The function uses OCI IAM for API authentication, but Kubernetes RBAC
# is still required to authorize the function's dynamic group to manage
# deployments in the cluster.

# ClusterRole granting permission to manage deployments
resource "kubernetes_cluster_role" "dr_failover_function" {
  count = local.enabled && var.create_kubernetes_rbac ? 1 : 0

  metadata {
    name = "${local.name_prefix}-dr-failover-function-role"
    labels = {
      "app.kubernetes.io/name"       = "dr-failover-function"
      "app.kubernetes.io/component"  = "rbac"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "patch", "update"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments/scale"]
    verbs      = ["get", "patch", "update"]
  }
}

# ClusterRoleBinding to associate the dynamic group with the ClusterRole
# In OKE, OCI dynamic groups are mapped as Kubernetes groups using their OCID
resource "kubernetes_cluster_role_binding" "dr_failover_function" {
  count = local.enabled && var.create_kubernetes_rbac ? 1 : 0

  metadata {
    name = "${local.name_prefix}-dr-failover-function-binding"
    labels = {
      "app.kubernetes.io/name"       = "dr-failover-function"
      "app.kubernetes.io/component"  = "rbac"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.dr_failover_function[0].metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = oci_identity_dynamic_group.function[0].id
    api_group = "rbac.authorization.k8s.io"
  }
}

# =============================================================================
# NSG Rule for Function to Access OKE API Endpoint
# =============================================================================
# The function runs in worker node subnets and needs access to the OKE API
# endpoint on port 6443. This rule allows ingress from the worker NSG
# (where the function is attached) to the API endpoint NSG.

resource "oci_core_network_security_group_security_rule" "function_to_api_endpoint" {
  count = local.enabled ? 1 : 0

  network_security_group_id = var.api_endpoint_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP

  description = "Allow DR failover function to access Kubernetes API"

  source      = var.worker_nsg_id
  source_type = "NETWORK_SECURITY_GROUP"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}
