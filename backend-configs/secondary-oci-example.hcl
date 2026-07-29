# Backend Configuration: Example - Secondary Workspace
#
# Copy this file and update values:
#   cp backend-configs/example-secondary.hcl backend-configs/secondary-oci.hcl
#
# Usage:
#   terraform init -backend-config=backend-configs/secondary-oci.hcl
#   terraform workspace select secondary

# bucket              = "your-terraform-state-bucket"
# namespace           = "your-oci-namespace"
# region              = "us-chicago-1"
# key                 = "env:/logscale-oci-oke"
# auth                = "ApiKey"
# config_file_profile = "DEFAULT"
