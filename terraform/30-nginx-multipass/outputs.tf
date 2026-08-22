output "instance_name" {
  description = "Multipass instance running the proxy."
  value       = var.vm_name
}

output "proxy_internal_ip" {
  description = "VM address on the Multipass network. Same subnet as the k8s nodes."
  value       = data.external.proxy_vm_ip.result.ip
}

output "proxy_lan_ip" {
  description = "LAN address the host publishes the proxy on (via socat)."
  value       = var.proxy_lan_ip
}

output "proxy_listen_port" {
  description = "Port nginx listens on inside the VM. Consumed by the dynamic inventory's shared-state fallback (see ansible/inventory/terraform_inventory.py)."
  value       = var.proxy_listen_port
}

output "application_url" {
  description = "Single entry point for the application."
  value       = "http://${var.proxy_lan_ip}:${var.proxy_listen_port}/customer-onboarding/login"
}

output "health_url" {
  description = "Proxy health probe."
  value       = "http://${var.proxy_lan_ip}:${var.proxy_listen_port}/proxy-health"
}

output "inventory_file" {
  description = "Ansible inventory fragment consumed by the dynamic inventory."
  value       = local_file.inventory.filename
}
