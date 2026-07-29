terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.13.2, < 3.0.0"
    }
    oci = {
      source  = "oracle/oci"
      version = "~> 8.1.0"
    }
  }
}
