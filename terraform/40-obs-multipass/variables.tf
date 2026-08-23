variable "vm_name" {
  description = "Multipass instance hosting Prometheus and Grafana."
  type        = string
  default     = "obs"
}

variable "image" {
  description = "Multipass image for the observability VM."
  type        = string
  default     = "24.04"
}

variable "cpus" {
  description = "vCPUs for the observability VM."
  type        = number
  default     = 2
}

variable "memory" {
  description = <<-EOT
    RAM for the observability VM.

    Prometheus' memory is driven by active series and retention, and Grafana
    adds ~200MB. 6G leaves room for both plus page cache for the TSDB.

    This is a Multipass ALLOCATION, not a reservation: qemu commits pages
    lazily, so the host pays only what the guest actually touches (oracle-db
    holds 6G allocated at ~1.1G resident). That matters on this host, which
    runs four other VMs in 24G.
  EOT
  type        = string
  default     = "6G"
}

variable "disk" {
  description = "Disk for the observability VM. The TSDB is the only thing that grows; 20G holds well over the default retention."
  type        = string
  default     = "20G"
}

variable "launch_timeout" {
  description = "Seconds to allow for `multipass launch`. Cold first boot pulls the image and installs docker."
  type        = number
  default     = 1200
}

variable "prometheus_port" {
  description = "Port Prometheus listens on."
  type        = number
  default     = 9090
}

variable "grafana_port" {
  description = "Port Grafana listens on."
  type        = number
  default     = 3000
}

variable "ssh_public_key_path" {
  description = "Public key injected via cloud-init so Ansible can reach the VM."
  type        = string
  default     = "~/.ssh/homelab_iac_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Matching private key, handed to Ansible through the inventory fragment."
  type        = string
  default     = "~/.ssh/homelab_iac_ed25519"
}
