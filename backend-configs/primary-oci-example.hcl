# Backend Configuration: Example - Primary Workspace
#
# Copy this file and update values:
#   cp backend-configs/example-primary.hcl backend-configs/primary-oci.hcl
#
# Usage:
#   terraform init -backend-config=backend-configs/primary-oci.hcl
#   terraform workspace select primary

# bucket              = "your-terraform-state-bucket"
# namespace           = "your-oci-namespace"
# region              = "us-chicago-1"
# key                 = "env:/logscale-oci-oke"
# auth                = "ApiKey"
# config_file_profile = "DEFAULT"
