output "master_name" {
  description = "Multipass instance name of the control-plane node."
  value       = var.master_name
}

output "worker_names" {
  description = "Multipass instance names of the worker nodes."
  value       = var.worker_names
}

output "worker_names_str" {
  description = "Worker node instance names, space-joined for shell consumption."
  value       = join(" ", var.worker_names)
}

output "master_ip" {
  description = "Control-plane node's Multipass IP."
  value       = data.external.master_vm_ip.result.ip
}

output "worker_ips" {
  description = "Worker node Multipass IPs, keyed by VM name."
  value       = { for name, d in data.external.worker_vm_ip : name => d.result.ip }
}

output "kubeconfig_path" {
  description = "Local kubeconfig file the admin context was written to."
  value       = local.kubeconfig_file
}
