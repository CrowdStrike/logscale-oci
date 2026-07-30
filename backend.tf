# Partial backend configuration - provide values via -backend-config:
#   terraform init -backend-config=backend-configs/primary-oci.hcl

terraform {
  backend "oci" {}
}
