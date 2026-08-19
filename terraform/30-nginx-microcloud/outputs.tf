output "instance_name" {
  value       = lxd_instance.nginx.name
  description = "LXD instance running nginx."
}

output "proxy_internal_ip" {
  value       = var.proxy_internal_ip
  description = "Static OVN address of the proxy."
}

output "application_url" {
  description = "The single entry point for the application."
  value       = "http://${var.proxy_lan_ip}:${var.proxy_listen_port}/customer-onboarding/login"
}

output "health_url" {
  value       = "http://${var.proxy_lan_ip}:${var.proxy_listen_port}/proxy-health"
  description = "Proxy health probe."
}

output "inventory_file" {
  value       = local_file.inventory.filename
  description = "Generated Ansible inventory fragment for the nginx group."
}
