##
## Stack 40 — observability (Prometheus + Grafana) on Multipass
##
## Its own VM and its own stack, deliberately, for three reasons:
##
## 1. THE CLUSTER HAS NO ROOM. kube-prometheus-stack wants 1.5-2.5G; at the
##    time this was written k8s-worker-1 sat at 91% of its memory requests and
##    k8s-master at 64%, with WebLogic already overcommitted on limits. This
##    repo has an OOM episode on record where the scheduler stacked AdminServer
##    onto the small node and killed an in-flight WLST deploy. Monitoring must
##    not be able to do that to the thing it is monitoring.
##
## 2. IT MUST OUTLIVE WHAT IT WATCHES. Metrics are most valuable across a
##    teardown/rebuild of the tiers below. A separate stack means
##    homelab-teardown can destroy the application tiers without touching the
##    history that explains why.
##
## 3. DEPLOY AND TEARDOWN ARE ONE `terraform destroy`. The observability
##    pipeline's DESTROY action removes this stack and nothing else.
##
## Mirrors the null_resource + Multipass-CLI pattern of the other stacks: there
## is no maintained Multipass Terraform provider.
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

        The observability VM needs a key injected via cloud-init so Ansible can
        configure Prometheus and Grafana. Generate it with:

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

resource "null_resource" "obs_vm" {
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
      # check — so fall back to sudo.
      mp() { if multipass "$@" 2>/dev/null; then return 0; else sudo -n multipass "$@"; fi; }

      if mp info "${var.vm_name}" >/dev/null 2>&1; then
        echo "[obs] ${var.vm_name} already exists — skipping launch"
      else
        echo "[obs] launching ${var.vm_name} (this can take a few minutes)"
        # multipass draws a spinner with \r that Terraform's non-TTY log
        # capture turns into one line per frame; send it to a log file instead
        # and only show it if the launch actually fails.
        LAUNCH_LOG=$(mktemp)
        if ! mp launch "${var.image}" \
          --name "${var.vm_name}" \
          --cpus "${var.cpus}" \
          --memory "${var.memory}" \
          --disk "${var.disk}" \
          --cloud-init "${local_file.cloud_init.filename}" \
          --timeout ${var.launch_timeout} >"$LAUNCH_LOG" 2>&1; then
          echo "[obs] ERROR: multipass launch failed:" >&2
          cat "$LAUNCH_LOG" >&2
          rm -f "$LAUNCH_LOG"
          exit 1
        fi
        rm -f "$LAUNCH_LOG"
      fi

      # A VM reports an IP before its SSH/agent stack is ready; wait for both.
      for i in $(seq 1 60); do
        STATE=$(mp info "${var.vm_name}" --format csv 2>/dev/null | awk -F, 'NR>1{print $2}')
        IP=$(mp info "${var.vm_name}" --format csv 2>/dev/null | awk -F, 'NR>1{print $3}')
        if [ "$STATE" = "Running" ] && [ -n "$IP" ]; then
          echo "[obs] ${var.vm_name} Running at $IP"
          break
        fi
        echo "[obs] waiting ($i): state=$STATE ip=$${IP:-none}"
        sleep 5
      done

      # Running-with-an-IP is NOT ready: cloud-init is still installing docker,
      # and the prometheus/grafana roles run `docker` as their first action.
      # Wait for cloud-init's own completion marker instead of racing it.
      for i in $(seq 1 90); do
        if mp exec "${var.vm_name}" -- test -f /var/lib/cloud/obs-prereqs-done 2>/dev/null; then
          echo "[obs] cloud-init finished; docker is installed"
          exit 0
        fi
        echo "[obs] waiting ($i) for cloud-init to finish installing docker"
        sleep 10
      done
      echo "[obs] ERROR: ${var.vm_name} never wrote /var/lib/cloud/obs-prereqs-done" >&2
      exit 1
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      mp() { if multipass "$@" 2>/dev/null; then return 0; else sudo -n multipass "$@"; fi; }
      echo "[obs] deleting ${self.triggers.vm_name}"
      mp delete "${self.triggers.vm_name}" --purge || true
    EOT
  }

  depends_on = [local_file.cloud_init]
}

# The IP is assigned by Multipass, so it can only be read back after creation.
data "external" "obs_vm_ip" {
  program    = ["${path.module}/scripts/vm_ip.sh", var.vm_name]
  depends_on = [null_resource.obs_vm]
}

# Handoff to Ansible. Written as a real inventory fragment so the dynamic
# inventory can merge it without any parsing logic.
resource "local_file" "inventory" {
  filename = "${path.module}/.generated/obs_inventory.yaml"
  content = yamlencode({
    # Group name deliberately differs from the VM name: Ansible warns, and
    # patterns become ambiguous, when a group and a host share one.
    observability = {
      hosts = {
        (var.vm_name) = {
          ansible_host                 = data.external.obs_vm_ip.result.ip
          ansible_user                 = "ubuntu"
          ansible_ssh_private_key_file = local.ssh_private_key_file
          obs_ip                       = data.external.obs_vm_ip.result.ip
          prometheus_port              = var.prometheus_port
          grafana_port                 = var.grafana_port
        }
      }
    }
  })
  file_permission = "0644"
}
