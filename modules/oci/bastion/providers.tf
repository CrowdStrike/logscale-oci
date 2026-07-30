terraform {
  required_version = ">= 1.3.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.1.0"
      configuration_aliases = [
        oci,
        oci.home,
      ]
    }
  }
}