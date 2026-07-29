terraform {
  required_version = ">= 1.12.2"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.1.0"
      configuration_aliases = [
        oci,
        oci.home,
      ]
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.36.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.13.2, < 3.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.1"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = ">= 2.2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0"
    }
  }
}
