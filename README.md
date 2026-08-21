# Homelab IaC — Oracle XE + WebLogic (k8s) + nginx

Infrastructure-as-code for a three-tier Java application stack, provisioned with
**Packer, Terraform, Ansible and Jenkins**. Every tier runs on Multipass VMs on a
single host; WebLogic runs on a Multipass-based Kubernetes cluster.

```
                    LAN 192.168.29.0/24
                            │
                 192.168.29.200:80  (host socat bridge)
                            │
              ┌─────────────▼──────────────┐
              │  nginx reverse proxy       │   Multipass VM
              │  JSESSIONID route-ID       │   10.2.243.x
              │  session affinity          │
              └─────────────┬──────────────┘
                            │  direct to NodePorts (same subnet)
              ┌─────────────▼──────────────┐
              │  WebLogic cluster          │   Multipass k8s
              │  ms1 :30701  ms2 :30702    │   10.2.243.69
              └─────────────┬──────────────┘
                            │  jdbc:oracle:thin
              ┌─────────────▼──────────────┐
              │  Oracle XE 21c / XEPDB1    │   Multipass VM
              │  :1521                     │   10.2.243.x
              └────────────────────────────┘
```

**Everything shares `10.2.243.0/24`**, so each tier reaches the next directly.
Only the LAN entry point needs a bridge, because Multipass VMs are NAT'd.

## Layout

| Path | Tool | Responsibility |
|---|---|---|
| `packer/wls-domain-image/` | Packer | WebLogic Model-in-Image domain image |
| `terraform/10-db-multipass/` | Terraform | Oracle XE VM |
| `terraform/20-wls-k8s/` | Terraform | Namespace, secrets, Domain/Cluster CRs, NodePorts |
| `terraform/30-nginx-multipass/` | Terraform | nginx proxy VM |
| `ansible/` | Ansible | XE bootstrap, app build+deploy, socat bridges, nginx config |
| `jenkins/` | Jenkins | Pipelines: full infra, app-only redeploy, teardown |
| `app/customer-onboarding/` | Maven | The application, with the fixes described below |

## Why every tier is on Multipass

nginx originally ran on MicroCloud (LXD + OVN + Ceph). It was moved after two
failures in one evening:

- **LXD and MicroCeph pools are loop-file backed and the loop devices are not
  recreated at boot.** After a kernel upgrade LXD crash-looped on
  `zpool import local: no such pool available`, 97 Ceph pgs went inactive, and
  the proxy VM was unreachable until both images were manually re-attached.
- **The OVN subnet could not reach the k8s subnet**, so the proxy had to hairpin
  out to the physical LAN and back through host socat bridges just to reach a
  NodePort.

Multipass restores its own instances after a reboot and puts the proxy on the
same subnet as the backends.

## Application fixes carried in this repo

`app/customer-onboarding/` is the upstream demo with four changes, each required
to run on WebLogic:

1. **Dialect-aware schema init** — the original issues an Oracle PL/SQL
   anonymous block, which H2 cannot parse.
2. **Explicit JDBC driver registration** — WebLogic's classloader isolation stops
   `DriverManager` SPI discovery from seeing `WEB-INF/lib`.
3. **H2 dependency** alongside `ojdbc11`, so `DB_MODE=h2` works with no database.
4. **`web.xml` is templated** by Ansible, so the JDBC URL follows `DB_MODE`
   instead of being hardcoded.

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
