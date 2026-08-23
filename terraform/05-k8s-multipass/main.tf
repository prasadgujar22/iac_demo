##
## Stack 05 — Kubernetes cluster (kubeadm) on Multipass
##
## Not present in the upstream repo: `terraform/20-wls-k8s` configures a
## WebLogic domain against an ALREADY-EXISTING cluster; it never creates the
## master/worker VMs. This stack fills that gap so 20-wls-k8s has something to
## target — one control-plane node and one or more workers, joined with
## kubeadm and networked with Flannel, with the WebLogic Kubernetes Operator
## installed at the end.
##
## Mirrors the null_resource + Multipass-CLI pattern used by 10-db-multipass
## and 30-nginx-multipass: there is no maintained Multipass Terraform provider.
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
  ssh_public_key_file  = pathexpand(var.ssh_public_key_path)
  ssh_private_key_file = pathexpand(var.ssh_private_key_path)
  kubeconfig_file       = pathexpand(var.kubeconfig_path)

  master_cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    hostname            = var.master_name
    ssh_authorized_key  = fileexists(local.ssh_public_key_file) ? trimspace(file(local.ssh_public_key_file)) : "MISSING-SSH-KEY"
    k8s_minor_version   = var.k8s_minor_version
  })

  worker_cloud_init = {
    for name in var.worker_names : name => templatefile("${path.module}/cloud-init.yaml.tftpl", {
      hostname           = name
      ssh_authorized_key = fileexists(local.ssh_public_key_file) ? trimspace(file(local.ssh_public_key_file)) : "MISSING-SSH-KEY"
      k8s_minor_version  = var.k8s_minor_version
    })
  }

  # Shared shell helpers, inlined into every provisioner command: multipass
  # requires client auth (local.passphrase set); root bypasses it and CI has
  # passwordless sudo, so fall back to sudo for any non-owner caller.
  #
  # mp_wait bounds a call that can hang: multipass 1.16.3's client has been
  # seen spinning at 100% CPU forever after the remote command already
  # finished (`exec ... kubeadm init` -- control plane fully up on the VM,
  # client never returned), which wedges the whole pipeline because a
  # local-exec provisioner has no timeout of its own. Returns 124 on a
  # watchdog kill, mirroring GNU timeout (not shipped on macOS, and not
  # installed here), so callers can tell "client hung" from "command really
  # failed" and re-check the VM's actual state before giving up.
  #
  # Output is staged through temp files instead of the inherited pipe so a
  # killed client that somehow outlives us can never hold Terraform's
  # provisioner pipe open; stdout and stderr stay separate so callers keep
  # their usual redirection semantics.
  mp_helper = <<-EOT
    mp() { if multipass "$@" 2>/dev/null; then return 0; else sudo -n multipass "$@"; fi; }

    mp_wait() {
      local secs="$1"; shift
      local out err pid rc waited
      out="$(mktemp -t mp_wait_out)"
      err="$(mktemp -t mp_wait_err)"
      mp "$@" >"$out" 2>"$err" &
      pid=$!
      waited=0
      rc=0
      while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
          pkill -P "$pid" 2>/dev/null || true
          kill "$pid" 2>/dev/null || true
          sleep 2
          pkill -9 -P "$pid" 2>/dev/null || true
          kill -9 "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          cat "$out"; cat "$err" >&2; rm -f "$out" "$err"
          return 124
        fi
        sleep 2
        waited=$((waited + 2))
      done
      wait "$pid" || rc=$?
      cat "$out"; cat "$err" >&2; rm -f "$out" "$err"
      return "$rc"
    }
  EOT
}

resource "terraform_data" "ssh_key_precondition" {
  lifecycle {
    precondition {
      condition     = fileexists(local.ssh_public_key_file)
      error_message = <<-EOT
        SSH public key not found: ${local.ssh_public_key_file}

        The k8s nodes need a key injected via cloud-init. Generate it with:

            make ssh-key
      EOT
    }
  }
}

resource "local_file" "master_cloud_init" {
  filename        = "${path.module}/.generated/cloud-init-${var.master_name}.yaml"
  content         = local.master_cloud_init
  file_permission = "0600"
  depends_on      = [terraform_data.ssh_key_precondition]
}

resource "local_file" "worker_cloud_init" {
  for_each        = local.worker_cloud_init
  filename        = "${path.module}/.generated/cloud-init-${each.key}.yaml"
  content         = each.value
  file_permission = "0600"
  depends_on      = [terraform_data.ssh_key_precondition]
}

# ---------------------------------------------------------------------------
# VMs
# ---------------------------------------------------------------------------

resource "null_resource" "master_vm" {
  triggers = {
    vm_name    = var.master_name
    cpus       = var.master_cpus
    memory     = var.master_memory
    disk       = var.master_disk
    image      = var.image
    cloud_init = sha256(local.master_cloud_init)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.mp_helper}
      if mp info "${var.master_name}" >/dev/null 2>&1; then
        echo "[k8s] ${var.master_name} already exists — skipping launch"
      else
        echo "[k8s] launching ${var.master_name}"
        mp launch "${var.image}" \
          --name "${var.master_name}" \
          --cpus "${var.master_cpus}" \
          --memory "${var.master_memory}" \
          --disk "${var.master_disk}" \
          --cloud-init "${local_file.master_cloud_init.filename}" \
          --timeout ${var.launch_timeout}
      fi
      for i in $(seq 1 60); do
        STATE=$(mp info "${var.master_name}" --format csv 2>/dev/null | awk -F, 'NR>1{print $2}')
        IP=$(mp info "${var.master_name}" --format csv 2>/dev/null | awk -F, 'NR>1{print $3}')
        if [ "$STATE" = "Running" ] && [ -n "$IP" ]; then
          echo "[k8s] ${var.master_name} Running at $IP"
          exit 0
        fi
        echo "[k8s] waiting ($i): state=$STATE ip=$${IP:-none}"
        sleep 5
      done
      echo "[k8s] ERROR: ${var.master_name} did not become Running with an IP" >&2
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
      echo "[k8s] deleting ${self.triggers.vm_name}"
      mp delete "${self.triggers.vm_name}" --purge 2>/dev/null || true
    EOT
  }

  depends_on = [local_file.master_cloud_init]
}

resource "null_resource" "worker_vm" {
  for_each = toset(var.worker_names)

  triggers = {
    vm_name    = each.key
    cpus       = var.worker_cpus
    memory     = var.worker_memory
    disk       = var.worker_disk
    image      = var.image
    cloud_init = sha256(local.worker_cloud_init[each.key])
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.mp_helper}
      if mp info "${each.key}" >/dev/null 2>&1; then
        echo "[k8s] ${each.key} already exists — skipping launch"
      else
        echo "[k8s] launching ${each.key}"
        mp launch "${var.image}" \
          --name "${each.key}" \
          --cpus "${var.worker_cpus}" \
          --memory "${var.worker_memory}" \
          --disk "${var.worker_disk}" \
          --cloud-init "${local_file.worker_cloud_init[each.key].filename}" \
          --timeout ${var.launch_timeout}
      fi
      for i in $(seq 1 60); do
        STATE=$(mp info "${each.key}" --format csv 2>/dev/null | awk -F, 'NR>1{print $2}')
        IP=$(mp info "${each.key}" --format csv 2>/dev/null | awk -F, 'NR>1{print $3}')
        if [ "$STATE" = "Running" ] && [ -n "$IP" ]; then
          echo "[k8s] ${each.key} Running at $IP"
          exit 0
        fi
        echo "[k8s] waiting ($i): state=$STATE ip=$${IP:-none}"
        sleep 5
      done
      echo "[k8s] ERROR: ${each.key} did not become Running with an IP" >&2
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
      echo "[k8s] deleting ${self.triggers.vm_name}"
      mp delete "${self.triggers.vm_name}" --purge 2>/dev/null || true
    EOT
  }

  # Serialized after master_vm on purpose: both VMs' cloud-init grabs
  # whatever IP DHCP just handed enp0s1 and pins it statically with no
  # uniqueness check (see cloud-init.yaml.tftpl) -- launching concurrently
  # let their DHCP requests race and get the SAME address handed to both,
  # permanently colliding once pinned. Serializing also avoids both VMs'
  # cold, cache-less apt installs contending for CPU/network at once.
  depends_on = [local_file.worker_cloud_init, null_resource.master_vm]
}

data "external" "master_vm_ip" {
  program    = ["${path.module}/scripts/vm_ip.sh", var.master_name]
  depends_on = [null_resource.master_vm]
}

data "external" "worker_vm_ip" {
  for_each   = toset(var.worker_names)
  program    = ["${path.module}/scripts/vm_ip.sh", each.key]
  depends_on = [null_resource.worker_vm]
}

# ---------------------------------------------------------------------------
# kubeadm init (control plane) + Flannel CNI
# ---------------------------------------------------------------------------

resource "null_resource" "kubeadm_init" {
  triggers = {
    master_ip = data.external.master_vm_ip.result.ip
    pod_cidr  = var.pod_cidr
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.mp_helper}
      MASTER_IP="${data.external.master_vm_ip.result.ip}"

      if mp_wait 60 exec "${var.master_name}" -- test -f /etc/kubernetes/admin.conf >/dev/null 2>&1; then
        echo "[k8s] control plane already initialised on ${var.master_name}"
      else
        echo "[k8s] running kubeadm init on ${var.master_name} ($MASTER_IP)"
        RC=0
        mp_wait "${var.kubeadm_timeout}" exec "${var.master_name}" -- sudo kubeadm init \
          --pod-network-cidr="${var.pod_cidr}" \
          --apiserver-advertise-address="$MASTER_IP" \
          --node-name="${var.master_name}" || RC=$?
        if [ "$RC" -ne 0 ]; then
          # A non-zero client exit does NOT mean kubeadm failed -- when the
          # multipass client hangs (see mp_wait) the control plane is already
          # up and the watchdog just killed a stuck client. Ask the VM.
          if mp_wait 60 exec "${var.master_name}" -- test -f /etc/kubernetes/admin.conf >/dev/null 2>&1; then
            echo "[k8s] WARN: multipass exec returned $RC (124 = watchdog kill), but /etc/kubernetes/admin.conf exists — control plane is up, continuing"
          else
            echo "[k8s] ERROR: kubeadm init failed (exit $RC) and ${var.master_name} has no /etc/kubernetes/admin.conf" >&2
            exit 1
          fi
        fi
        mp exec "${var.master_name}" -- bash -c '
          mkdir -p "$HOME/.kube"
          sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
          sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
        '
      fi

      echo "[k8s] applying Flannel CNI"
      RC=1
      for attempt in 1 2 3; do
        RC=0
        mp_wait 300 exec "${var.master_name}" -- sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
          apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml || RC=$?
        if [ "$RC" -eq 0 ]; then break; fi
        echo "[k8s] Flannel apply attempt $attempt returned $RC — retrying (apply is idempotent)"
        sleep 10
      done
      if [ "$RC" -ne 0 ]; then
        echo "[k8s] ERROR: Flannel apply failed after 3 attempts (exit $RC)" >&2
        exit 1
      fi

      echo "[k8s] waiting for control-plane node Ready"
      for i in $(seq 1 ${floor(var.kubeadm_timeout / 5)}); do
        READY=$(mp_wait 60 exec "${var.master_name}" -- sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
          get node "${var.master_name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$READY" = "True" ]; then
          echo "[k8s] ${var.master_name} Ready"
          # This homelab has no dedicated worker capacity to spare -- the
          # control-plane node must also run WLS pods, so drop the default
          # kubeadm NoSchedule taint. Idempotent: already-untainted is a
          # harmless "not found" from kubectl, swallowed by || true.
          echo "[k8s] removing control-plane NoSchedule taint from ${var.master_name}"
          mp exec "${var.master_name}" -- sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
            taint nodes "${var.master_name}" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
          exit 0
        fi
        echo "[k8s] waiting ($i) for ${var.master_name} Ready: $${READY:-unknown}"
        sleep 5
      done
      echo "[k8s] ERROR: ${var.master_name} did not become Ready in time" >&2
      exit 1
    EOT
  }

  depends_on = [data.external.master_vm_ip]
}

# ---------------------------------------------------------------------------
# kubeadm join (workers)
# ---------------------------------------------------------------------------

resource "null_resource" "kubeadm_join" {
  for_each = toset(var.worker_names)

  triggers = {
    worker_ip = data.external.worker_vm_ip[each.key].result.ip
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.mp_helper}
      if mp_wait 60 exec "${each.key}" -- test -f /etc/kubernetes/kubelet.conf >/dev/null 2>&1; then
        echo "[k8s] ${each.key} already joined"
      else
        echo "[k8s] fetching join command from ${var.master_name}"
        JOIN_CMD=$(mp_wait 300 exec "${var.master_name}" -- sudo kubeadm token create --print-join-command)
        echo "[k8s] joining ${each.key}"
        RC=0
        mp_wait "${var.kubeadm_timeout}" exec "${each.key}" -- sudo bash -c "$JOIN_CMD" || RC=$?
        if [ "$RC" -ne 0 ]; then
          # Same client-hang caveat as kubeadm init above: a joined worker
          # writes /etc/kubernetes/kubelet.conf, so let the VM decide.
          if mp_wait 60 exec "${each.key}" -- test -f /etc/kubernetes/kubelet.conf >/dev/null 2>&1; then
            echo "[k8s] WARN: multipass exec returned $RC (124 = watchdog kill), but ${each.key} has /etc/kubernetes/kubelet.conf — joined, continuing"
          else
            echo "[k8s] ERROR: kubeadm join failed on ${each.key} (exit $RC)" >&2
            exit 1
          fi
        fi
      fi
    EOT
  }

  depends_on = [null_resource.kubeadm_init, data.external.worker_vm_ip]
}

# ---------------------------------------------------------------------------
# kubeconfig handoff to the host
# ---------------------------------------------------------------------------

resource "null_resource" "kubeconfig_local" {
  triggers = {
    master_ip = data.external.master_vm_ip.result.ip
    always    = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      ${local.mp_helper}
      mkdir -p "$(dirname "${local.kubeconfig_file}")"
      mkdir -p "${path.module}/.generated"
      mp exec "${var.master_name}" -- sudo cat /etc/kubernetes/admin.conf > "${path.module}/.generated/admin.conf"

      DEST="${local.kubeconfig_file}"
      if [ -s "$DEST" ]; then
        cp "$DEST" "$DEST.bak.$(date +%s)" 2>/dev/null || true
        KUBECONFIG="${path.module}/.generated/admin.conf:$DEST" kubectl config view --flatten > /tmp/homelab-iac-kubeconfig-merged.yaml
      else
        cp "${path.module}/.generated/admin.conf" /tmp/homelab-iac-kubeconfig-merged.yaml
      fi
      mv /tmp/homelab-iac-kubeconfig-merged.yaml "$DEST"
      chmod 600 "$DEST"
      KUBECONFIG="$DEST" kubectl config use-context kubernetes-admin@kubernetes
      echo "[k8s] kubeconfig written to $DEST"
    EOT
  }

  depends_on = [null_resource.kubeadm_join]
}

# ---------------------------------------------------------------------------
# WebLogic Kubernetes Operator (Helm)
# ---------------------------------------------------------------------------

resource "null_resource" "wls_operator" {
  count = var.install_weblogic_operator ? 1 : 0

  triggers = {
    version = var.weblogic_operator_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${local.kubeconfig_file}"
      kubectl get ns weblogic-operator-system >/dev/null 2>&1 || kubectl create ns weblogic-operator-system
      if helm status weblogic-operator -n weblogic-operator-system >/dev/null 2>&1; then
        echo "[k8s] weblogic-operator already installed"
      else
        helm repo add weblogic-operator https://oracle.github.io/weblogic-kubernetes-operator/charts --force-update
        helm repo update weblogic-operator
        helm install weblogic-operator weblogic-operator/weblogic-operator \
          --namespace weblogic-operator-system \
          --version "${var.weblogic_operator_version}" \
          --set domainNamespaceSelectionStrategy=LabelSelector \
          --set domainNamespaceLabelSelector=weblogic-operator=enabled \
          --wait --timeout 5m
      fi
    EOT
  }

  depends_on = [null_resource.kubeconfig_local]
}
