##
## Stack 30 — nginx reverse proxy on MicroCloud (LXD + OVN)
##
## Two OVN-specific constraints are encoded here:
##
## 1. An LXD `proxy` device with nat=true does NOT work on OVN networks — that
##    flag only applies to bridge networks such as lxdbr0. Publishing to the LAN
##    must use OVN `network forward` instead.
##
## 2. A network forward requires the instance to hold a STATIC address. DHCP
##    leases move and silently break the forward, so eth0 is overridden with a
##    pinned ipv4.address.
##
## The instance is a VM (not a container) to match the existing deployment and to
## keep nginx isolated from the host kernel.
##

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    lxd   = { source = "terraform-lxd/lxd", version = "~> 2.5" }
    local = { source = "hashicorp/local", version = "~> 2.4" }
  }
}

provider "lxd" {
  generate_client_certificates = true
  accept_remote_certificate    = true
}

locals {
  # Reserve the forward address as a /32 route on the uplink so OVN answers ARP
  # for it on the physical segment.
  forward_route = "${var.proxy_lan_ip}/32"

  # pathexpand() is REQUIRED: Terraform's file() does not expand "~".
  ssh_public_key_file = pathexpand(var.ssh_public_key_path)
}

# ---------------------------------------------------------------------------
# nginx VM
# ---------------------------------------------------------------------------
resource "lxd_instance" "nginx" {
  name  = var.instance_name
  image = var.image
  type  = "virtual-machine"

  # Provider v2 requires limits.* in a dedicated map, not inside config.
  limits = {
    cpu    = var.cpus
    memory = var.memory
  }

  config = {
    "user.managed-by" = "terraform"
    # cloud-init installs nginx so Ansible has something to configure; the
    # package set is deliberately minimal.
    "cloud-init.user-data" = <<-EOT
      #cloud-config
      package_update: true
      packages:
        - nginx
      ssh_authorized_keys:
        - ${trimspace(file(local.ssh_public_key_file))}
      runcmd:
        - systemctl enable --now nginx
    EOT
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      pool = var.storage_pool
      path = "/"
      size = var.disk_size
    }
  }

  # Static address: mandatory for the network forward to remain valid.
  device {
    name = "eth0"
    type = "nic"
    properties = {
      network        = var.ovn_network
      "ipv4.address" = var.proxy_internal_ip
    }
  }
}

# ---------------------------------------------------------------------------
# Publish to the LAN via OVN network forward
# ---------------------------------------------------------------------------
resource "lxd_network_forward" "proxy" {
  network        = var.ovn_network
  listen_address = var.proxy_lan_ip
  description    = "nginx reverse proxy -> WebLogic cluster (JSESSIONID route-ID affinity)"

  ports = [
    {
      protocol       = "tcp"
      listen_port    = tostring(var.proxy_listen_port)
      target_port    = "80"
      target_address = var.proxy_internal_ip
      description    = "HTTP reverse proxy"
    },
  ]

  depends_on = [lxd_instance.nginx]
}

# ---------------------------------------------------------------------------
# Ansible handoff
# ---------------------------------------------------------------------------
resource "local_file" "inventory" {
  filename = "${path.module}/.generated/nginx_inventory.yaml"
  content = yamlencode({
    nginx = {
      hosts = {
        (var.instance_name) = {
          # Reached through the LXD socket rather than SSH, which avoids
          # depending on the guest's sshd being up.
          ansible_connection = "community.general.lxd"
          ansible_lxd_remote = "local"
          proxy_lan_ip       = var.proxy_lan_ip
          proxy_listen_port  = var.proxy_listen_port
          proxy_internal_ip  = var.proxy_internal_ip
        }
      }
    }
  })
  file_permission = "0644"
}
