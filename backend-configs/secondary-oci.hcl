# Backend Configuration: Secondary Workspace
#
# Usage:
#   terraform init -backend-config=backend-configs/secondary-oci.hcl
#   terraform workspace select secondary

bucket              = "your-terraform-state-bucket"
namespace           = "your-tenancy-namespace"
region              = "us-chicago-1"
key                 = "env:/logscale-oci-oke"
auth                = "ApiKey"
config_file_profile = "DEFAULT"
