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

# These two are read by humans off the end of an apply, so they must name an
# address that actually answers. They were built from var.proxy_lan_ip, the LAN
# address the socat bridge publishes -- but that bridge only exists where the
# lan_bridge role runs, which is gated on primary_ip being an address the host
# actually has (see ansible/playbooks/site.yml). On any host without it the
# outputs advertised the original Linux homelab's 192.168.29.200, which answers
# nowhere: a URL that looks authoritative, was printed by a successful apply,
# and 404s in the browser.
#
# The VM's own Multipass address is reachable from the host on both platforms,
# so it is the honest answer here. The LAN entry point is still available as
# proxy_lan_ip + proxy_listen_port, for the hosts where the bridge is up.
output "application_url" {
  description = "Single entry point for the application, on the Multipass network. For the LAN entry point (where the socat bridge runs) combine proxy_lan_ip with proxy_listen_port."
  value       = "http://${data.external.proxy_vm_ip.result.ip}:${var.proxy_listen_port}/customer-onboarding/login"
}

output "health_url" {
  description = "Proxy health probe, on the Multipass network."
  value       = "http://${data.external.proxy_vm_ip.result.ip}:${var.proxy_listen_port}/proxy-health"
}

output "inventory_file" {
  description = "Ansible inventory fragment consumed by the dynamic inventory."
  value       = local_file.inventory.filename
}
