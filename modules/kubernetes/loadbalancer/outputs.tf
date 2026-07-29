output "logscale_lb_ip" {
  description = "Public IP of the LogScale LoadBalancer Service"
  value       = try(kubernetes_service_v1.logscale_lb.status[0].load_balancer[0].ingress[0].ip, "")
}
