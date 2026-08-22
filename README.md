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
              │  gvenzl/oracle-xe:21-slim  │   10.2.243.x
              │  CONTAINER on the VM :1521 │   (Docker)
              └────────────────────────────┘
```

**Everything shares `10.2.243.0/24`**, so each tier reaches the next directly.
Only the LAN entry point needs a bridge, because Multipass VMs are NAT'd.

## Layout

| Path | Tool | Responsibility |
|---|---|---|
| `packer/wls-domain-image/` | Packer | WebLogic Model-in-Image domain image |
| `terraform/05-k8s-multipass/` | Terraform | Kubeadm K8s cluster (control-plane + worker VMs) + WLS operator |
| `terraform/10-db-multipass/` | Terraform | VM that *hosts* the Oracle XE container |
| `terraform/20-wls-k8s/` | Terraform | Namespace, secrets, Domain/Cluster CRs, NodePorts |
| `terraform/30-nginx-multipass/` | Terraform | nginx proxy VM |
| `ansible/` | Ansible | Oracle XE **container**, app build+deploy, socat bridges, nginx config |
| `jenkins/` | Jenkins | Pipelines: full infra, app-only redeploy, teardown |
| `app/customer-onboarding/` | Maven | The application, with the fixes described below |

## The database runs as a CONTAINER on a VM

To be unambiguous: `terraform/10-db-multipass` provisions an **Ubuntu 24.04
Multipass VM**, and Ansible then runs Oracle XE as a **Docker container on that
VM**. There is no native Oracle install — `/opt/oracle/product` does not exist.

```
Multipass VM  oracle-db  10.2.243.x   Ubuntu 24.04
  └── Docker
        └── container `oracle-xe`  gvenzl/oracle-xe:21-slim
              ├── listener 1521  (published 0.0.0.0:1521 via docker-proxy)
              ├── PDB XEPDB1
              └── datafiles bind-mounted -> /opt/oracle-data on the VM
```

Connection string, unchanged by any of this:

```
jdbc:oracle:thin:@//<db-vm-ip>:1521/XEPDB1
```

### Why a container rather than a native install

Oracle ships XE as an RPM only. Converting it for Ubuntu with `alien` failed
**four times across three distinct root causes**, each retry costing ~40 minutes
(2.2 GB download + ~35 min conversion):

1. **`alien` exits non-zero on success.** The RPM is unsigned for apt's purposes,
   so rpm emits `Header V3 RSA/SHA256 Signature ... NOKEY` warnings and `alien`
   propagates a failure code — aborting the play *after* a conversion that had
   actually worked.
2. **`libaio.so.1` does not exist on Ubuntu 24.04.** The t64 transition ships
   `libaio.so.1t64`; Oracle's binaries link the historic SONAME, so `orabase`
   died before DBCA ever started.
3. **`netca` rejects Ubuntu's `127.0.1.1` hostname mapping** with
   `No valid IP Address returned for the host oracle-db`.

Fixing all three got the *listener* running, but DBCA then failed with
`DBT-05509` inside its CVU prerequisite machinery.

`gvenzl/oracle-xe` is the image Oracle's own developer advocate maintains for
this purpose. It is **~2 GB, healthy in about 4 minutes**, needs no conversion,
and creates the application schema itself from `APP_USER` / `APP_USER_PASSWORD` —
which also retired the hand-written `create-app-schema.sql` and `listener.ora`
templates.

The VM is still worth having: it puts the database on `10.2.243.0/24` alongside
the k8s nodes, so WebLogic pods reach the listener directly.

## Why every tier is on Multipass

nginx originally ran on MicroCloud (LXD + OVN + Ceph). **MicroCloud has since been
removed from the host entirely**, after two failures in one evening:

- **LXD and MicroCeph pools were loop-file backed and the loop devices were not
  recreated at boot.** After a kernel upgrade LXD crash-looped on
  `zpool import local: no such pool available`, 97 Ceph pgs went inactive, and
  the proxy VM was unreachable until both images were manually re-attached.
- **The OVN subnet could not reach the k8s subnet**, so the proxy had to hairpin
  out to the physical LAN and back through host socat bridges just to reach a
  NodePort.

Multipass restores its own instances after a reboot and puts every tier on one
subnet. Removing the four snaps (lxd, microceph, microovn, microcloud) reclaimed
**21 GB** and removed a whole class of boot-time failure.

## Application fixes and features carried in this repo

`app/customer-onboarding/` is the upstream demo with these changes on top,
vendored directly in this repo (`app/customer-onboarding/`) rather than forked
elsewhere, so the application and the infrastructure that deploys it are
reviewed and versioned together:

1. **Dialect-aware schema init** — the original issues an Oracle PL/SQL
   anonymous block, which H2 cannot parse.
2. **Explicit JDBC driver registration** — WebLogic's classloader isolation stops
   `DriverManager` SPI discovery from seeing `WEB-INF/lib`.
3. **H2 dependency** alongside `ojdbc11`, so `DB_MODE=h2` works with no database.
4. **`web.xml` is templated** by Ansible, so the JDBC URL follows `DB_MODE`
   instead of being hardcoded.
5. **Edit existing records.** The Reports tab carries an **Edit** link per row
   (`/dashboard?tab=onboarding&editId=N`) that reopens the onboarding form
   pre-filled for that record; the same form and servlet (`/customers`) handle
   both create and update, distinguished by a hidden `id` field.
   `CustomerDao.update()`/`findById()` back it; `CREATED_DATE` is left
   untouched on edit. Values re-rendered into the form are HTML-escaped, since
   existing data may legitimately contain `&`/`"`/`<`/`>`.

The application is built and deployed by the `homelab-app` Jenkins pipeline
(see below) — not by uploading a WAR through the WebLogic console by hand, as
the vendored `app/customer-onboarding/README.md` describes for a standalone
checkout.

## Adopting existing hand-built infrastructure

Most of this stack existed before the repo did. Terraform does not know about
those objects, so `apply` tries to **create** them and fails with
`already exists`. Adopt them into state first — this is idempotent and
non-destructive:

```bash
make import
make plan          # review the diffs carefully before applying
```

One protection exists because imported objects differ from the code:

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

## Jenkins runs natively on the host

Jenkins is installed as a **host package** (`jenkins` apt package, systemd unit),
not in Docker, and the pipelines execute on the **built-in node labelled
`homelab`**.

This was a deliberate change. Jenkins originally ran as
`jenkins/jenkins:lts-jdk17`, whose image has **only `git` and `ssh`** — no
terraform, ansible, packer, kubectl or multipass. Those tools drive host-level
hypervisors (the Multipass daemon socket, the k8s API), so they cannot be
usefully containerised, and every pipeline needed an SSH agent pointing back at
the host. Installing Jenkins natively removed that indirection entirely.

Three host-specific details this requires:

- **`JENKINS_HOME` must live under `/home`.** The package defaults to
  `/var/lib/jenkins`, but snap-packaged tools refuse to run for a user whose home
  is outside `/home` (`Sorry, home directories outside of /home needs
  configuration`), which makes `multipass` unusable. Set via a systemd override.
- **Terraform state is shared, not per-workspace.** See below.
- **`multipass` needs a sudo fallback.** `local.passphrase` is set, so only the
  VM owner is authenticated; the CI user goes through `sudo -n multipass`.

### Terraform state must not live in a job workspace

Jenkins gives every **job** its own workspace. State written by `homelab-iac`
was therefore invisible to `homelab-teardown`, which reported

```
Destroy complete! Resources: 0 destroyed.
Teardown complete. Everything destroyed, including data.
Finished: SUCCESS
```

while every VM kept running. A pipeline that claims to have destroyed everything
and destroyed nothing is far more dangerous than one that fails loudly.

All four stacks (including `05-k8s-multipass`, which bootstraps the cluster itself
via kubeadm — not present in the original three-stack layout) now pin a local
backend at `/home/jenkins/tfstate/<stack>.tfstate`, outside any workspace, so
plan/apply and teardown share one view of reality and a workspace wipe cannot
orphan live infrastructure.

### Jenkins credentials the pipelines expect

| ID | Type | Purpose |
|---|---|---|
| `oracle-sys` | username/password | Oracle `SYS` |
| `oracle-app` | username/password | Application schema (`customer_app`) |
| `wls-admin` | username/password | WebLogic administrator |

### Shell steps need an explicit bash shebang

Jenkins' `sh` step runs `/bin/sh`, which is **dash** on Ubuntu, and dash has no
`pipefail`. The shebang is only honoured as the first bytes of the script, so it
must be glued to the opening quotes:

```groovy
sh '''#!/bin/bash
    set -euo pipefail
    ...
'''
```

Written as `sh '''` followed by a newline, the shebang lands on line 2 and is
silently ignored — the failure looks identical.

## Idempotency

Every stack is safe to re-run. Ansible roles are declarative; Terraform is stateful;
Packer builds are versioned by tag. `make infra` twice should produce no changes on the
second pass — `make plan` proves it.

## Database mode

`db_mode` selects the persistence backend:

- `oracle` (default) — Oracle XE as a **container on a Multipass VM**, shared across both managed servers
- `h2` — embedded in-memory H2, per-pod dataset, no external dependency

Set in `ansible/group_vars/all.yml` or override: `make app DB_MODE=h2`
