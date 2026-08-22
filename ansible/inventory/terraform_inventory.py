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

WHY THE SHARED-STATE FALLBACK
.generated/ is workspace-local and gitignored (machine-specific IPs have no
business in version control). A different checkout of this repo — a second
clone, or a Jenkins job's own workspace — has no .generated files even when
Terraform's REMOTE/shared backend state proves the VMs already exist: `plan`
only never regenerates local_file resources, and a fresh workspace has never
had `apply` write them in the first place. Falling back to `terraform output`
against the shared backend lets any workspace reconstruct the same inventory
groups the original apply would have produced, mirroring the fallback
site.yml already uses to resolve oracle_db_host as a fact.
"""
import json
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML is required for the dynamic inventory\n")
    sys.exit(1)

# This file lives at <repo>/ansible/inventory/, so the repo root is THREE
# dirname() calls up. Getting this wrong silently yields an empty db group.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

SSH_PRIVATE_KEY_FILE = os.path.expanduser(
    os.environ.get("HOMELAB_SSH_PRIVATE_KEY", "~/.ssh/homelab_iac_ed25519")
)

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


def terraform_outputs(stack):
    """Read a stack's outputs from its shared backend. {} on any failure —
    this must never raise, or a workspace with no Terraform state at all
    (a fresh h2-mode checkout, say) would break the whole inventory."""
    stack_dir = os.path.join(REPO_ROOT, "terraform", stack)
    try:
        subprocess.run(
            ["terraform", f"-chdir={stack_dir}", "init", "-reconfigure", "-no-color", "-input=false"],
            capture_output=True, timeout=60, check=False,
        )
        result = subprocess.run(
            ["terraform", f"-chdir={stack_dir}", "output", "-json"],
            capture_output=True, timeout=30, check=False, text=True,
        )
        if result.returncode != 0 or not result.stdout.strip():
            return {}
        raw = json.loads(result.stdout)
        return {k: v.get("value") for k, v in raw.items() if isinstance(v, dict)}
    except Exception:                              # noqa: BLE001
        return {}


def merge_from_shared_state(inv, group, host_key, host_default, build_hostvars):
    """Populate one group straight from Terraform outputs when its
    .generated file was absent (see module docstring)."""
    if inv.get(group, {}).get("hosts"):
        return  # .generated already supplied this group; don't redo the work
    outputs = terraform_outputs(GROUP_STACKS[group])
    if not outputs:
        return
    host = outputs.get(host_key, host_default)
    hostvars = build_hostvars(outputs)
    if not hostvars.get("ansible_host"):
        return
    inv.setdefault(group, {"hosts": []})
    if host not in inv[group]["hosts"]:
        inv[group]["hosts"].append(host)
    inv["_meta"]["hostvars"].setdefault(host, {}).update(hostvars)


GROUP_STACKS = {
    "db": "10-db-multipass",
    "nginx": "30-nginx-multipass",
}


def build():
    inv = base_inventory()
    for path in GENERATED:
        merge(inv, path)

    merge_from_shared_state(
        inv, "db", "vm_name", "oracle-db",
        lambda o: {
            "ansible_host": o.get("db_host"),
            "ansible_user": "ubuntu",
            "ansible_ssh_private_key_file": SSH_PRIVATE_KEY_FILE,
            "oracle_listener_port": o.get("listener_port"),
        },
    )
    merge_from_shared_state(
        inv, "nginx", "instance_name", "nginx-proxy",
        lambda o: {
            "ansible_host": o.get("proxy_internal_ip"),
            "ansible_user": "ubuntu",
            "ansible_ssh_private_key_file": SSH_PRIVATE_KEY_FILE,
            "proxy_internal_ip": o.get("proxy_internal_ip"),
            "proxy_lan_ip": o.get("proxy_lan_ip"),
            "proxy_listen_port": o.get("proxy_listen_port", 80),
        },
    )

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
