variable "cluster_name" {
  description = "The name of the OKE cluster"
  type        = string
}

variable "logscale_namespace" {
  description = "The kubernetes namespace used by logscale resources"
  type        = string
}

variable "logscale_public_fqdn" {
  description = "Public FQDN for the LogScale cluster"
  type        = string
}

variable "lb_subnet_id" {
  description = "OCI subnet OCID for the LoadBalancer Service"
  type        = string
}

variable "lb_nsg_id" {
  description = "OCI Network Security Group OCID for the LoadBalancer Service"
  type        = string
}
