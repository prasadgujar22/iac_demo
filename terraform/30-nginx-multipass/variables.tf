variable "vm_name" {
  description = "Multipass instance name for the nginx reverse proxy."
  type        = string
  default     = "nginx-proxy"
}

variable "image" {
  description = "Multipass image alias."
  type        = string
  default     = "24.04"
}

variable "cpus" {
  description = "vCPUs. nginx is not CPU bound; 1 is ample."
  type        = number
  default     = 1
}

variable "memory" {
  description = "RAM for the proxy VM."
  type        = string
  default     = "1G"
}

variable "disk" {
  description = "Disk size for the proxy VM."
  type        = string
  default     = "5G"
}

variable "proxy_lan_ip" {
  description = <<-EOT
    LAN address the proxy is published on.

    Multipass VMs are NAT'd on 10.2.243.0/24 and have no routable LAN address,
    so the host bridges this address to the VM with socat (the lan_bridge role).
  EOT
  type        = string
  default     = "192.168.29.200"
}

variable "proxy_listen_port" {
  description = "Port nginx listens on inside the VM, and the LAN port published."
  type        = number
  default     = 80
}

variable "launch_timeout" {
  description = "Seconds multipass may take to launch before failing."
  type        = number
  default     = 600
}

variable "ssh_public_key_path" {
  description = "Public key injected via cloud-init. Create it with `make ssh-key`."
  type        = string
  default     = "~/.ssh/homelab_iac_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Matching private key, written into the generated inventory."
  type        = string
  default     = "~/.ssh/homelab_iac_ed25519"
}
