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
  # pathexpand() is REQUIRED: Terraform's file() does not expand "~", and fails
  # with 'no file exists at "~/.ssh/..."' even when the file is present.
  ssh_public_key_file  = pathexpand(var.ssh_public_key_path)
  ssh_private_key_file = pathexpand(var.ssh_private_key_path)

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    # Guarded so a missing key surfaces via the precondition below (which has an
    # actionable message) instead of an opaque file() evaluation error.
    ssh_authorized_key = fileexists(local.ssh_public_key_file) ? trimspace(file(local.ssh_public_key_file)) : "MISSING-SSH-KEY"
  })
}

# Fail early with an actionable message rather than a bare file() error.
resource "terraform_data" "ssh_key_precondition" {
  lifecycle {
    precondition {
      condition     = fileexists(local.ssh_public_key_file)
      error_message = <<-EOT
        SSH public key not found: ${local.ssh_public_key_file}

        The database VM needs a key injected via cloud-init so Ansible can
        connect. Generate the dedicated homelab-iac keypair:

            make ssh-key

        or point at an existing key:

            terraform apply -var ssh_public_key_path=~/.ssh/other.pub \
                            -var ssh_private_key_path=~/.ssh/other
      EOT
    }
  }
}

# Rendered cloud-init is written out so it can be inspected and diffed.
resource "local_file" "cloud_init" {
  filename        = "${path.module}/.generated/cloud-init-${var.vm_name}.yaml"
  content         = local.cloud_init
  file_permission = "0600"

  # Ensures the SSH-key precondition is evaluated before we render cloud-init.
  depends_on = [terraform_data.ssh_key_precondition]
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
      # multipass requires client authentication (local.passphrase is set).
      # CI runs as a user that is not authenticated, while root bypasses the
      # check — so fall back to sudo. Without this, destroy provisioners fail
      # silently and leave VMs running with no state to track them.
      mp() { if multipass "$@" 2>/dev/null; then return 0; else sudo -n multipass "$@"; fi; }
      if mp info "${var.vm_name}" >/dev/null 2>&1; then
        echo "[db] ${var.vm_name} already exists — skipping launch"
      else
        echo "[db] launching ${var.vm_name}"
        mp launch "${var.image}" \
          --name "${var.vm_name}" \
          --cpus "${var.cpus}" \
          --memory "${var.memory}" \
          --disk "${var.disk}" \
          --cloud-init "${local_file.cloud_init.filename}" \
          --timeout ${var.launch_timeout}
      fi

      # A VM reports an IP before its SSH/agent stack is ready; wait for both.
      for i in $(seq 1 60); do
        STATE=$(mp info "${var.vm_name}" --format csv 2>/dev/null | awk -F, 'NR>1{print $2}')
        IP=$(mp info "${var.vm_name}" --format csv 2>/dev/null | awk -F, 'NR>1{print $3}')
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
      mp() { if multipass "$@" 2>/dev/null; then return 0; else sudo -n multipass "$@"; fi; }
      # multipass requires client authentication (local.passphrase is set).
      # CI runs as a user that is not authenticated, while root bypasses the
      # check — so fall back to sudo. Without this, destroy provisioners fail
      # silently and leave VMs running with no state to track them.
      mp() { if multipass "$@" 2>/dev/null; then return 0; else sudo -n multipass "$@"; fi; }
      NAME="${self.triggers.vm_name}"
      echo "[db] deleting $NAME"
      mp delete "$NAME" 2>/dev/null || true
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
          ansible_ssh_private_key_file = local.ssh_private_key_file
          oracle_listener_port         = var.listener_port
        }
      }
    }
  })
  file_permission = "0644"
}
