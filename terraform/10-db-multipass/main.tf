##
## Stack 10 — Oracle XE database on Multipass
##
## Deliberately Multipass rather than libvirt: a Multipass VM joins the
## 10.2.243.0/24 NAT network that the k8s nodes already live on, so WebLogic pods
## can reach the listener directly. The previous libvirt VM sat on
## 192.168.122.0/24 and was unreachable from pods ("No route to host"), which
## drove the whole domain into ADMIN mode.
##
## There is no maintained Terraform provider for Multipass, so the VM lifecycle
## is driven through the CLI via null_resource. State still tracks it, and
## destroy is wired up, so the stack behaves like any other Terraform resource.
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
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    ssh_authorized_key = trimspace(file(var.ssh_public_key_path))
  })
}

# Rendered cloud-init is written out so it can be inspected and diffed.
resource "local_file" "cloud_init" {
  filename        = "${path.module}/.generated/cloud-init-${var.vm_name}.yaml"
  content         = local.cloud_init
  file_permission = "0600"
}

resource "null_resource" "db_vm" {
  triggers = {
    vm_name    = var.vm_name
    cpus       = var.cpus
    memory     = var.memory
    disk       = var.disk
    image      = var.image
    cloud_init = sha256(local.cloud_init)
  }

  # Create only when absent, so re-running the stack is a no-op rather than an error.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if multipass info "${var.vm_name}" >/dev/null 2>&1; then
        echo "[db] ${var.vm_name} already exists — skipping launch"
      else
        echo "[db] launching ${var.vm_name}"
        multipass launch "${var.image}" \
          --name "${var.vm_name}" \
          --cpus "${var.cpus}" \
          --memory "${var.memory}" \
          --disk "${var.disk}" \
          --cloud-init "${local_file.cloud_init.filename}" \
          --timeout ${var.launch_timeout}
      fi

      # A VM reports an IP before its SSH/agent stack is ready; wait for both.
      for i in $(seq 1 60); do
        STATE=$(multipass info "${var.vm_name}" --format csv 2>/dev/null | awk -F, 'NR>1{print $2}')
        IP=$(multipass info "${var.vm_name}" --format csv 2>/dev/null | awk -F, 'NR>1{print $3}')
        if [ "$STATE" = "Running" ] && [ -n "$IP" ]; then
          echo "[db] ${var.vm_name} Running at $IP"
          exit 0
        fi
        echo "[db] waiting ($i): state=$STATE ip=$${IP:-none}"
        sleep 5
      done
      echo "[db] ERROR: ${var.vm_name} did not become Running with an IP" >&2
      exit 1
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      NAME="${self.triggers.vm_name}"
      echo "[db] deleting $NAME"
      multipass delete "$NAME" 2>/dev/null || true
      multipass purge 2>/dev/null || true
    EOT
  }

  depends_on = [local_file.cloud_init]
}

# Read the assigned IP back out so downstream stacks and Ansible can consume it.
data "external" "db_vm_ip" {
  program    = ["/bin/bash", "${path.module}/scripts/vm_ip.sh", var.vm_name]
  depends_on = [null_resource.db_vm]
}

# Ansible inventory fragment — the single source of truth for the DB host.
resource "local_file" "inventory" {
  filename = "${path.module}/.generated/db_inventory.yaml"
  content = yamlencode({
    db = {
      hosts = {
        (var.vm_name) = {
          ansible_host                 = data.external.db_vm_ip.result.ip
          ansible_user                 = "ubuntu"
          ansible_ssh_private_key_file = var.ssh_private_key_path
          oracle_listener_port         = var.listener_port
        }
      }
    }
  })
  file_permission = "0644"
}
