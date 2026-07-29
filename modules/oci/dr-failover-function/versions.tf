terraform {
  required_providers {
    oci = {
      source                = "oracle/oci"
      version               = "~> 8.1.0"
      configuration_aliases = [oci.home]
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}