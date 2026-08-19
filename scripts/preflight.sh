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
for t in terraform packer ansible-playbook kubectl helm multipass lxc socat mvn java git; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t present"; else bad "$t missing"; fi
done

hdr "Primary NIC (host's only LAN path — must never be disturbed)"
if ip link show "$PRIMARY_NIC" >/dev/null 2>&1; then
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
    if multipass list >/dev/null 2>&1; then
        ok "multipass daemon responding"
    else
        bad "multipass daemon not responding"
    fi
fi

hdr "Kubernetes (WebLogic tier)"
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
    if kubectl api-resources 2>/dev/null | grep -q "weblogic.oracle"; then
        ok "WebLogic operator CRDs installed"
    else
        bad "WebLogic operator CRDs absent — install the operator first"
    fi
else
    bad "k8s API unreachable (multipass VMs started? kubeconfig valid?)"
fi

hdr "Disk headroom"
AVAIL=$(df --output=avail -BG / 2>/dev/null | tail -1 | tr -dc '0-9')
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
