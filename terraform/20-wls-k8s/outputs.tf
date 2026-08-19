output "namespace" {
  value       = var.namespace
  description = "Namespace hosting the domain."
}

output "domain_uid" {
  value       = var.domain_uid
  description = "WebLogic domainUID."
}

output "admin_username" {
  value       = var.admin_username
  description = "WebLogic administrator username."
}

output "admin_password" {
  value       = random_password.wls_admin.result
  sensitive   = true
  description = "Generated WebLogic admin password. Retrieve with: terraform output -raw admin_password"
}

output "admin_console_nodeport" {
  value       = var.admin_nodeport
  description = "NodePort for the WebLogic admin console."
}

output "managed_server_endpoints" {
  description = "Per-JVM routing data consumed by the nginx tier."
  value = [
    for s in var.managed_servers : {
      name     = s.name
      nodeport = s.nodeport
      lan_url  = "http://${s.lan_ip}:${s.lan_port}"
    }
  ]
}

output "wls_facts_file" {
  value       = local_file.wls_facts.filename
  description = "Generated facts file for Ansible and the nginx stack."
}
