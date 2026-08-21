variable "vm_name" {
  description = "Multipass instance name for the Oracle XE host."
  type        = string
  default     = "oracle-db"
}

variable "image" {
  description = "Multipass image alias. Oracle XE 21c is supported on Ubuntu 22.04/24.04."
  type        = string
  default     = "24.04"
}

variable "cpus" {
  description = "vCPUs. Oracle XE needs 2 to install in reasonable time."
  type        = number
  default     = 2
}

variable "memory" {
  description = <<-EOT
    RAM. Oracle XE requires >= 2G to start at all.

    6G rather than 4G because the `configure` step builds the SGA/PGA and spikes
    well above steady-state usage; the host has ample headroom and an OOM
    part-way through a 40-minute install is expensive to retry.
  EOT
  type        = string
  default     = "6G"
}

variable "disk" {
  description = <<-EOT
    Disk size.

    Sized for alien's PEAK usage, not the installed footprint. Converting the
    Oracle RPM keeps four copies on disk at once:

      original RPM        2.2G
      extracted tree     12.0G
      generated .deb      2.2G
      installed tree     11.0G   (/opt/oracle)
      ------------------------
      peak              ~27.4G

    A 24G disk fails partway through `dpkg -i` with no space left. 48G leaves
    headroom for datafile growth after the intermediates are cleaned up.
  EOT
  type        = string
  default     = "48G"
}

variable "listener_port" {
  description = "Oracle listener port."
  type        = number
  default     = 1521
}

variable "launch_timeout" {
  description = "Seconds multipass may take to launch before failing."
  type        = number
  default     = 600
}

variable "ssh_public_key_path" {
  description = <<-EOT
    Public key injected via cloud-init for Ansible access.

    Defaults to a dedicated homelab-iac keypair rather than ~/.ssh/id_rsa, which
    does not exist on every host. Create it with `make ssh-key`.
  EOT
  type        = string
  default     = "~/.ssh/homelab_iac_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Matching private key, written into the generated Ansible inventory."
  type        = string
  default     = "~/.ssh/homelab_iac_ed25519"
}
