#!/usr/bin/env bash
#
# Terraform external data source: emit the Multipass VM's IPv4 as JSON.
# Multipass reports several addresses once k8s/CNI plugins are present, so take
# the first 10.x address, which is the NAT interface shared with the k8s nodes.
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
         | tr ' ' '\n' | grep -oE '^10\.[0-9.]+$' | head -1 || true)
    [ -n "$IP" ] && break
    sleep 4
done

if [ -z "$IP" ]; then
    echo "{\"error\":\"no IPv4 for $NAME\"}" >&2
    exit 1
fi
printf '{"ip":"%s"}\n' "$IP"
