#!/usr/bin/env python3
"""
Dynamic inventory: merge the static topology with Terraform-generated facts.

WHY THIS EXISTS
The database VM's IP is only known after `terraform apply`, and Terraform writes
it to terraform/10-db-multipass/.generated/db_inventory.yaml. A static
inventory therefore cannot reach the host, failing with:

    Could not resolve hostname oracle-db: Name or service not known

Loading that file into a *variable* inside a play does not help either — by then
Ansible has already decided how to connect. Connection details must exist at
INVENTORY time, which is what this script provides.

Safe when Terraform has not run: the db group is simply reported empty rather
than erroring, so h2-mode runs work with no database at all.
"""
import json
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML is required for the dynamic inventory\n")
    sys.exit(1)

# This file lives at <repo>/ansible/inventory/, so the repo root is THREE
# dirname() calls up. Getting this wrong silently yields an empty db group.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

GENERATED = [
    os.path.join(REPO_ROOT, "terraform", "10-db-multipass", ".generated", "db_inventory.yaml"),
    os.path.join(REPO_ROOT, "terraform", "30-nginx-multipass", ".generated", "nginx_inventory.yaml"),
]


def base_inventory():
    """Static topology that never depends on Terraform state."""
    return {
        "_meta": {"hostvars": {}},
        "all": {"children": ["control", "db", "nginx", "ungrouped"]},
        # The host itself: runs socat bridges, kubectl and the Maven build.
        "control": {
            "hosts": ["localhost"],
            "vars": {"ansible_connection": "local"},
        },
        "db": {"hosts": []},
        "nginx": {"hosts": []},
    }


def merge(inv, path):
    """Merge one Terraform-generated inventory fragment, if present."""
    if not os.path.isfile(path):
        return
    try:
        with open(path) as fh:
            data = yaml.safe_load(fh) or {}
    except Exception as exc:                      # noqa: BLE001
        sys.stderr.write("warning: could not parse %s: %s\n" % (path, exc))
        return

    for group, gdata in data.items():
        if not isinstance(gdata, dict):
            continue
        hosts = gdata.get("hosts") or {}
        inv.setdefault(group, {"hosts": []})
        for host, hvars in hosts.items():
            if host not in inv[group]["hosts"]:
                inv[group]["hosts"].append(host)
            if isinstance(hvars, dict):
                inv["_meta"]["hostvars"].setdefault(host, {}).update(hvars)


def build():
    inv = base_inventory()
    for path in GENERATED:
        merge(inv, path)
    return inv


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "--list"
    if arg == "--host":
        host = sys.argv[2] if len(sys.argv) > 2 else ""
        print(json.dumps(build()["_meta"]["hostvars"].get(host, {})))
    else:
        print(json.dumps(build(), indent=2))


if __name__ == "__main__":
    main()
