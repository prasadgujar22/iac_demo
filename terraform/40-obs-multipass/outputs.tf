output "vm_name" {
  description = "Multipass instance running the observability stack."
  value       = var.vm_name
}

output "obs_ip" {
  description = "VM address on the Multipass network. Same subnet as every scrape target."
  value       = data.external.obs_vm_ip.result.ip
}

# Built from the VM's real address rather than any configured one: these are
# read by humans off the end of an apply and pasted into a browser, so they must
# name something that answers. See 30-nginx-multipass/outputs.tf for the bug
# that taught this lesson.
output "grafana_url" {
  description = "Grafana entry point."
  value       = "http://${data.external.obs_vm_ip.result.ip}:${var.grafana_port}"
}

output "prometheus_url" {
  description = "Prometheus entry point (targets page is the useful one when a scrape breaks)."
  value       = "http://${data.external.obs_vm_ip.result.ip}:${var.prometheus_port}/targets"
}

output "prometheus_port" {
  description = "Port Prometheus listens on."
  value       = var.prometheus_port
}

output "grafana_port" {
  description = "Port Grafana listens on."
  value       = var.grafana_port
}

output "inventory_file" {
  description = "Ansible inventory fragment consumed by the dynamic inventory."
  value       = local_file.inventory.filename
}
