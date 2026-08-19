output "vm_name" {
  description = "Multipass instance name."
  value       = var.vm_name
}

output "db_host" {
  description = "IP of the database VM on the Multipass NAT network (shared with k8s nodes)."
  value       = data.external.db_vm_ip.result.ip
}

output "listener_port" {
  description = "Oracle listener port."
  value       = var.listener_port
}

output "jdbc_url" {
  description = "JDBC URL for the pluggable database, consumed by the WLS stack and Ansible."
  value       = "jdbc:oracle:thin:@//${data.external.db_vm_ip.result.ip}:${var.listener_port}/XEPDB1"
}

output "inventory_file" {
  description = "Generated Ansible inventory fragment for the db group."
  value       = local_file.inventory.filename
}
