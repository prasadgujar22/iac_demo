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
              │  Oracle Free 23c / XEPDB1  │   Multipass VM
              │  gvenzl/oracle-free:23-slim│   10.2.243.x
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
| `ansible/` | Ansible | Oracle XE **container**, app build, socat bridges, nginx config |
| `jenkins/` | Jenkins | Pipelines: full infra, app-only redeploy, teardown |
| `app/customer-onboarding/` | Maven | The application, with the fixes described below |

## The database runs as a CONTAINER on a VM

To be unambiguous: `terraform/10-db-multipass` provisions an **Ubuntu 24.04
Multipass VM**, and Ansible then runs Oracle XE as a **Docker container on that
VM**. There is no native Oracle install — `/opt/oracle/product` does not exist.

```
Multipass VM  oracle-db  10.2.243.x   Ubuntu 24.04
  └── Docker
        └── container `oracle-xe`  gvenzl/oracle-free:23-slim
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

### `oracle-free`, not `oracle-xe`, on Apple Silicon

`ansible/roles/oracle_xe` pulls **`gvenzl/oracle-free:23-slim`**. gvenzl
publishes `oracle-xe` as **amd64 only**, and on an Apple Silicon host the
Multipass VM is arm64: running amd64 XE under QEMU user-mode emulation crashes
*the emulator* ("QEMU internal SIGSEGV"), not the database. That is a nested
virtualization limit (macOS → arm64 VM → qemu-user → amd64), not something a
retry fixes. `oracle-free` ships a native arm64 image under the same
`APP_USER`/`APP_USER_PASSWORD` contract, so only the image and the PDB name
change — `ORACLE_DATABASE=XEPDB1` keeps the PDB (and therefore the JDBC URL
above) exactly as it was, instead of `oracle-free`'s own `FREEPDB1` default.

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

### The multipass client can hang long after the work is finished

`multipass exec` has been seen spinning at 100% CPU forever *after* the remote
command already completed — build #44 lost 20 minutes that way on a `kubeadm
init` that had finished in about 90 seconds, because a Terraform `local-exec`
provisioner has no timeout of its own and the stack has no way to know the
difference between "still working" and "wedged".

`terraform/05-k8s-multipass` therefore runs every long multipass call through
`mp_wait`, which bounds it and reports **124** for a genuine timeout kill and
**125** for a client killed early because the work was already done. The early
kill is driven by `MP_DONE_CHECK`, a probe polled while the client is alive.

The probe has to prove the remote command **exited**, not that its work looks
finished: killing the client closes the channel and can `SIGHUP` a command
still running. So `kubeadm init` and `kubeadm join` each record their own exit
code to `/run/kubeadm-{init,join}.rc` as the last thing the remote shell does,
and that sentinel is what the probe looks for. It also carries the real result
— `admin.conf` is written in an early kubeadm phase, so its mere presence was
never proof the run succeeded.

`/run` is tmpfs, so a reboot clears the sentinels; the `admin.conf` /
`kubelet.conf` checks remain as the fallback for that case.

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

6. **Replicated HTTP sessions** — `weblogic.xml` sets
   `persistent-store-type=replicated_if_clustered`, so every session has a
   secondary copy on the other managed server and survives losing the pod that
   owns the primary. `verify` proves this by killing that pod and re-using the
   same `JSESSIONID`.

7. **Database settings come from the environment first.** `DatabaseConfig`
   resolves each of url/user/password as **environment variable → system
   property → `web.xml` context-param**. The WAR ships inside the domain image
   and its `web.xml` is templated at build time, so the baked-in JDBC URL is
   only a fallback now; the deployment supplies the current one. An *empty*
   environment variable counts as unset, so a runtime that defines `DB_URL`
   with no value cannot blank out a working fallback.

The application is built and deployed by the `homelab-app` Jenkins pipeline
(see below) — not by uploading a WAR through the WebLogic console by hand, as
the vendored `app/customer-onboarding/README.md` describes for a standalone
checkout.

### Shipping an application change

The WAR is **baked into the domain image**, not deployed at runtime. The domain
is Model-in-Image (`domainHomeSourceType: FromModel`), so every pod rebuilds
`$DOMAIN_HOME` from the WDT model on each start: an application deployed with
WLST lives only in that ephemeral domain home, and any pod restart brings the
pod back with no application at all. `appDeployments` in
`packer/wls-domain-image/model/wls-domain-model.yaml` points at a WAR carried in
the image's WDT archive instead.

Shipping a change is therefore four steps, which the `homelab-app` job performs
in order:

1. `ansible-playbook playbooks/build-app.yml` — build the WAR (templating
   `web.xml` for `DB_MODE`) and zip it to
   `packer/wls-domain-image/.generated/archive.zip`.
2. `packer build` — bake that archive into a new image tag.
3. `docker save` + `multipass transfer` + `ctr images import` onto **every** k8s
   node. There is no registry here and pods pull with `imagePullPolicy:
   IfNotPresent`, so an image missing from one node is an `ErrImagePull` the
   moment a pod schedules there.
4. `terraform apply -var domain_image=… -var db_url=…` — changing `spec.image`
   is what makes the operator roll the servers onto the new application, one at
   a time. `db_url` must be passed on the same apply (see below), or the pods
   come back without it.

### The database address is no longer frozen into the image

`web.xml` is still templated at *build* time, so the JDBC URL inside the WAR is
whatever the database VM's address was when the image was built — and Multipass
pins addresses per VM without *reserving* them. A recreated database VM used to
leave every existing image dialling the old address: `ORA-17820: The network
adapter could not establish the connection`, against an otherwise healthy
cluster.

`terraform/20-wls-k8s` now injects **`DB_URL` into every server pod** through the
domain's `spec.serverPod.env` (declared at domain level, so admin and cluster
members alike inherit it), and the application prefers it over the baked-in
context-param. The same image therefore works wherever the database currently
lives, and the fallback is what keeps `DB_MODE=h2` — which has no database to
point at — and plain non-container runs of the app working unchanged.

Two things to know about the `db_url` variable:

- **Every apply of this stack must pass it.** It defaults to empty (inject
  nothing), so an apply that omits it strips `DB_URL` back out of the pods and
  rolls the domain a second time. `jenkins/Jenkinsfile` and
  `jenkins/Jenkinsfile.app` both read it from the db stack's own `jdbc_url`
  output and skip it in `h2` mode. **`make infra` does not pass it** — prefer the
  Jenkins jobs whenever a domain that needs `DB_URL` is in play.
- **It is deliberately a `-var`, not a `terraform_remote_state` read** of the db
  stack. A remote-state read would make *planning* this stack depend on the db
  stack's state already existing — exactly the plan-time coupling that has
  deadlocked from-scratch bootstraps in this pipeline before.

Changing `db_url` rolls the domain, which is precisely how the new address
reaches the running application.

## Verification runs once, against a settled domain

`ansible/roles/verify` asserts the stack end to end: proxy health, each managed
server directly, the login page through the proxy, the dashboard, session
affinity, session distribution, a write-then-read round trip through the
database — and, since sessions became replicated, a **destructive** check that
kills the pod owning a session and re-uses the same `JSESSIONID`.

That destructive check is why the surrounding order matters. Each rule below
exists because a build failed without it:

- **Verification runs in exactly one place.** The pipeline's `Configure` stage
  invokes `site.yml --skip-tags verify`; the dedicated `Verify` stage is the only
  one that verifies. Running it in both was harmless while every check was
  read-only, but the second run then started seconds after the first had killed a
  pod, against a cluster still recovering — build #39 reported all 10 new
  sessions on `ms2` while `ms1` was still coming back.
- **It waits for the operator to finish rolling first**, via the
  `domain_settled` role, gated on the Domain's **`Completed=True`** condition.
  "`Rolling` isn't `True` and every server reads `RUNNING`" is *not* enough: the
  operator restarts servers one at a time, so between two restarts every server
  legitimately reports `RUNNING`. Build #41 passed straight through such a
  window and templated the proxy 42s before the operator restarted `ms1`.
- **nginx routing is re-templated both before and after verification.** nginx
  pins sessions by JVM route id, and a restarted server comes back with a *new*
  one. Capturing the map before the roll finishes records ids that are about to
  be replaced (build #42: map written at 09:21:13, roll ran until 09:27:56,
  distribution then collapsed onto one server). Refreshing only *afterwards* is
  not enough either, because a failing run never reaches it — and refreshing
  afterwards matters for real users, not just the next test: sessions carrying a
  route id nginx no longer knows fall through to the balanced pool and land
  anywhere.
- **`nginx_proxy` resets `wls_routes` before discovery.** The role builds that
  list by appending to itself, and now runs twice in one execution; without the
  reset the template emits `upstream wls_ms1` twice, `nginx -t` rejects the
  config, and the proxy silently stays on its previous one.
- **The failover check polls for the replacement pod** rather than using
  `kubectl wait`, which returns `NotFound` immediately (measured 0.04s) for a pod
  that does not exist yet — indistinguishable from "the pod never came back".

The main nginx play in `site.yml` is deliberately **not** tagged `verify`;
separate verify-tagged plays cover the verification path. Tagging the main play
instead made the `Configure` stage's `--skip-tags verify` skip configuring nginx
altogether — the play header printed with no tasks beneath it.

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
make app               # build WAR, bake it into a new domain image
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
backend at `<jenkins-home>/tfstate/<stack>.tfstate`, outside any workspace, so
plan/apply and teardown share one view of reality and a workspace wipe cannot
orphan live infrastructure. On the reference Ubuntu host, where Jenkins runs as
the system `jenkins` user, that's `/home/jenkins/tfstate/`; this checkout runs
Jenkins as `prasad_mac` on macOS, so the `backend.tf` files here point at
`/Users/prasad_mac/.homelab-iac/tfstate/` instead — match the path to whatever
user Jenkins actually runs as on your host.

### Builds run unattended

`homelab-iac` takes **`AUTO_APPROVE` (default true)**, and both *Approve apply*
stages are skipped when it is set. Starting a build already means choosing
`APPLY`, `DB_MODE`, `BUILD_IMAGE` and `DEPLOY_APP` — the prompts only re-asked
what was just selected, and each carried a 15-minute timeout, so a build nobody
was watching could abort with the k8s tier applied and nothing after it.

Uncheck `AUTO_APPROVE` to get the plan-by-plan review back.

`Jenkinsfile.teardown` deliberately keeps its prompt: it guards `terraform
destroy`, where launch parameters are not a sufficient statement of intent.
That job has its own `AUTO_APPROVE`, scoped to the non-destructive `SHUTDOWN`
path, and `CONFIRM=DESTROY` for the rest.

> Jenkins **drops a parameter its stored job config does not know yet**, so a
> newly added one is absent from the first build after it appears — the job
> learns parameters from the `Jenkinsfile` only once it has run with them. The
> `parameters {}` default still applies during that run.

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

Set in `ansible/inventory/group_vars/all.yml` or override: `make app DB_MODE=h2`
