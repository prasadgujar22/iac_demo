variable "instance_name" {
  description = "LXD instance name for the nginx reverse proxy."
  type        = string
  default     = "webserver"
}

variable "image" {
  description = "LXD image alias for the proxy VM."
  type        = string
  default     = "ubuntu:24.04"
}

variable "cpus" {
  type        = string
  description = "vCPUs for the proxy VM."
  default     = "2"
}

variable "memory" {
  type        = string
  description = "RAM for the proxy VM."
  default     = "1GiB"
}

variable "disk_size" {
  type        = string
  description = "Root disk size."
  default     = "8GiB"
}

variable "storage_pool" {
  description = "LXD storage pool. MicroCloud provisions 'remote' (Ceph) and 'local' (ZFS)."
  type        = string
  default     = "remote"
}

variable "ovn_network" {
  description = "OVN network the instance attaches to."
  type        = string
  default     = "default"
}

variable "proxy_internal_ip" {
  description = <<-EOT
    Static address on the OVN subnet.

    Must be static: an OVN network forward targets a fixed address, and a moving
    DHCP lease silently breaks LAN publishing.
  EOT
  type        = string
  default     = "10.184.135.2"
}

variable "proxy_lan_ip" {
  description = "LAN address published by the OVN forward. Must fall inside the reserved range."
  type        = string
  default     = "192.168.29.200"
}

variable "proxy_listen_port" {
  description = "LAN port for the reverse proxy."
  type        = number
  default     = 80
}

variable "ssh_public_key_path" {
  description = "Public key injected via cloud-init."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}
