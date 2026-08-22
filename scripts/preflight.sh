#!/usr/bin/env bash
#
# Preflight: verify the toolchain and platform health BEFORE any pipeline stage
# mutates infrastructure. Encodes the failure modes actually observed on this host.
#
# Exit 0 = safe to proceed. Exit 1 = blocking fault (message explains the fix).
#
set -uo pipefail

FAIL=0
WARN=0
ok()   { printf "  \033[32m[ OK ]\033[0m %s\n" "$*"; }
bad()  { printf "  \033[31m[FAIL]\033[0m %s\n" "$*"; FAIL=$((FAIL+1)); }
warn() { printf "  \033[33m[WARN]\033[0m %s\n" "$*"; WARN=$((WARN+1)); }
hdr()  { printf "\n\033[1m== %s ==\033[0m\n" "$*"; }

UPLINK="${OVN_UPLINK_NIC:-enx00e04c096078}"
PRIMARY_NIC="${PRIMARY_NIC:-enp0s31f6}"
PRIMARY_IP="${PRIMARY_IP:-192.168.29.159}"

hdr "Toolchain"
for t in terraform packer ansible-playbook kubectl helm multipass mvn java git; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t present"; else bad "$t missing"; fi
done
# lxc (LXD/MicroCloud) and socat (the lan_bridge role's LAN-publishing) are
# only needed by the Linux LAN-bridge host path, which is skipped entirely on
# hosts that reach nginx directly at its Multipass IP instead — a hard FAIL
# here would block every other host's preflight for a tool it will never use.
for t in lxc socat; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t present"; else warn "$t missing (only needed for the Linux LAN-bridge path)"; fi
done

hdr "Primary NIC (host's only LAN path — must never be disturbed)"
if ! command -v ip >/dev/null 2>&1; then
    # No `ip` command at all (e.g. macOS) means this isn't the Linux host the
    # check was written for — the LAN-bridge role that depends on this NIC is
    # skipped entirely on such hosts, so there is nothing here to protect.
    warn "no 'ip' command — not the Linux LAN-bridge host, skipping this check"
elif ip link show "$PRIMARY_NIC" >/dev/null 2>&1; then
    ok "$PRIMARY_NIC present"
    if ip -4 addr show "$PRIMARY_NIC" | grep -q "$PRIMARY_IP"; then
        ok "$PRIMARY_NIC holds $PRIMARY_IP"
    else
        bad "$PRIMARY_NIC is missing $PRIMARY_IP — refusing to touch networking"
    fi
else
    bad "$PRIMARY_NIC absent"
fi

hdr "MicroCloud / LXD (nginx tier)"
if command -v lxc >/dev/null 2>&1; then
    if sudo lxc info >/dev/null 2>&1; then
        ok "LXD API reachable"
    else
        bad "LXD API unreachable (snap running? user in lxd group?)"
    fi
    # The OVN uplink is a USB NIC with a documented history of carrier flaps.
    if [ -r "/sys/class/net/$UPLINK/carrier" ]; then
        if [ "$(cat "/sys/class/net/$UPLINK/carrier" 2>/dev/null)" = "1" ]; then
            ok "OVN uplink $UPLINK carrier up"
        else
            bad "OVN uplink $UPLINK carrier DOWN — recover: sudo ip link set $UPLINK up"
        fi
    else
        warn "uplink $UPLINK not found (set OVN_UPLINK_NIC to override)"
    fi
fi

hdr "Multipass (database tier)"
if command -v multipass >/dev/null 2>&1; then
    # Multipass requires client authentication (local.passphrase is set), and
    # the CI user has no passphrase of its own. root bypasses it, so fall back
    # to sudo — CI runs as the `jenkins` user with passwordless sudo, while an
    # interactive run as the VM owner succeeds on the first branch.
    if multipass list >/dev/null 2>&1 || sudo -n multipass list >/dev/null 2>&1; then
        ok "multipass daemon responding"
    else
        bad "multipass daemon not responding"
    fi
fi

hdr "Kubernetes (WebLogic tier)"
# MASTER_VM is exported by the Jenkinsfile's "Start VMs" stage (the k8s
# control-plane VM name from terraform var.master_name); empty when run
# standalone outside the pipeline.
MASTER_VM_STATE=""
if [ -n "${MASTER_VM:-}" ] && command -v multipass >/dev/null 2>&1; then
    MASTER_VM_STATE=$(multipass info "$MASTER_VM" --format csv 2>/dev/null | awk -F, 'NR>1{print $2}')
fi
if kubectl cluster-info >/dev/null 2>&1; then
    ok "k8s API reachable"
    NOTREADY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{c++} END{print c+0}')
    if [ "$NOTREADY" -eq 0 ]; then
        ok "all k8s nodes Ready"
    else
        # Flannel subnet.env corruption after a node restart is the usual cause.
        bad "$NOTREADY k8s node(s) NotReady — check Flannel: kubectl -n kube-flannel get pods"
    fi
    # Domain CRD version differs per kind: domains=v9, clusters=v1.
    #
    # Capture first, then grep the variable — NOT `kubectl ... | grep -q`.
    # Under `set -o pipefail`, grep -q exits the instant it finds a match,
    # closing its end of the pipe while kubectl may still be writing further
    # output; kubectl then dies of SIGPIPE and pipefail reports THAT exit
    # code for the whole pipeline, masking grep's own successful match. This
    # made the check fail intermittently even with the CRDs genuinely
    # installed — flaky in a way that looked like a real absence.
    API_RESOURCES="$(kubectl api-resources 2>/dev/null || true)"
    if grep -q "weblogic.oracle" <<< "$API_RESOURCES"; then
        ok "WebLogic operator CRDs installed"
    else
        bad "WebLogic operator CRDs absent — install the operator first"
    fi
elif [ -n "${MASTER_VM:-}" ] && [ -z "$MASTER_VM_STATE" ]; then
    # The control-plane VM doesn't exist at all -- this is a from-scratch
    # bootstrap (e.g. right after a teardown), not a broken existing cluster.
    # "Apply infrastructure" (APPLY=true) is what creates it; failing here
    # would make it impossible to ever rebuild the stack from nothing.
    warn "k8s API unreachable -- $MASTER_VM does not exist yet, will be created by Apply infrastructure (APPLY=true)"
else
    bad "k8s API unreachable (multipass VMs started? kubeconfig valid?)"
fi

hdr "SSH key for VM provisioning"
# Terraform injects this key via cloud-init so Ansible can reach new VMs.
# Note: Terraform's file() does NOT expand "~", so the stacks use pathexpand();
# this check mirrors that behaviour.
SSH_KEY="${SSH_KEY:-$HOME/.ssh/homelab_iac_ed25519}"
if [ -f "${SSH_KEY}.pub" ]; then
    ok "$(basename "${SSH_KEY}").pub present"
    if [ -f "$SSH_KEY" ]; then
        # GNU stat (-c) vs BSD/macOS stat (-f): try GNU first, fall back to BSD.
        PERM=$(stat -c '%a' "$SSH_KEY" 2>/dev/null || stat -f '%OLp' "$SSH_KEY" 2>/dev/null)
        if [ "$PERM" = "600" ]; then
            ok "private key permissions 600"
        else
            warn "private key is $PERM, expected 600 — ssh may refuse it"
        fi
    else
        bad "public key exists but private key $SSH_KEY is missing"
    fi
else
    bad "SSH keypair missing (${SSH_KEY}.pub) — create it with: make ssh-key"
fi

hdr "Disk headroom"
# GNU df (--output=avail -BG) vs BSD/macOS df: -g reports whole gigabytes and
# has no --output flag, so fall back to counting a fixed column instead.
AVAIL=$(df --output=avail -BG / 2>/dev/null | tail -1 | tr -dc '0-9')
[ -z "$AVAIL" ] && AVAIL=$(df -g / 2>/dev/null | tail -1 | awk '{print $4}')
if [ "${AVAIL:-0}" -ge 20 ]; then
    ok "root filesystem has ${AVAIL}G free"
else
    warn "only ${AVAIL}G free on / — WLS images are ~2.4G each"
fi

hdr "Result"
if [ "$FAIL" -gt 0 ]; then
    printf "  \033[31m%d blocking fault(s), %d warning(s)\033[0m\n\n" "$FAIL" "$WARN"
    exit 1
fi
printf "  \033[32mpreflight passed\033[0m (%d warning(s))\n\n" "$WARN"
exit 0
