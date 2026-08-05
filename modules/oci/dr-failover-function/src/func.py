"""
DR Failover OCI Function Handler

This OCI Function handles automatic DR failover for LogScale clusters.
When the primary cluster's health check fails, this function:
1. Validates the health check status with pre-failover validation
2. Scales the humio-operator deployment to start LogScale pods

Features:
- Pre-failover validation to prevent false failovers
- Exponential backoff retry logic for transient Kubernetes API failures
- Jitter to prevent thundering herd problem
- Configurable retry parameters via environment variables
- Cooldown period to prevent failover flapping
- Detailed logging and retry statistics for observability
"""

import io
import json
import logging
import os
import random
import tempfile
import time
import yaml
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from functools import wraps
from typing import Callable, Optional, Tuple

import oci
import requests
from fdk import response


# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# =============================================================================
# Configuration from Environment Variables
# =============================================================================

CLUSTER_ID = os.environ.get("CLUSTER_ID", "")
CLUSTER_REGION = os.environ.get("CLUSTER_REGION", "")
NAMESPACE = os.environ.get("CLUSTER_NAMESPACE", "logging")
TARGET_OPERATOR_REPLICAS = int(os.environ.get("TARGET_OPERATOR_REPLICAS", "1"))
PRIMARY_HEALTH_CHECK_ID = os.environ.get("PRIMARY_HEALTH_CHECK_ID", "")
SECONDARY_HEALTH_CHECK_ID = os.environ.get("SECONDARY_HEALTH_CHECK_ID", "")
SKIP_SECONDARY_HEALTH_CHECK = os.environ.get("SKIP_SECONDARY_HEALTH_CHECK", "false").lower() == "true"
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")

STEERING_POLICY_ID = os.environ.get("STEERING_POLICY_ID", "")
STEERING_POLICY_ATTACHMENT_ID = os.environ.get("STEERING_POLICY_ATTACHMENT_ID", "")
SECONDARY_POOL_NAME = os.environ.get("SECONDARY_POOL_NAME", "secondary")
INGRESS_NAMESPACE = os.environ.get("INGRESS_NAMESPACE", "logging-ingress")
INGRESS_SERVICE_NAME = os.environ.get("INGRESS_SERVICE_NAME", "nginx-ingress-controller")
CERT_SECRET_NAME = os.environ.get("CERT_SECRET_NAME", "")
CERT_SECRET_NAMESPACE = os.environ.get("CERT_SECRET_NAMESPACE", "logging-ingress")
CERT_WAIT_TIMEOUT_SECONDS = int(os.environ.get("CERT_WAIT_TIMEOUT_SECONDS", "0"))

# Cooldown persistence (stored as annotation on humio-operator Deployment)
COOLDOWN_PERSISTENCE_ENABLED = os.environ.get("COOLDOWN_PERSISTENCE_ENABLED", "true").lower() == "true"
COOLDOWN_ANNOTATION_KEY = os.environ.get("COOLDOWN_ANNOTATION_KEY", "logscale.dr/last-failover-epoch")

# LB backend health monitoring (recommended)
# When true, use OCI Classic Load Balancer backend health metrics instead of external health checks
USE_LB_HEALTH_METRICS = os.environ.get("USE_LB_HEALTH_METRICS", "false").lower() == "true"
PRIMARY_LB_OCID = os.environ.get("PRIMARY_LB_OCID", "")
LB_BACKEND_SET_NAME = os.environ.get("LB_BACKEND_SET_NAME", "TCP-443")

# TLS secret cleanup (prevents CA certificate mismatch on failover)
HUMIOCLUSTER_NAME = os.environ.get("HUMIOCLUSTER_NAME", "")

# Pod readiness wait (ensures pods are ready before DNS update)
POD_READY_TIMEOUT_SECONDS = int(os.environ.get("POD_READY_TIMEOUT_SECONDS", "300"))
POD_READY_TARGET_COUNT = int(os.environ.get("POD_READY_TARGET_COUNT", "1"))

# Pre-failover validation configuration
PRE_FAILOVER_FAILURE_SECONDS = int(os.environ.get("PRE_FAILOVER_FAILURE_SECONDS", "180"))
FAILOVER_COOLDOWN_SECONDS = int(os.environ.get("FAILOVER_COOLDOWN_SECONDS", "300"))

# Retry configuration (with sensible defaults)
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", "3"))
BASE_DELAY_SECONDS = float(os.environ.get("BASE_DELAY_SECONDS", "1.0"))
MAX_DELAY_SECONDS = float(os.environ.get("MAX_DELAY_SECONDS", "30.0"))

logger.setLevel(LOG_LEVEL)

# HTTP status codes that indicate transient failures and should trigger retry
RETRYABLE_STATUS_CODES = frozenset([429, 500, 502, 503, 504])

# Track last failover time for cooldown
_last_failover_time = 0


def _lb_kind_from_ocid(lb_ocid: str) -> str:
    """Determine if OCID is a Classic Load Balancer."""
    if lb_ocid.startswith("ocid1.loadbalancer."):
        return "lb"
    return "unknown"


def _effective_lb_kind() -> str:
    """Determine whether PRIMARY_LB_OCID refers to an OCI Classic LB."""
    return _lb_kind_from_ocid(PRIMARY_LB_OCID)


# =============================================================================
# Retry Statistics Tracking
# =============================================================================

@dataclass
class RetryStats:
    """Track retry statistics for observability and debugging."""
    total_attempts: int = 0
    successful_retries: int = 0
    failed_operations: int = 0
    total_delay_seconds: float = 0.0
    errors_by_status: dict = field(default_factory=dict)
    errors_by_type: dict = field(default_factory=dict)


# Global retry stats for the current function invocation
retry_stats = RetryStats()


def _reset_retry_stats():
    """Reset retry statistics for a new invocation."""
    global retry_stats
    retry_stats = RetryStats()


def _get_retry_stats_dict() -> dict:
    """Convert retry stats to a dictionary for logging/response."""
    return {
        "total_attempts": retry_stats.total_attempts,
        "successful_retries": retry_stats.successful_retries,
        "failed_operations": retry_stats.failed_operations,
        "total_delay_seconds": round(retry_stats.total_delay_seconds, 2),
        "errors_by_status": retry_stats.errors_by_status,
        "errors_by_type": retry_stats.errors_by_type,
    }


# =============================================================================
# Retry Logic Implementation
# =============================================================================

def _calculate_delay(attempt: int, base_delay: float, max_delay: float, exponential_base: float = 2.0) -> float:
    """
    Calculate delay with exponential backoff and jitter.

    Args:
        attempt: Current attempt number (0-indexed)
        base_delay: Base delay in seconds
        max_delay: Maximum delay cap in seconds
        exponential_base: Base for exponential calculation (default 2.0)

    Returns:
        Delay in seconds with jitter applied

    Example delays (base=1.0, max=30.0):
        attempt 0: ~1.0s (±0.25s jitter)
        attempt 1: ~2.0s (±0.5s jitter)
        attempt 2: ~4.0s (±1.0s jitter)
        attempt 3: ~8.0s (±2.0s jitter)
    """
    # Calculate exponential backoff
    delay = min(base_delay * (exponential_base ** attempt), max_delay)

    # Add jitter (±25%) to prevent thundering herd problem
    # This is important when multiple functions might retry simultaneously
    jitter = delay * 0.25 * (2 * random.random() - 1)

    return max(0.1, delay + jitter)


def retry_with_backoff(
    max_retries: int = MAX_RETRIES,
    base_delay: float = BASE_DELAY_SECONDS,
    max_delay: float = MAX_DELAY_SECONDS,
    operation_name: str = "operation",
):
    """
    Decorator that retries a function with exponential backoff and jitter.

    Retries are triggered for:
    - HTTP 429 (Too Many Requests) - Kubernetes API rate limiting
    - HTTP 500 (Internal Server Error) - Transient server errors
    - HTTP 502 (Bad Gateway) - Load balancer/proxy issues
    - HTTP 503 (Service Unavailable) - API server overloaded
    - HTTP 504 (Gateway Timeout) - Request timeout
    - Connection errors (ConnectionError, ConnectionResetError, TimeoutError, OSError)

    Non-retryable errors (fail immediately):
    - HTTP 400 (Bad Request) - Invalid request
    - HTTP 401 (Unauthorized) - Authentication failed
    - HTTP 403 (Forbidden) - Permission denied
    - HTTP 404 (Not Found) - Resource doesn't exist
    - HTTP 409 (Conflict) - Resource version conflict
    - HTTP 422 (Unprocessable Entity) - Validation error

    Args:
        max_retries: Maximum number of retry attempts (default from MAX_RETRIES env var)
        base_delay: Initial delay in seconds before first retry
        max_delay: Maximum delay cap between retries
        operation_name: Human-readable name for logging
    """
    def decorator(func: Callable):
        @wraps(func)
        def wrapper(*args, **kwargs):
            global retry_stats
            last_exception = None

            for attempt in range(max_retries + 1):
                retry_stats.total_attempts += 1

                try:
                    result = func(*args, **kwargs)

                    # Log successful retry
                    if attempt > 0:
                        retry_stats.successful_retries += 1
                        logger.info(
                            "[%s] Succeeded after %d retry attempt(s)",
                            operation_name, attempt
                        )

                    return result

                except requests.exceptions.HTTPError as e:
                    last_exception = e
                    status_code = e.response.status_code if e.response else 0
                    status_key = f"http_{status_code}"
                    retry_stats.errors_by_status[status_key] = retry_stats.errors_by_status.get(status_key, 0) + 1

                    # Check if this is a retryable status code
                    if status_code not in RETRYABLE_STATUS_CODES:
                        logger.error(
                            "[%s] Non-retryable API error (HTTP %s): %s",
                            operation_name, status_code, str(e)
                        )
                        retry_stats.failed_operations += 1
                        raise

                    # Check if we have retries remaining
                    if attempt >= max_retries:
                        logger.error(
                            "[%s] Max retries (%d) exhausted. Last error (HTTP %s): %s",
                            operation_name, max_retries, status_code, str(e)
                        )
                        retry_stats.failed_operations += 1
                        raise

                    # Calculate and apply delay
                    delay = _calculate_delay(attempt, base_delay, max_delay)
                    retry_stats.total_delay_seconds += delay

                    logger.warning(
                        "[%s] Retryable API error (HTTP %s): %s. "
                        "Attempt %d/%d, retrying in %.2fs...",
                        operation_name, status_code, str(e),
                        attempt + 1, max_retries + 1, delay
                    )
                    time.sleep(delay)

                except (ConnectionError, ConnectionResetError, TimeoutError, OSError, requests.exceptions.RequestException) as e:
                    last_exception = e
                    error_type = type(e).__name__
                    retry_stats.errors_by_type[error_type] = retry_stats.errors_by_type.get(error_type, 0) + 1

                    # Check if we have retries remaining
                    if attempt >= max_retries:
                        logger.error(
                            "[%s] Max retries (%d) exhausted. Last connection error: %s",
                            operation_name, max_retries, e
                        )
                        retry_stats.failed_operations += 1
                        raise

                    # Calculate and apply delay
                    delay = _calculate_delay(attempt, base_delay, max_delay)
                    retry_stats.total_delay_seconds += delay

                    logger.warning(
                        "[%s] Connection error: %s. Attempt %d/%d, retrying in %.2fs...",
                        operation_name, e, attempt + 1, max_retries + 1, delay
                    )
                    time.sleep(delay)

            # Should not reach here, but handle edge case
            if last_exception:
                raise last_exception

        return wrapper
    return decorator


# =============================================================================
# Pre-Failover Validation Functions
# =============================================================================

def _check_cooldown_period(persisted_epoch: int = 0) -> bool:
    """
    Check if we're still within the cooldown period from a previous failover.

    Returns:
        True if cooldown has passed (OK to proceed), False if still in cooldown
    """
    global _last_failover_time

    if FAILOVER_COOLDOWN_SECONDS <= 0:
        return True

    current_time = time.time()
    last_ts = max(_last_failover_time, int(persisted_epoch or 0))
    if last_ts <= 0:
        return True

    time_since_last = current_time - last_ts

    if time_since_last < FAILOVER_COOLDOWN_SECONDS:
        logger.warning(
            "Failover cooldown active: %ds since last failover, cooldown is %ds. Skipping.",
            int(time_since_last), FAILOVER_COOLDOWN_SECONDS
        )
        return False

    return True


# =============================================================================
# DNS Steering Policy Helpers
# =============================================================================

def _discover_secondary_lb_ip(endpoint: str, token: str, ca_cert: str) -> str:
    """Discover the nginx ingress LB IP on the standby cluster.

    Returns the external IP string or empty string if not found.
    """
    svc_url = f"{endpoint}/api/v1/namespaces/{INGRESS_NAMESPACE}/services/{INGRESS_SERVICE_NAME}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json"
    }

    verify = True
    if ca_cert:
        import base64
        with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.crt') as f:
            f.write(base64.b64decode(ca_cert))
            verify = f.name

    try:
        resp = requests.get(svc_url, headers=headers, verify=verify, timeout=20)
        resp.raise_for_status()
        svc = resp.json()
        ingress = svc.get("status", {}).get("loadBalancer", {}).get("ingress", [])
        if ingress:
            ip = ingress[0].get("ip", "") or ingress[0].get("hostname", "")
            return ip
        logger.info("Ingress service found but no loadBalancer ingress yet")
        return ""
    except Exception as e:
        logger.warning("Failed to discover ingress LB IP: %s", e)
        return ""


def _get_opc_home_region_from_error(err: Exception) -> Optional[str]:
    """Best-effort extraction of the Health Checks monitor home region from an OCI ServiceError."""
    headers = getattr(err, "headers", None)
    if isinstance(headers, dict):
        return headers.get("opc-home-region")
    return None


def _healthchecks_client_for_region(signer, region: str) -> "oci.healthchecks.HealthChecksClient":
    """Create a HealthChecksClient for a specific region (region may be empty)."""
    config = {"region": region} if region else {}
    return oci.healthchecks.HealthChecksClient(config=config, signer=signer)


def _get_http_monitor_in_home_region(signer, monitor_id: str):
    """
    Get an HTTP monitor and a HealthChecksClient targeting the monitor's home region.

    Health Checks resources are tied to a home region; update operations must be sent to that region.
    """
    # First try the function/cluster region as a hint (most common).
    preferred_region = (CLUSTER_REGION or "").strip()
    health_client = _healthchecks_client_for_region(signer, preferred_region)
    try:
        monitor = health_client.get_http_monitor(monitor_id).data
        home_region = getattr(monitor, "home_region", None) or preferred_region
        if home_region and home_region != preferred_region:
            # Re-create the client explicitly in the home region for updates.
            health_client = _healthchecks_client_for_region(signer, home_region)
            monitor = health_client.get_http_monitor(monitor_id).data
        return monitor, health_client
    except Exception as e:
        home_region = _get_opc_home_region_from_error(e)
        if home_region and home_region != preferred_region:
            health_client = _healthchecks_client_for_region(signer, home_region)
            monitor = health_client.get_http_monitor(monitor_id).data
            return monitor, health_client
        raise


def _ensure_http_monitor_target_present(signer, monitor_id: str, target_ip: str) -> bool:
    """Ensure the DNS steering policy's HTTP monitor includes target_ip in its targets list."""
    if not monitor_id:
        return False

    monitor, health_client = _get_http_monitor_in_home_region(signer, monitor_id)
    existing_targets = list(getattr(monitor, "targets", []) or [])

    target_ip = (target_ip or "").strip()
    if not target_ip:
        return False

    if target_ip in existing_targets:
        logger.info("Health check monitor %s already includes target %s; skipping update", monitor_id, target_ip)
        return False

    new_targets = existing_targets + [target_ip]

    update_details = oci.healthchecks.models.UpdateHttpMonitorDetails(
        display_name=getattr(monitor, "display_name", None),
        interval_in_seconds=getattr(monitor, "interval_in_seconds", None),
        protocol=getattr(monitor, "protocol", None),
        targets=new_targets,
        method=getattr(monitor, "method", None),
        path=getattr(monitor, "path", None),
        port=getattr(monitor, "port", None),
        timeout_in_seconds=getattr(monitor, "timeout_in_seconds", None),
        headers=getattr(monitor, "headers", None),
        is_enabled=getattr(monitor, "is_enabled", True),
        vantage_point_names=getattr(monitor, "vantage_point_names", None),
    )

    logger.info("Updating health check monitor %s targets to include %s", monitor_id, target_ip)
    health_client.update_http_monitor(monitor_id, update_details)
    return True


def _update_steering_policy_with_secondary(signer, compartment_id: str, secondary_ip: str):
    """Upsert the secondary answer in the steering policy and disable the primary answer.

    The steering policy uses FILTER → PRIORITY → LIMIT (no HEALTH rule) so DNS failover
    is controlled entirely by the is_disabled flag on each answer. This function disables
    the primary answer and enables the secondary to redirect traffic.

    If the policy has an HTTP health check monitor attached, this function also
    (best-effort) ensures the monitor includes the secondary IP in its targets list.
    """
    if not STEERING_POLICY_ID:
        logger.info("No STEERING_POLICY_ID configured; skipping DNS update")
        return

    dns_client = oci.dns.DnsClient(config={}, signer=signer)

    # Fetch existing policy to merge answers safely
    policy = dns_client.get_steering_policy(STEERING_POLICY_ID).data

    # Best-effort: if the policy still has an HTTP monitor, ensure it can evaluate the secondary answer.
    try:
        monitor_id = getattr(policy, "health_check_monitor_id", None)
        if monitor_id:
            _ensure_http_monitor_target_present(signer, monitor_id, secondary_ip)
    except Exception as e:
        logger.warning("Failed to update steering policy health check monitor targets: %s", e)

    answers = list(policy.answers)
    pools = set([a.pool for a in answers])

    # Ensure secondary pool exists (policy template FAILOVER auto-creates pools on OCI side)
    if SECONDARY_POOL_NAME not in pools:
        logger.warning("Secondary pool %s not present; policy may be invalid for failover", SECONDARY_POOL_NAME)

    # Disable primary and enable secondary for failover
    # DNS failover is controlled by is_disabled flag (FILTER rule keeps non-disabled answers)
    updated = False
    secondary_found = False
    for a in answers:
        if a.pool == "primary":
            if not a.is_disabled:
                logger.info("Disabling primary answer for DNS failover")
                a.is_disabled = True
                updated = True
        elif a.pool == SECONDARY_POOL_NAME:
            secondary_found = True
            if a.rdata != secondary_ip or a.is_disabled:
                a.rdata = secondary_ip
                a.is_disabled = False
                updated = True

    # Insert secondary answer if not present
    if not secondary_found:
        new_answer = oci.dns.models.SteeringPolicyAnswer(
            name="secondary-ingest",
            rtype="A",
            rdata=secondary_ip,
            pool=SECONDARY_POOL_NAME,
            is_disabled=False
        )
        answers.append(new_answer)
        updated = True

    if not updated:
        logger.info("Steering policy already has secondary IP %s; no DNS change needed", secondary_ip)
        return

    update_details = oci.dns.models.UpdateSteeringPolicyDetails(
        answers=answers,
        template=policy.template,
        ttl=policy.ttl,
        rules=policy.rules
    )

    logger.info("Updating steering policy %s: disabling primary, enabling secondary IP %s", STEERING_POLICY_ID, secondary_ip)
    dns_client.update_steering_policy(STEERING_POLICY_ID, update_details)

    # Optional: refresh attachment to propagate changes quicker
    if STEERING_POLICY_ATTACHMENT_ID:
        try:
            att = dns_client.get_steering_policy_attachment(STEERING_POLICY_ATTACHMENT_ID).data
            att_details = oci.dns.models.UpdateSteeringPolicyAttachmentDetails(
                display_name=att.display_name,
                steering_policy_id=att.steering_policy_id,
                zone_id=att.zone_id,
                domain_name=att.domain_name,
                rtype=att.rtype,
                ttl=att.ttl,
            )
            dns_client.update_steering_policy_attachment(STEERING_POLICY_ATTACHMENT_ID, att_details)
            logger.info("Refreshed steering policy attachment %s", STEERING_POLICY_ATTACHMENT_ID)
        except Exception as e:
            logger.warning("Failed to refresh steering policy attachment %s: %s", STEERING_POLICY_ATTACHMENT_ID, e)


def _wait_for_cert_ready(endpoint: str, token: str, ca_cert: str, namespace: str, name: str, timeout_seconds: int):
    """Wait until the TLS secret exists and contains tls.crt (best-effort)."""
    if timeout_seconds <= 0:
        return

    import base64
    secret_url = f"{endpoint}/api/v1/namespaces/{namespace}/secrets/{name}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json"
    }

    verify = True
    if ca_cert:
        with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.crt') as f:
            f.write(base64.b64decode(ca_cert))
            verify = f.name

    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            resp = requests.get(secret_url, headers=headers, verify=verify, timeout=10)
            if resp.status_code == 404:
                logger.info("Cert secret %s/%s not found yet; waiting", namespace, name)
            else:
                resp.raise_for_status()
                data = resp.json().get("data", {})
                if "tls.crt" in data:
                    logger.info("Certificate secret %s/%s is present; proceeding with DNS flip", namespace, name)
                    return
                logger.info("Cert secret %s/%s present but missing tls.crt; waiting", namespace, name)
        except Exception as e:
            logger.info("Waiting for cert %s/%s: %s", namespace, name, e)

        time.sleep(5)

    raise TimeoutError(f"Certificate {namespace}/{name} not ready after {timeout_seconds}s")



def _get_consecutive_failure_seconds(signer, health_check_id: str, compartment_id: str) -> int:
    """
    Query OCI Monitoring for consecutive health check failure duration.

    Supports two monitoring modes:
    1. Classic LB Backend Health (USE_LB_HEALTH_METRICS=true): Monitors LB backend health
       from within OCI using oci_lbaas namespace with unhealthyBackendServers metric.
    2. External Health Check (USE_LB_HEALTH_METRICS=false): Uses oci_healthchecks namespace
       with HTTP.isHealthy metric from external vantage points.

    Args:
        signer: OCI authentication signer
        health_check_id: The OCI health check OCID (used only when USE_LB_HEALTH_METRICS=false)
        compartment_id: The compartment OCID for monitoring queries

    Returns:
        Number of consecutive seconds the health check has been failing
    """
    try:
        monitoring_client = oci.monitoring.MonitoringClient(config={}, signer=signer)

        # Use a lookback window that's longer than the required failure duration
        lookback_seconds = max(PRE_FAILOVER_FAILURE_SECONDS * 2, 300)
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(seconds=lookback_seconds)

        # Select namespace and query based on monitoring mode
        if USE_LB_HEALTH_METRICS and PRIMARY_LB_OCID:
            lb_kind = _effective_lb_kind()
            is_unhealthy_check = lambda v: v > 0

            if lb_kind == "lb":
                namespace = "oci_lbaas"
                query = f'unhealthyBackendServers[1m]{{resourceId = "{PRIMARY_LB_OCID}", backendSetName = "{LB_BACKEND_SET_NAME}"}}.max()'
                logger.info(
                    "Using LB backend health metrics mode (namespace=%s, lb=%s, backendSet=%s)",
                    namespace,
                    PRIMARY_LB_OCID,
                    LB_BACKEND_SET_NAME,
                )
            else:
                logger.warning(
                    "USE_LB_HEALTH_METRICS=true but PRIMARY_LB_OCID=%s is not a recognized Classic LB OCID; skipping LB metrics validation",
                    PRIMARY_LB_OCID,
                )
                return 0
        else:
            # External Health Check Mode (legacy)
            # Uses oci_healthchecks namespace with HTTP.isHealthy metric
            namespace = "oci_healthchecks"
            # Use groupBy(resourceId) to aggregate across dimensions like vantagePoint/target
            query = f'HTTP.isHealthy[1m]{{resourceId = "{health_check_id}"}}.groupBy(resourceId).max()'
            # For health checks, unhealthy means value < 1
            is_unhealthy_check = lambda v: v < 1.0
            logger.info("Using external health check metrics mode (namespace=%s, healthCheckId=%s)",
                       namespace, health_check_id)

        summarize_metrics_details = oci.monitoring.models.SummarizeMetricsDataDetails(
            namespace=namespace,
            query=query,
            start_time=start_time.isoformat(),
            end_time=end_time.isoformat(),
            resolution="1m"
        )

        response = monitoring_client.summarize_metrics_data(
            compartment_id=compartment_id,
            summarize_metrics_data_details=summarize_metrics_details
        )

        if not response.data:
            # This typically happens when metrics are absent
            resource_id = PRIMARY_LB_OCID if USE_LB_HEALTH_METRICS else health_check_id
            logger.warning("No monitoring datapoints found for resource %s", resource_id)

            # For external health check mode, check if monitor is disabled
            if not USE_LB_HEALTH_METRICS and health_check_id:
                try:
                    health_client = oci.healthchecks.HealthChecksClient(config={}, signer=signer)
                    monitor = health_client.get_http_monitor(health_check_id)
                    is_enabled = getattr(monitor.data, "is_enabled", True)
                    if is_enabled is False:
                        logger.info(
                            "Health check %s is disabled; treating absence as %ds consecutive failure.",
                            health_check_id, lookback_seconds
                        )
                        return int(lookback_seconds)
                except Exception as e:
                    logger.warning("Could not verify health check enabled state for %s: %s", health_check_id, e)

            return 0

        # Get datapoints from the response
        datapoints = []
        for metric in response.data:
            for dp in metric.aggregated_datapoints:
                datapoints.append({
                    "timestamp": dp.timestamp,
                    "value": dp.value
                })

        if not datapoints:
            resource_id = PRIMARY_LB_OCID if USE_LB_HEALTH_METRICS else health_check_id
            logger.warning("No datapoints in monitoring response for resource %s", resource_id)
            return 0

        # Sort by timestamp descending (most recent first)
        datapoints.sort(key=lambda x: x["timestamp"], reverse=True)

        # Calculate consecutive failure duration from most recent datapoint
        most_recent_time = datapoints[0]["timestamp"]
        failure_start_time = most_recent_time

        for dp in datapoints:
            raw_value = dp.get("value", 0 if USE_LB_HEALTH_METRICS else 1)
            try:
                status_value = float(raw_value)
            except (TypeError, ValueError):
                status_value = 0.0 if USE_LB_HEALTH_METRICS else 1.0

            if not is_unhealthy_check(status_value):  # Healthy - stop counting
                break

            failure_start_time = dp["timestamp"]

        # Check if most recent datapoint is a failure
        try:
            most_recent_value = float(datapoints[0].get("value", 0 if USE_LB_HEALTH_METRICS else 1))
        except (TypeError, ValueError):
            most_recent_value = 0.0 if USE_LB_HEALTH_METRICS else 1.0

        if not is_unhealthy_check(most_recent_value):  # Most recent is healthy
            resource_id = PRIMARY_LB_OCID if USE_LB_HEALTH_METRICS else health_check_id
            logger.info(
                "Resource %s: most recent check is healthy (value=%.1f)",
                resource_id, most_recent_value
            )
            return 0

        # Calculate consecutive failure seconds
        consecutive_failure_seconds = int((most_recent_time - failure_start_time).total_seconds())

        resource_id = PRIMARY_LB_OCID if USE_LB_HEALTH_METRICS else health_check_id
        logger.info(
            "Resource %s: failing for %d consecutive seconds (last_value=%.1f)",
            resource_id, consecutive_failure_seconds, most_recent_value
        )
        return consecutive_failure_seconds

    except Exception as e:
        logger.warning("Error querying OCI Monitoring for health metrics: %s", e)
        return 0


def _health_check_healthy(signer, health_check_id: str, compartment_id: str = None) -> bool:
    """Check if primary is healthy using OCI Monitoring metrics.

    Supports two monitoring modes:
    1. Classic LB Backend Health (USE_LB_HEALTH_METRICS=true): Uses oci_lbaas namespace
       with unhealthyBackendServers metric. Healthy when value=0.
    2. External Health Check (USE_LB_HEALTH_METRICS=false): Uses oci_healthchecks namespace
       with HTTP.isHealthy metric. Healthy when min(HTTP.isHealthy) >= 1.

    This function uses OCI Monitoring metrics for consistency with the alarm that triggers
    the DR failover.

    Returns False (unhealthy) if:
    - LB mode: Unhealthy backend count > 0
    - External mode: HTTP.isHealthy < 1 or health check is disabled
    - Errors occur during check

    Args:
        signer: OCI authentication signer
        health_check_id: The OCI health check OCID (used only when USE_LB_HEALTH_METRICS=false)
        compartment_id: The compartment OCID for monitoring queries (optional, uses env var if not provided)
    """
    try:
        # Get compartment ID from parameter or environment
        comp_id = compartment_id or os.environ.get("COMPARTMENT_ID", "")

        # LB Backend Health Mode (recommended)
        if USE_LB_HEALTH_METRICS and PRIMARY_LB_OCID:
            if not comp_id:
                logger.warning("No compartment ID available for LB metrics query; treating as unhealthy")
                return False

            lb_kind = _effective_lb_kind()
            if lb_kind != "lb":
                logger.warning(
                    "USE_LB_HEALTH_METRICS=true but PRIMARY_LB_OCID=%s is not a recognized Classic LB OCID; skipping LB metrics validation",
                    PRIMARY_LB_OCID,
                )
                return True

            monitoring_client = oci.monitoring.MonitoringClient(config={}, signer=signer)

            # Query the last 2 minutes of LB backend health metrics
            end_time = datetime.now(timezone.utc)
            start_time = end_time - timedelta(minutes=2)

            # unhealthyBackendServers = 0 means all backends are healthy (per backendSetName)
            namespace = "oci_lbaas"
            query = f'unhealthyBackendServers[1m]{{resourceId = "{PRIMARY_LB_OCID}", backendSetName = "{LB_BACKEND_SET_NAME}"}}.max()'

            summarize_metrics_details = oci.monitoring.models.SummarizeMetricsDataDetails(
                namespace=namespace,
                query=query,
                start_time=start_time.isoformat(),
                end_time=end_time.isoformat(),
                resolution="1m"
            )

            response = monitoring_client.summarize_metrics_data(
                compartment_id=comp_id,
                summarize_metrics_data_details=summarize_metrics_details
            )

            if not response.data:
                logger.warning("No %s metrics found for %s; treating as unhealthy", namespace, PRIMARY_LB_OCID)
                return False

            # Get the most recent datapoint
            datapoints = []
            for metric in response.data:
                for dp in metric.aggregated_datapoints:
                    datapoints.append({
                        "timestamp": dp.timestamp,
                        "value": dp.value
                    })

            if not datapoints:
                logger.warning("No datapoints in LB metrics response for %s; treating as unhealthy", PRIMARY_LB_OCID)
                return False

            # Sort by timestamp descending (most recent first)
            datapoints.sort(key=lambda x: x["timestamp"], reverse=True)

            # Check if the most recent datapoint indicates healthy (unhealthy backend count = 0)
            most_recent_value = float(datapoints[0].get("value", 1))
            is_healthy = most_recent_value == 0

            logger.info(
                "%s %s status (via metrics): %s (unhealthy_backends=%.0f, datapoints=%d)",
                lb_kind.upper(),
                PRIMARY_LB_OCID,
                "healthy" if is_healthy else "unhealthy",
                most_recent_value,
                len(datapoints)
            )
            return is_healthy

        # External Health Check Mode (legacy)
        health_client = oci.healthchecks.HealthChecksClient(config={}, signer=signer)

        # Get health check details
        health_check = health_client.get_http_monitor(health_check_id)

        # Check if the health check is enabled - if disabled, treat as unhealthy
        is_enabled = health_check.data.is_enabled if hasattr(health_check.data, 'is_enabled') else True
        lifecycle_state = health_check.data.lifecycle_state if hasattr(health_check.data, 'lifecycle_state') else "ACTIVE"

        if not is_enabled:
            logger.info(
                "Health check %s is DISABLED (lifecycle: %s); treating as unhealthy",
                health_check_id, lifecycle_state
            )
            return False

        # Use OCI Monitoring metrics for health status (consistent with alarm evaluation)
        try:
            if not comp_id:
                logger.warning("No compartment ID available for metrics query; falling back to probe results")
                return _health_check_healthy_probe_fallback(signer, health_check_id, lifecycle_state, is_enabled)

            monitoring_client = oci.monitoring.MonitoringClient(config={}, signer=signer)

            # Query the last 2 minutes of health check metrics
            # Using min() aggregation to match alarm behavior - unhealthy if ANY vantage point fails
            end_time = datetime.now(timezone.utc)
            start_time = end_time - timedelta(minutes=2)

            query = f'HTTP.isHealthy[1m]{{resourceId = "{health_check_id}"}}.groupBy(resourceId).min()'

            summarize_metrics_details = oci.monitoring.models.SummarizeMetricsDataDetails(
                namespace="oci_healthchecks",
                query=query,
                start_time=start_time.isoformat(),
                end_time=end_time.isoformat(),
                resolution="1m"
            )

            response = monitoring_client.summarize_metrics_data(
                compartment_id=comp_id,
                summarize_metrics_data_details=summarize_metrics_details
            )

            if not response.data:
                logger.warning("No monitoring datapoints found for health check %s; treating as unhealthy", health_check_id)
                return False

            # Get the most recent datapoint
            datapoints = []
            for metric in response.data:
                for dp in metric.aggregated_datapoints:
                    datapoints.append({
                        "timestamp": dp.timestamp,
                        "value": dp.value
                    })

            if not datapoints:
                logger.warning("No datapoints in monitoring response for health check %s; treating as unhealthy", health_check_id)
                return False

            # Sort by timestamp descending (most recent first)
            datapoints.sort(key=lambda x: x["timestamp"], reverse=True)

            # Check if the most recent datapoint indicates healthy (value >= 1.0)
            most_recent_value = float(datapoints[0].get("value", 0))
            is_healthy = most_recent_value >= 1.0

            logger.info(
                "Health check %s status (via metrics): %s (min_value=%.1f, datapoints=%d, lifecycle: %s, enabled: %s)",
                health_check_id,
                "healthy" if is_healthy else "unhealthy",
                most_recent_value,
                len(datapoints),
                lifecycle_state,
                is_enabled
            )
            return is_healthy

        except Exception as e:
            logger.warning("Could not get monitoring metrics for health check %s: %s; falling back to probe results", health_check_id, e)
            return _health_check_healthy_probe_fallback(signer, health_check_id, lifecycle_state, is_enabled)

    except Exception as e:
        logger.error("Error checking health: %s", e)
        return False


def _health_check_healthy_probe_fallback(signer, health_check_id: str, lifecycle_state: str, is_enabled: bool) -> bool:
    """Fallback health check using probe results API.

    Used when OCI Monitoring metrics are not available.
    """
    try:
        health_client = oci.healthchecks.HealthChecksClient(config={}, signer=signer)
        results = health_client.list_http_probe_results(
            probe_configuration_id=health_check_id,
            sort_order="DESC",
            limit=10
        )

        if results.data:
            # Check if the most recent results indicate healthy
            healthy_count = sum(1 for r in results.data if r.is_healthy)
            total_count = len(results.data)

            # Consider healthy if majority of recent probes passed
            is_healthy = healthy_count > (total_count / 2)

            logger.info(
                "Health check %s status (probe fallback): %s (healthy: %d/%d, lifecycle: %s, enabled: %s)",
                health_check_id,
                "healthy" if is_healthy else "unhealthy",
                healthy_count,
                total_count,
                lifecycle_state,
                is_enabled
            )
            return is_healthy
        else:
            logger.warning("No probe results found for health check %s", health_check_id)
            return False

    except Exception as e:
        logger.warning("Could not get probe results for health check %s: %s", health_check_id, e)
        # Fall back to checking lifecycle state
        is_healthy = lifecycle_state == "ACTIVE" and is_enabled
        logger.info(
            "Health check %s status (lifecycle fallback): %s (lifecycle: %s, enabled: %s)",
            health_check_id,
            "healthy" if is_healthy else "unhealthy",
            lifecycle_state,
            is_enabled
        )
        return is_healthy


def _validate_primary_unhealthy(signer, compartment_id: str) -> bool:
    """
    Comprehensive pre-failover validation for primary health.

    This function ALWAYS performs pre-failover validation to prevent the function
    from scaling the secondary operator when the primary is healthy (e.g., during failback).

    Validation steps:
    1. Queries OCI health check for current health status
    2. Queries OCI Monitoring for consecutive failure duration
    3. Verifies failures have persisted for the required duration

    Returns:
        True if primary is confirmed unhealthy (proceed with failover)
        False if primary appears healthy (skip failover)
    """
    logger.info(
        "Pre-failover validation (failure_seconds=%d, cooldown=%ds)",
        PRE_FAILOVER_FAILURE_SECONDS, FAILOVER_COOLDOWN_SECONDS
    )

    # Step 1: Check current health status via OCI health check (using metrics for consistency with alarm)
    if _health_check_healthy(signer, PRIMARY_HEALTH_CHECK_ID, compartment_id):
        logger.info("Primary health check is currently healthy; may be recovering. Skipping failover.")
        return False

    # Step 2: If PRE_FAILOVER_FAILURE_SECONDS is 0, skip duration check (for testing)
    if PRE_FAILOVER_FAILURE_SECONDS == 0:
        logger.info("PRE_FAILOVER_FAILURE_SECONDS=0; skipping duration check (testing mode)")
        return True

    # Step 3: Query OCI Monitoring for consecutive failure duration
    consecutive_failure_seconds = _get_consecutive_failure_seconds(signer, PRIMARY_HEALTH_CHECK_ID, compartment_id)

    if consecutive_failure_seconds < PRE_FAILOVER_FAILURE_SECONDS:
        logger.info(
            "Primary has been failing for %ds (need %ds); waiting for more confirmation",
            consecutive_failure_seconds, PRE_FAILOVER_FAILURE_SECONDS
        )
        return False

    # Primary is confirmed unhealthy
    logger.info(
        "Primary confirmed unhealthy: failing for %ds >= %ds required. Proceeding with failover.",
        consecutive_failure_seconds, PRE_FAILOVER_FAILURE_SECONDS
    )
    return True


# =============================================================================
# Kubernetes Client Functions
# =============================================================================

@retry_with_backoff(operation_name="get_kubernetes_client")
def _get_kubernetes_client(signer, cluster_id: str):
    """Create Kubernetes API client for OKE cluster with retry logic."""
    try:
        container_engine = oci.container_engine.ContainerEngineClient(config={}, signer=signer)

        # Get cluster details
        cluster = container_engine.get_cluster(cluster_id)

        # Get kubeconfig for the cluster
        kubeconfig_response = container_engine.create_kubeconfig(
            cluster_id=cluster_id,
            create_cluster_kubeconfig_content_details=oci.container_engine.models.CreateClusterKubeconfigContentDetails(
                token_version="2.0.0",
                expiration=600  # 10 minutes
            )
        )

        # Parse the kubeconfig content
        kubeconfig_data = kubeconfig_response.data.text if hasattr(kubeconfig_response.data, 'text') else str(kubeconfig_response.data)

        # Write kubeconfig to temporary file
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.kubeconfig') as f:
            f.write(kubeconfig_data)
            kubeconfig_path = f.name

        # Parse YAML to extract endpoint and token
        kubeconfig = yaml.safe_load(kubeconfig_data)

        # Extract cluster endpoint
        # Priority order:
        # 1. kubernetes endpoint (public endpoint if enabled)
        # 2. vcn_hostname_endpoint (VCN-internal DNS name, works from functions in same VCN)
        # 3. private_endpoint (raw IP:port, may not be routable from functions subnet)
        endpoint = cluster.data.endpoints.kubernetes
        if not endpoint:
            # Try VCN hostname endpoint first - this is the best option for functions
            vcn_ep = getattr(cluster.data.endpoints, 'vcn_hostname_endpoint', None)
            if vcn_ep:
                endpoint = f"https://{vcn_ep}"
                logger.info("Using VCN hostname endpoint: %s", endpoint)
            else:
                # Fall back to private endpoint
                private_ep = cluster.data.endpoints.private_endpoint
                if private_ep:
                    endpoint = f"https://{private_ep}"
                    logger.info("Using private endpoint: %s", endpoint)
                else:
                    raise RuntimeError("No kubernetes, VCN hostname, or private endpoint available for cluster")

        # Extract token from kubeconfig
        # The kubeconfig contains exec-based auth or token directly
        token = None
        for user in kubeconfig.get('users', []):
            user_data = user.get('user', {})
            if 'token' in user_data:
                token = user_data['token']
                break
            elif 'exec' in user_data:
                # For exec-based auth, we need to use the OCI SDK token
                # Generate a token using the signer
                token = _generate_oke_token(signer, cluster_id)
                break

        if not token:
            token = _generate_oke_token(signer, cluster_id)

        # Extract CA certificate
        ca_cert = None
        for cluster_data in kubeconfig.get('clusters', []):
            ca_data = cluster_data.get('cluster', {}).get('certificate-authority-data')
            if ca_data:
                ca_cert = ca_data
                break

        logger.info("Configured Kubernetes client for cluster %s", cluster_id)
        return endpoint, token, ca_cert, kubeconfig_path

    except Exception as e:
        logger.error("Failed to get Kubernetes client: %s", e)
        raise


def _generate_oke_token(signer, cluster_id: str) -> str:
    """
    Generate an OKE authentication token using the OCI SDK.

    This creates a short-lived token for Kubernetes API authentication.
    The token is a base64-encoded signed URL that OKE validates by calling back to OCI.

    This implementation mimics what `oci ce cluster generate-token` does:
    1. Create a signed request to the OKE cluster_request endpoint
    2. Base64 encode the signed URL as the bearer token
    """
    try:
        import base64
        import urllib.parse
        from datetime import datetime, timezone

        # Extract region from cluster_id (format: ocid1.cluster.oc1.<region>.<unique_id>)
        # Example: ocid1.cluster.oc1.us-chicago-1.aaaaaaaexampleexampleexampleexampleexample
        parts = cluster_id.split('.')
        if len(parts) >= 4:
            region = parts[3]
        else:
            region = CLUSTER_REGION or "us-chicago-1"

        # Build the cluster_request URL that OKE uses for token validation
        oke_endpoint = f"https://containerengine.{region}.oraclecloud.com"
        request_path = f"/cluster_request/{cluster_id}"
        full_url = f"{oke_endpoint}{request_path}"

        # Create a prepared request object for the signer
        req = requests.Request('GET', full_url)
        prepared = req.prepare()

        # Sign the request using the OCI signer
        # This adds the Authorization header with the OCI signature
        signer.do_request_sign(prepared, enforce_content_headers=False)

        # Get the authorization header that was added
        auth_header = prepared.headers.get('authorization', '')
        date_header = prepared.headers.get('date', '')

        if not auth_header:
            raise RuntimeError("Signer did not add authorization header")

        # Construct the token URL with authorization as query parameter
        # This matches the format used by `oci ce cluster generate-token`
        token_url = f"{full_url}?authorization={urllib.parse.quote(auth_header)}&date={urllib.parse.quote(date_header)}"

        # Base64 encode the URL - this is the bearer token
        token = base64.b64encode(token_url.encode('utf-8')).decode('utf-8')

        logger.info("Generated OKE token using signed request method for region %s", region)
        return token

    except Exception as e:
        logger.warning("Failed to generate OKE token via signed request: %s, falling back to kubeconfig method", e)

        # Fallback: Try using create_kubeconfig
        try:
            container_engine = oci.container_engine.ContainerEngineClient(config={}, signer=signer)
            kubeconfig_response = container_engine.create_kubeconfig(
                cluster_id=cluster_id,
                create_cluster_kubeconfig_content_details=oci.container_engine.models.CreateClusterKubeconfigContentDetails(
                    token_version="2.0.0",
                    expiration=600
                )
            )

            kubeconfig_data = kubeconfig_response.data.text if hasattr(kubeconfig_response.data, 'text') else str(kubeconfig_response.data)
            kubeconfig = yaml.safe_load(kubeconfig_data)

            # Extract token from kubeconfig if available
            for user in kubeconfig.get('users', []):
                user_data = user.get('user', {})
                if 'token' in user_data:
                    return user_data['token']

            logger.warning("Could not extract token from kubeconfig")
            return ""

        except Exception as e2:
            logger.error("Failed to generate OKE token: %s", e2)
            raise


@retry_with_backoff(operation_name="get_operator_state")
def _get_operator_state(endpoint: str, token: str, ca_cert: str) -> Tuple[int, int]:
    """Get current humio-operator replica count and persisted cooldown timestamp."""
    deployment_url = f"{endpoint}/apis/apps/v1/namespaces/{NAMESPACE}/deployments/humio-operator"

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json"
    }

    # Write CA cert to temp file if provided
    verify = True
    if ca_cert:
        import base64
        with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.crt') as f:
            f.write(base64.b64decode(ca_cert))
            verify = f.name

    try:
        resp = requests.get(deployment_url, headers=headers, verify=verify, timeout=30)
        resp.raise_for_status()

        deployment_data = resp.json()
        current_replicas = int(deployment_data.get("spec", {}).get("replicas", 0))
        annotations = deployment_data.get("metadata", {}).get("annotations", {}) or {}
        persisted_epoch = 0
        if COOLDOWN_PERSISTENCE_ENABLED:
            try:
                persisted_epoch = int(annotations.get(COOLDOWN_ANNOTATION_KEY, "0"))
            except Exception:
                persisted_epoch = 0

        logger.info("Current humio-operator replicas: %d", current_replicas)
        return current_replicas, persisted_epoch

    except requests.exceptions.HTTPError as e:
        if e.response and e.response.status_code == 404:
            logger.error("humio-operator deployment not found in namespace %s", NAMESPACE)
            raise RuntimeError(f"Deployment humio-operator not found in namespace {NAMESPACE}")
        raise


@retry_with_backoff(operation_name="patch_operator_annotation")
def _patch_operator_annotation(endpoint: str, token: str, ca_cert: str, annotation_key: str, annotation_value: str):
    """Patch humio-operator deployment annotation with retry logic."""
    deployment_url = f"{endpoint}/apis/apps/v1/namespaces/{NAMESPACE}/deployments/humio-operator"

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/merge-patch+json",
        "Accept": "application/json"
    }

    patch_data = {
        "metadata": {
            "annotations": {
                annotation_key: annotation_value
            }
        }
    }

    # Write CA cert to temp file if provided
    verify = True
    if ca_cert:
        import base64
        with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.crt') as f:
            f.write(base64.b64decode(ca_cert))
            verify = f.name

    try:
        logger.info("Persisting failover cooldown to annotation %s=%s", annotation_key, annotation_value)
        resp = requests.patch(
            deployment_url,
            headers=headers,
            json=patch_data,
            verify=verify,
            timeout=30
        )
        resp.raise_for_status()
    except Exception as e:
        logger.error("Failed to patch operator annotation: %s", e)
        raise


@retry_with_backoff(operation_name="patch_operator_replicas")
def _patch_operator_replicas(endpoint: str, token: str, ca_cert: str, target_replicas: int):
    """Patch humio-operator replica count with retry logic."""
    deployment_url = f"{endpoint}/apis/apps/v1/namespaces/{NAMESPACE}/deployments/humio-operator"

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json-patch+json",
        "Accept": "application/json"
    }

    patch_data = [
        {"op": "replace", "path": "/spec/replicas", "value": target_replicas}
    ]

    # Write CA cert to temp file if provided
    verify = True
    if ca_cert:
        import base64
        with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.crt') as f:
            f.write(base64.b64decode(ca_cert))
            verify = f.name

    try:
        logger.info("Patching humio-operator deployment to %d replica(s)", target_replicas)

        resp = requests.patch(
            deployment_url,
            headers=headers,
            json=patch_data,
            verify=verify,
            timeout=30
        )
        resp.raise_for_status()

        logger.info("Successfully patched humio-operator replicas to %d", target_replicas)

    except Exception as e:
        logger.error("Failed to patch operator replicas: %s", e)
        raise


@retry_with_backoff(operation_name="cleanup_tls_secret")
def _cleanup_stale_tls_secret(endpoint: str, token: str, ca_cert: str, namespace: str, humiocluster_name: str):
    """
    Delete stale TLS secret before scaling operator to prevent CA certificate mismatch.

    In DR standby deployments, when the operator is scaled to 0 and later scaled back up,
    the CA keypair may be regenerated but the cluster TLS secret ({humiocluster_name})
    retains the old CA. This causes TLS verification failures when the operator tries
    to communicate with LogScale pods.

    Deleting the TLS secret allows cert-manager to recreate it with the correct CA
    from the current CA keypair.

    See: humio-operator/internal/helpers/clusterinterface.go line 213

    Args:
        endpoint: Kubernetes API endpoint URL
        token: Bearer token for authentication
        ca_cert: Base64-encoded CA certificate
        namespace: Namespace containing the secret
        humiocluster_name: Name of the HumioCluster (also the secret name)

    Returns:
        True if cleanup succeeded or secret didn't exist
    """
    if not humiocluster_name:
        logger.info("HUMIOCLUSTER_NAME not set; skipping TLS secret cleanup")
        return True

    secret_name = humiocluster_name
    secret_url = f"{endpoint}/api/v1/namespaces/{namespace}/secrets/{secret_name}"

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json"
    }

    # Write CA cert to temp file if provided
    verify = True
    if ca_cert:
        import base64
        with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.crt') as f:
            f.write(base64.b64decode(ca_cert))
            verify = f.name

    try:
        # First, check if secret exists
        resp = requests.get(secret_url, headers=headers, verify=verify, timeout=30)

        if resp.status_code == 404:
            logger.info("TLS secret '%s' not found in namespace '%s'; nothing to cleanup", secret_name, namespace)
            return True

        resp.raise_for_status()
        logger.info("Found TLS secret '%s' in namespace '%s'", secret_name, namespace)

        # Delete the secret
        delete_resp = requests.delete(secret_url, headers=headers, verify=verify, timeout=30)

        if delete_resp.status_code == 404:
            # Secret was deleted between GET and DELETE (race condition) - that's OK
            logger.info("TLS secret '%s' already deleted", secret_name)
            return True

        delete_resp.raise_for_status()
        logger.info("Deleted stale TLS secret '%s' to prevent CA mismatch", secret_name)
        logger.info("  cert-manager will recreate the secret with the current CA")
        return True

    except requests.exceptions.HTTPError as e:
        if e.response is not None and e.response.status_code == 404:
            logger.info("TLS secret '%s' not found; nothing to cleanup", secret_name)
            return True
        logger.error("Failed to cleanup TLS secret: %s", e)
        raise
    except Exception as e:
        logger.error("Failed to cleanup TLS secret: %s", e)
        raise


def _wait_for_logscale_ready(endpoint: str, token: str, ca_cert: str, namespace: str, target_count: int, timeout_seconds: int) -> bool:
    """
    Wait for LogScale pods to become ready after operator scaling.

    This ensures the failover is complete before DNS is updated, preventing
    traffic from being routed to pods that aren't ready to serve requests.

    Args:
        endpoint: Kubernetes API endpoint URL
        token: Bearer token for authentication
        ca_cert: Base64-encoded CA certificate
        namespace: Namespace containing LogScale pods
        target_count: Minimum number of ready pods required
        timeout_seconds: Maximum time to wait (0 disables waiting)

    Returns:
        True if target_count pods became ready within timeout, False otherwise
    """
    if timeout_seconds <= 0:
        logger.info("Pod readiness wait disabled (timeout=0)")
        return True

    if target_count <= 0:
        logger.info("Pod readiness wait disabled (target_count=0)")
        return True

    logger.info("Waiting for LogScale pods to become ready (target=%d, timeout=%ds)...", target_count, timeout_seconds)

    # Label selector for LogScale pods managed by humio-operator
    label_selector = "app.kubernetes.io/name=humio,app.kubernetes.io/managed-by=humio-operator"
    # URL-encode the label selector
    import urllib.parse
    encoded_selector = urllib.parse.quote(label_selector)
    pods_url = f"{endpoint}/api/v1/namespaces/{namespace}/pods?labelSelector={encoded_selector}"

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json"
    }

    # Write CA cert to temp file if provided
    verify = True
    if ca_cert:
        import base64
        with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.crt') as f:
            f.write(base64.b64decode(ca_cert))
            verify = f.name

    start_time = time.time()
    check_interval = 10  # seconds between checks

    while time.time() - start_time < timeout_seconds:
        elapsed = int(time.time() - start_time)

        try:
            resp = requests.get(pods_url, headers=headers, verify=verify, timeout=30)
            resp.raise_for_status()
            pods_data = resp.json()

            items = pods_data.get("items", [])
            if not items:
                logger.info("No LogScale pods found yet (elapsed: %d/%ds)", elapsed, timeout_seconds)
                time.sleep(check_interval)
                continue

            ready_count = 0
            for pod in items:
                pod_name = pod.get("metadata", {}).get("name", "unknown")
                pod_phase = pod.get("status", {}).get("phase", "Unknown")

                # Check for Ready condition
                is_ready = False
                conditions = pod.get("status", {}).get("conditions", [])
                for condition in conditions:
                    if condition.get("type") == "Ready" and condition.get("status") == "True":
                        is_ready = True
                        break

                if is_ready:
                    ready_count += 1
                    logger.info("Pod %s is Ready", pod_name)
                else:
                    logger.info("Pod %s phase=%s, ready=%s", pod_name, pod_phase, is_ready)

            if ready_count >= target_count:
                logger.info("%d LogScale pod(s) are Ready (target: %d)", ready_count, target_count)
                logger.info("LogScale DR failover complete - pods are ready to serve traffic")
                return True

            logger.info("Ready pods: %d/%d (elapsed: %d/%ds)", ready_count, target_count, elapsed, timeout_seconds)

        except Exception as e:
            logger.warning("Error checking pod status (will retry): %s", e)

        time.sleep(check_interval)

    logger.error("Timeout reached (%ds) - LogScale pods not ready", timeout_seconds)
    logger.error("Troubleshooting commands:")
    logger.error("  kubectl get pods -n %s -l %s", namespace, label_selector)
    logger.error("  kubectl describe pod -n %s -l %s", namespace, label_selector)
    return False


# =============================================================================
# Main Alarm Handler
# =============================================================================

def _handle_alarm(signer, compartment_id: str) -> dict:
    """
    Main alarm handling logic with retry-enabled Kubernetes operations.

    Flow:
    0. Check cooldown period
    1. Validate primary health check is unhealthy (with pre-failover validation)
    2. Optionally validate secondary health check is healthy
    3. Build Kubernetes client (with retry)
    4. Get current operator replicas (with retry)
    5a. Cleanup stale TLS secret (with retry) - prevents CA mismatch
    5b. Patch operator replicas (with retry)
    5c. Wait for LogScale pods to become ready
    6. Discover secondary LB IP and update steering policy (best-effort)

    Returns:
        dict with action taken and retry statistics
    """
    global _last_failover_time
    _reset_retry_stats()

    # Step 0: Check in-memory cooldown period (fast path)
    if not _check_cooldown_period():
        return {
            "action": "skipped",
            "reason": "cooldown_active",
            "retry_stats": _get_retry_stats_dict()
        }

    # Step 1: Validate primary health check with pre-failover validation
    if not _validate_primary_unhealthy(signer, compartment_id):
        logger.info("Primary health check recovered or insufficient failures; skipping operator scale-up.")
        return {
            "action": "skipped",
            "reason": "primary_healthy",
            "retry_stats": _get_retry_stats_dict()
        }

    # Step 2: Optionally validate secondary health check
    if SKIP_SECONDARY_HEALTH_CHECK:
        logger.info("Skipping secondary health check gating due to configuration.")
    elif SECONDARY_HEALTH_CHECK_ID:
        secondary_ok = _health_check_healthy(signer, SECONDARY_HEALTH_CHECK_ID, compartment_id)
        if not secondary_ok:
            logger.warning("Secondary health check not healthy; not scaling operator.")
            return {
                "action": "skipped",
                "reason": "secondary_unhealthy",
                "retry_stats": _get_retry_stats_dict()
            }
    else:
        logger.info("No secondary health check configured; proceeding without gate.")

    # Step 3: Get Kubernetes access (with retry)
    endpoint, token, ca_cert, kubeconfig_path = _get_kubernetes_client(signer, CLUSTER_ID)

    # Step 4: Get current replicas and persisted cooldown (with retry)
    current_replicas, persisted_epoch = _get_operator_state(endpoint, token, ca_cert)

    if COOLDOWN_PERSISTENCE_ENABLED and persisted_epoch > 0:
        if not _check_cooldown_period(persisted_epoch):
            return {
                "action": "skipped",
                "reason": "cooldown_active_persisted",
                "persisted_epoch": persisted_epoch,
                "retry_stats": _get_retry_stats_dict()
            }

    if current_replicas >= TARGET_OPERATOR_REPLICAS:
        logger.info("humio-operator replicas already >= target (%d); no-op.", current_replicas)
        return {
            "action": "noop",
            "current": current_replicas,
            "target": TARGET_OPERATOR_REPLICAS,
            "retry_stats": _get_retry_stats_dict()
        }

    # Step 5a: Cleanup stale TLS secret before scaling operator (with retry)
    # This prevents CA certificate mismatch when operator is scaled from 0
    try:
        _cleanup_stale_tls_secret(endpoint, token, ca_cert, NAMESPACE, HUMIOCLUSTER_NAME)
    except Exception as e:
        logger.warning("TLS secret cleanup failed (continuing with failover): %s", e)
        # Non-fatal - continue with failover even if cleanup fails

    # Step 5b: Patch operator replicas (with retry)
    _patch_operator_replicas(endpoint, token, ca_cert, TARGET_OPERATOR_REPLICAS)

    # Step 5c: Wait for LogScale pods to become ready
    pods_ready = _wait_for_logscale_ready(
        endpoint, token, ca_cert, NAMESPACE,
        POD_READY_TARGET_COUNT, POD_READY_TIMEOUT_SECONDS
    )
    if not pods_ready:
        logger.warning("LogScale pods did not become ready within timeout; continuing with DNS update")

    # Step 6: Discover secondary LB IP and update steering policy (best-effort)
    secondary_ip = _discover_secondary_lb_ip(endpoint, token, ca_cert)
    if secondary_ip:
        # Optional: wait for certificate readiness before DNS flip
        if CERT_WAIT_TIMEOUT_SECONDS > 0 and CERT_SECRET_NAME:
            try:
                _wait_for_cert_ready(endpoint, token, ca_cert, CERT_SECRET_NAMESPACE, CERT_SECRET_NAME, CERT_WAIT_TIMEOUT_SECONDS)
            except Exception as e:
                logger.warning("Certificate readiness wait failed or timed out: %s (continuing DNS flip)", e)

        try:
            _update_steering_policy_with_secondary(signer, compartment_id, secondary_ip)
        except Exception as e:
            logger.warning("DNS steering policy update failed: %s", e)
    else:
        logger.warning("Could not discover secondary ingress LB IP; DNS not updated")

    # Update last failover time for cooldown tracking (in-memory + persistent)
    failover_epoch = int(time.time())
    _last_failover_time = failover_epoch
    if COOLDOWN_PERSISTENCE_ENABLED:
        try:
            _patch_operator_annotation(endpoint, token, ca_cert, COOLDOWN_ANNOTATION_KEY, str(failover_epoch))
        except Exception as e:
            logger.warning("Failed to persist cooldown annotation: %s", e)

    return {
        "action": "patched",
        "from": current_replicas,
        "to": TARGET_OPERATOR_REPLICAS,
        "secondary_ip": secondary_ip,
        "pods_ready": pods_ready,
        "retry_stats": _get_retry_stats_dict()
    }


# =============================================================================
# OCI Function Entry Point
# =============================================================================

def handler(ctx, data: io.BytesIO = None):
    """OCI Functions handler for DR failover"""
    try:
        # Create OCI signer using resource principal (instance principal for functions)
        signer = oci.auth.signers.get_resource_principals_signer()

        # Get compartment ID from signer
        compartment_id = os.environ.get("COMPARTMENT_ID", "")
        if not compartment_id:
            # Try to extract from cluster ID (format: ocid1.cluster.oc1.region.xxx)
            if CLUSTER_ID:
                parts = CLUSTER_ID.split('.')
                if len(parts) >= 4:
                    compartment_id = ".".join(parts[:4])

        logger.info(
            "DR Failover Function starting. Config: max_retries=%d, base_delay=%.1fs, "
            "max_delay=%.1fs, pre_failover_seconds=%d, cooldown=%ds",
            MAX_RETRIES, BASE_DELAY_SECONDS, MAX_DELAY_SECONDS,
            PRE_FAILOVER_FAILURE_SECONDS, FAILOVER_COOLDOWN_SECONDS
        )

        # Parse incoming notification data
        if data:
            raw_body = json.loads(data.getvalue())
            logger.info("Received notification: %s", json.dumps(raw_body))

            # ONS may send a list of alarm messages or a single dict
            # Handle both formats: [{...}] or {...}
            if isinstance(raw_body, list):
                logger.info("Notification is a list with %d items", len(raw_body))
                # Process the first alarm in the list
                body = raw_body[0] if raw_body else {}
            else:
                body = raw_body

            # Check if this is a monitoring alarm notification
            # OCI alarm notification can come in two formats:
            #
            # Format 1 (legacy): Root-level keys
            # {
            #   "alarm-name": "...",
            #   "alarm-state": "FIRING" or "OK",
            #   "severity": "CRITICAL",
            #   ...
            # }
            #
            # Format 2 (current): alarmMetaData array
            # {
            #   "title": "alarm-name",
            #   "type": "REPEAT|OK_TO_FIRING|...",
            #   "severity": "CRITICAL",
            #   "alarmMetaData": [{"id": "...", "status": "FIRING", ...}],
            #   ...
            # }
            #
            # Handle both formats for compatibility
            alarm_name = ""
            alarm_state = ""
            severity = ""

            if isinstance(body, dict):
                # Try Format 1 (legacy) first
                alarm_name = body.get("alarm-name", "")
                alarm_state = body.get("alarm-state", "")
                severity = body.get("severity", "")

                # If no alarm-state found, try Format 2 (alarmMetaData)
                if not alarm_state:
                    alarm_meta = body.get("alarmMetaData", [])
                    if alarm_meta and isinstance(alarm_meta, list) and len(alarm_meta) > 0:
                        first_alarm = alarm_meta[0]
                        if isinstance(first_alarm, dict):
                            alarm_state = first_alarm.get("status", "")
                            alarm_name = body.get("title", alarm_name)
                            severity = first_alarm.get("severity", severity) or body.get("severity", "")
                            logger.info("Using alarmMetaData format: status=%s", alarm_state)

            logger.info("Parsed alarm: name=%s, state=%s, severity=%s", alarm_name, alarm_state, severity)

            if alarm_state == "FIRING":
                logger.info("Processing alarm notification (state: FIRING, name: %s)", alarm_name)
                result = _handle_alarm(signer, compartment_id)
                logger.info("Failover handler result: %s", json.dumps(result))

                return response.Response(
                    ctx,
                    response_data=json.dumps({"status": "processed", "result": result}),
                    headers={"Content-Type": "application/json"}
                )
            else:
                logger.info("Alarm state is '%s' (not FIRING); skipping failover.", alarm_state)
                return response.Response(
                    ctx,
                    response_data=json.dumps({"status": "ignored", "reason": f"alarm_state={alarm_state}"}),
                    headers={"Content-Type": "application/json"}
                )
        else:
            logger.info("No data received")
            return response.Response(
                ctx,
                response_data=json.dumps({"status": "ignored", "reason": "no_data"}),
                headers={"Content-Type": "application/json"}
            )

    except Exception as e:
        logger.exception("Failed to process notification: %s", e)
        # Log retry stats even on failure for debugging
        logger.error("Retry stats at failure: %s", json.dumps(_get_retry_stats_dict()))
        return response.Response(
            ctx,
            response_data=json.dumps({"status": "error", "error": str(e), "retry_stats": _get_retry_stats_dict()}),
            headers={"Content-Type": "application/json"},
            status_code=500
        )
