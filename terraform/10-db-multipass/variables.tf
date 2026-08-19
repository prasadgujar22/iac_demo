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
  description = "RAM. Oracle XE requires >= 2G; 4G avoids swap thrash during install."
  type        = string
  default     = "4G"
}

variable "disk" {
  description = "Disk size. The XE installation alone consumes ~11G."
  type        = string
  default     = "24G"
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
  description = "Public key injected via cloud-init for Ansible access."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "Matching private key, written into the generated inventory."
  type        = string
  default     = "~/.ssh/id_rsa"
}
