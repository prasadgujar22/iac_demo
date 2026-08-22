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
