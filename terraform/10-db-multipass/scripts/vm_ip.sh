#!/usr/bin/env bash
#
# Terraform external data source: emit the Multipass VM's IPv4 as JSON.
# Multipass reports several addresses once k8s/CNI plugins are present, so take
# the first RFC1918 address, which is the NAT interface shared with the k8s
# nodes. The exact range depends on the Multipass driver: the Linux/KVM driver
# hands out 10.x, while the macOS/qemu driver hands out 192.168.x (or 172.16-31.x)
# — so all three private ranges must be accepted, not just 10.x.
#
set -euo pipefail
NAME="${1:?usage: vm_ip.sh <vm-name>}"

# multipass requires client authentication (local.passphrase is set), so any
# user other than the VM owner gets "The client is not authenticated". root
# bypasses it and CI has passwordless sudo, so fall back to sudo. Interactive
# runs as the owner take the first branch and never invoke sudo.
mp() { if multipass "$@" 2>/dev/null; then return 0; else sudo -n multipass "$@"; fi; }

IP=""
for _ in $(seq 1 30); do
    IP=$(mp info "$NAME" --format csv 2>/dev/null \
         | awk -F, 'NR>1{print $3}' \
         | tr ' ' '\n' | grep -oE '^(10\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9.]+|192\.168\.[0-9.]+)$' | head -1 || true)
    [ -n "$IP" ] && break
    sleep 4
done

if [ -z "$IP" ]; then
    echo "{\"error\":\"no IPv4 for $NAME\"}" >&2
    exit 1
fi
printf '{"ip":"%s"}\n' "$IP"
