# Backend Configuration: Primary Workspace
#
# Usage:
#   terraform init -backend-config=backend-configs/primary-oci.hcl
#   terraform workspace select primary

bucket              = "your-terraform-state-bucket"
namespace           = "your-tenancy-namespace"
region              = "us-chicago-1"
key                 = "env:/logscale-oci-oke"
auth                = "ApiKey"
config_file_profile = "DEFAULT"
