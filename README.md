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
| `terraform/30-nginx-microcloud/` | Terraform | LXD VM, static IP, OVN network forwards |
| `ansible/` | Ansible | Oracle XE bootstrap, app build+deploy, socat unit, nginx config |
| `jenkins/` | Jenkins | Pipelines: full infra, app-only redeploy, teardown |

## Quick start

```bash
make help              # list targets
make preflight         # verify toolchain + platform health
make plan              # terraform plan across all stacks (read-only)
make infra             # provision DB + WLS + nginx
make app               # build WAR and deploy to the cluster
make verify            # end-to-end assertions incl. session affinity
```

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
