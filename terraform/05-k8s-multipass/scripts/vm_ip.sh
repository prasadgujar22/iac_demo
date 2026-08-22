#!/usr/bin/env bash
#
# Terraform external data source: report a Multipass VM's IPv4 address as JSON.
# Must emit ONLY a JSON object on stdout, so all diagnostics go to stderr.
#
set -euo pipefail

# multipass needs client auth (local.passphrase set); root bypasses it and CI
# has passwordless sudo. Interactive owner runs take the first branch.
mp() { if multipass "$@" 2>/dev/null; then return 0; else sudo -n multipass "$@"; fi; }

VM="${1:?usage: vm_ip.sh <vm-name>}"

for _ in $(seq 1 30); do
    IP="$(mp info "$VM" --format csv 2>/dev/null | tail -1 | cut -d, -f3 | tr -d ' ')"
    if [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '{"ip":"%s"}\n' "$IP"
        exit 0
    fi
    sleep 4
done

echo "vm_ip.sh: no IPv4 address for $VM after 120s" >&2
exit 1
