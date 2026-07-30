variable "tenancy_ocid" {
  description = "The OCID of the tenancy"
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "The tenancy_ocid must be a valid OCI tenancy OCID."
  }
}

variable "compartment_ocid" {
  description = "The OCID of the compartment where storage resources will be created"
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.compartment\\.", var.compartment_ocid))
    error_message = "The compartment_ocid must be a valid OCI compartment OCID."
  }
}

variable "resource_name_prefix" {
  description = "Prefix for naming storage resources"
  type        = string

  validation {
    condition     = length(var.resource_name_prefix) > 0 && length(var.resource_name_prefix) <= 20
    error_message = "The resource_name_prefix must be between 1 and 20 characters long."
  }
}

variable "user_ocid" {
  description = "The OCID of the user for Object Storage S3-compatible access credentials"
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.user\\.", var.user_ocid))
    error_message = "The user_ocid must be a valid OCI user OCID."
  }
}

variable "data_retention_days" {
  description = "Number of days to retain LogScale data in Object Storage"
  type        = number
  default     = 2555 # ~7 years

  validation {
    condition     = var.data_retention_days >= 30 && var.data_retention_days <= 3650
    error_message = "Data retention must be between 30 and 3650 days."
  }
}

variable "archive_after_days" {
  description = "Number of days after which to archive logs to cheaper storage tier"
  type        = number
  default     = 90

  validation {
    condition     = var.archive_after_days >= 30 && var.archive_after_days <= 365
    error_message = "Archive period must be between 30 and 365 days."
  }
}

variable "temp_data_retention_days" {
  description = "Number of days to retain temporary/cache data"
  type        = number
  default     = 7

  validation {
    condition     = var.temp_data_retention_days >= 1 && var.temp_data_retention_days <= 30
    error_message = "Temporary data retention must be between 1 and 30 days."
  }
}

variable "region" {
  description = "OCI region for Object Storage endpoints"
  type        = string

  validation {
    condition     = length(var.region) > 0
    error_message = "Region must be specified."
  }
}

variable "par_expiration_time" {
  description = "Pre-authenticated request expiration time in RFC3339 format. Set to a future date to avoid recreation."
  type        = string
  default     = "2026-12-31T23:59:59Z"

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.par_expiration_time))
    error_message = "PAR expiration time must be in valid RFC3339 format (e.g., 2026-12-31T23:59:59Z)."
  }
}

variable "dr" {
  description = "Disaster Recovery mode - 'active' for primary cluster, 'standby' for DR standby cluster, '' (empty) for non-DR mode (treated as active). Standby clusters do not apply retention rules since their data is transient and recovered from primary during failover."
  type        = string
  default     = "active"

  validation {
    condition     = var.dr == "" || contains(["active", "standby"], var.dr)
    error_message = "dr must be either 'active', 'standby', or empty string (non-DR mode)"
  }
}