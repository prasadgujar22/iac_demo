##
## Stack 30 — nginx reverse proxy on Multipass
##
## Replaces the MicroCloud/LXD variant. Two reasons:
##
## 1. RELIABILITY. LXD's `local` (ZFS) and MicroCeph's OSD pools are both
##    loop-file backed, and the loop devices are NOT recreated on boot. After a
##    kernel upgrade the LXD daemon crash-looped on
##      zpool import local: no such pool available
##    and 97 Ceph pgs sat inactive, taking the nginx VM offline with them.
##    Multipass has no such failure mode: `multipass` restores instances itself.
##
## 2. SIMPLER NETWORK PATH. A Multipass VM sits on 10.2.243.0/24 — the SAME
##    subnet as the k8s nodes — so nginx reaches the WebLogic NodePorts
##    DIRECTLY. The MicroCloud VM could not (separate OVN subnet) and had to
##    hairpin out to the physical LAN and back through host socat bridges.
##
##      before:  client -> OVN fwd -> nginx(OVN) -> LAN .201/.202 -> socat -> NodePort
##      after:   client -> host socat -> nginx(10.2.243.x) -> NodePort directly
##
## The one thing Multipass does NOT give us is a routable LAN address, so the
## host still publishes the proxy via socat (the lan_bridge Ansible role).
##

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    null     = { source = "hashicorp/null", version = "~> 3.2" }
    local    = { source = "hashicorp/local", version = "~> 2.4" }
    external = { source = "hashicorp/external", version = "~> 2.3" }
  }
}

locals {
  # pathexpand() is REQUIRED: Terraform's file() does not expand "~".
  ssh_public_key_file  = pathexpand(var.ssh_public_key_path)
  ssh_private_key_file = pathexpand(var.ssh_private_key_path)

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    ssh_authorized_key = fileexists(local.ssh_public_key_file) ? trimspace(file(local.ssh_public_key_file)) : "MISSING-SSH-KEY"
  })
}

resource "terraform_data" "ssh_key_precondition" {
  lifecycle {
    precondition {
      condition     = fileexists(local.ssh_public_key_file)
      error_message = <<-EOT
        SSH public key not found: ${local.ssh_public_key_file}

        The proxy VM needs a key injected via cloud-init so Ansible can
        configure nginx. Generate it with:

            make ssh-key
      EOT
    }
  }
}

resource "local_file" "cloud_init" {
  filename        = "${path.module}/.generated/cloud-init-${var.vm_name}.yaml"
  content         = local.cloud_init
  file_permission = "0600"

  depends_on = [terraform_data.ssh_key_precondition]
}

# No maintained Multipass provider exists, so the CLI is driven directly.
# Guarded so re-apply is a no-op rather than an error.
resource "null_resource" "proxy_vm" {
  triggers = {
    vm_name   = var.vm_name
    cpus      = var.cpus
    memory    = var.memory
    disk      = var.disk
    image     = var.image
    init_hash = sha256(local.cloud_init)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if multipass info ${var.vm_name} >/dev/null 2>&1; then
        echo "[proxy] ${var.vm_name} already exists, skipping launch"
      else
        echo "[proxy] launching ${var.vm_name}"
        multipass launch ${var.image} \
          --name ${var.vm_name} \
          --cpus ${var.cpus} \
          --memory ${var.memory} \
          --disk ${var.disk} \
          --cloud-init ${local_file.cloud_init.filename} \
          --timeout ${var.launch_timeout}
      fi
      multipass info ${var.vm_name} --format csv | tail -1 | awk -F, '{print "[proxy] " $1 " " $2 " at " $3}'
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      echo "[proxy] deleting ${self.triggers.vm_name}"
      multipass delete ${self.triggers.vm_name} --purge || true
    EOT
  }

  depends_on = [local_file.cloud_init]
}

# The IP is assigned by Multipass, so it can only be read back after creation.
data "external" "proxy_vm_ip" {
  program    = ["${path.module}/scripts/vm_ip.sh", var.vm_name]
  depends_on = [null_resource.proxy_vm]
}

# Handoff to Ansible. Written as a real inventory fragment so the dynamic
# inventory can merge it without any parsing logic.
resource "local_file" "inventory" {
  filename = "${path.module}/.generated/nginx_inventory.yaml"
  content = yamlencode({
    nginx = {
      hosts = {
        (var.vm_name) = {
          ansible_host                 = data.external.proxy_vm_ip.result.ip
          ansible_user                 = "ubuntu"
          ansible_ssh_private_key_file = local.ssh_private_key_file
          proxy_internal_ip            = data.external.proxy_vm_ip.result.ip
          proxy_lan_ip                 = var.proxy_lan_ip
          proxy_listen_port            = var.proxy_listen_port
        }
      }
    }
  })
  file_permission = "0644"
}
