# Homelab IaC — nginx (MicroCloud) → WebLogic (k8s) → Oracle XE (Multipass)

Infrastructure-as-code for a three-tier stack spread across three virtualization
platforms on a single host, driven by Packer, Terraform, Ansible and Jenkins.

```
                    LAN 192.168.29.0/24
                            │
        ┌───────────────────┴────────────────────┐
        │  192.168.29.200:80   nginx reverse proxy│   ← MicroCloud VM (LXD/OVN)
        │  JSESSIONID route-ID session affinity   │     10.184.135.2
        └───────────────────┬────────────────────┘
                            │  192.168.29.201:8090  (ms1)
                            │  192.168.29.202:8090  (ms2)
                            │      ▲ socat, systemd-managed
        ┌───────────────────┴────────────────────┐
        │  WebLogic cluster, 2 managed servers    │   ← Multipass k8s
        │  domain wlsdomain / ns wls-domain       │     10.2.243.0/24
        └───────────────────┬────────────────────┘
                            │  10.2.243.x:1521
        ┌───────────────────┴────────────────────┐
        │  Oracle XE 21c                          │   ← Multipass VM
        └─────────────────────────────────────────┘
```

## Why the database lives on Multipass

The previous Oracle instance ran in a libvirt VM on `192.168.122.0/24`, which WebLogic
pods **could not reach** (`No route to host`) — that is what forced the domain into ADMIN
mode and blocked deployment. A Multipass VM shares the `10.2.243.0/24` NAT network with
the k8s nodes, so pods reach it directly. The platform choice is the fix.

## Layout

| Path | Tool | Responsibility |
|---|---|---|
| `packer/wls-domain-image/` | Packer | Build `wls-domain-image` from the Oracle WLS base + WDT model |
| `terraform/10-db-multipass/` | Terraform | Multipass VM for Oracle XE |
| `terraform/20-wls-k8s/` | Terraform | Namespace, secrets, Domain/Cluster CRs, per-server NodePorts |
| `terraform/30-nginx-multipass/` | Terraform | Multipass VM for nginx, on the k8s subnet |
| `ansible/` | Ansible | Oracle XE bootstrap, app build+deploy, socat unit, nginx config |
| `jenkins/` | Jenkins | Pipelines: full infra, app-only redeploy, teardown |

## Adopting existing hand-built infrastructure

Most of this stack existed before the repo did. Terraform does not know about
those objects, so `apply` tries to **create** them and fails with
`already exists`. Adopt them into state first — this is idempotent and
non-destructive:

```bash
make import
make plan          # review the diffs carefully before applying
```

Two protections exist because imported objects differ from the code:

- `lxd_instance.nginx` ignores changes to `image`/`description`. An imported
  instance reports no image, which Terraform reads as a change and would
  **destroy and rebuild the working proxy**. To rebuild deliberately, taint it.
- The WebLogic secrets ignore changes to `data`. Regenerating the admin password
  breaks a running domain, because it is baked into each server's
  `boot.properties` at creation time and the managed servers can then no longer
  authenticate. Rotating the runtime-encryption secret likewise invalidates the
  encrypted WDT model and forces a domain rebuild.

**The Domain and Cluster CRs cannot be imported** — Terraform's
`kubernetes_manifest` has no import support. Either leave them managed outside
Terraform, or delete them and let Terraform recreate them (which restarts the
domain). `make plan` will always show them as "to add" until you choose.

## Quick start

```bash
make help              # list targets
make ssh-key           # one-off: create the keypair injected into new VMs
make preflight         # verify toolchain + platform health
make plan              # terraform plan across all stacks (read-only)
make infra             # provision DB + WLS + nginx
make app               # build WAR and deploy to the cluster
make verify            # end-to-end assertions incl. session affinity
```

`make ssh-key` creates `~/.ssh/homelab_iac_ed25519`, a dedicated keypair injected
via cloud-init so Ansible can reach newly provisioned VMs. It is deliberately not
`~/.ssh/id_rsa`, which does not exist on every host. To use an existing key:

```bash
terraform apply -var ssh_public_key_path=~/.ssh/other.pub \
                -var ssh_private_key_path=~/.ssh/other
```

> Terraform's `file()` does **not** expand `~`, so every stack wraps key paths in
> `pathexpand()`. Without it you get
> `Invalid value for "path" parameter: no file exists at "~/.ssh/..."` even when
> the file is present. A `precondition` reports the missing key with the fix
> instead of an opaque evaluation error.

## Critical constraint: Jenkins runs in Docker

The Jenkins container (`jenkins/jenkins:lts-jdk17`) has **only `git` and `ssh`** — no
terraform, ansible, packer, kubectl, lxc or multipass. Those tools live on the host and
cannot be usefully installed in the container, because they must drive host-level
hypervisors (libvirt sockets, LXD unix socket, Multipass daemon).

Therefore all pipelines run on an **SSH agent pointing back at the host**, label
`homelab`. Bootstrap it once:

```bash
./jenkins/bootstrap-agent.sh
```

Running the pipelines on Jenkins' built-in node will fail by design — see
`jenkins/README.md`.

## Idempotency

Every stack is safe to re-run. Ansible roles are declarative; Terraform is stateful;
Packer builds are versioned by tag. `make infra` twice should produce no changes on the
second pass — `make plan` proves it.

## Database mode

`db_mode` selects the persistence backend:

- `oracle` (default) — Oracle XE on Multipass, shared across both managed servers
- `h2` — embedded in-memory H2, per-pod dataset, no external dependency

Set in `ansible/group_vars/all.yml` or override: `make app DB_MODE=h2`
