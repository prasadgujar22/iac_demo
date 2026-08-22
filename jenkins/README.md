# Jenkins pipelines

| Pipeline | File | Purpose |
|---|---|---|
| Full infrastructure | `Jenkinsfile` | Preflight, validate, optional Packer build, Terraform plan/apply, Ansible configure, verify |
| Application redeploy | `Jenkinsfile.app` | Rebuild the WAR, redeploy, refresh routing, verify. The fast inner loop. |
| Teardown | `Jenkinsfile.teardown` | Destroy in reverse order. Requires typing `DESTROY`. |
| Shutdown | `Jenkinsfile.shutdown` | Non-destructive: `multipass stop` every VM. State and data untouched; `multipass start <name>` brings the stack back. |
| Start | `Jenkinsfile.start` | Non-destructive: `multipass start` every VM. Counterpart to Shutdown; database and k8s nodes first, nginx last. |

## Why Jenkins runs on the host, not in Docker

Jenkins originally ran as a Docker container (`jenkins/jenkins:lts-jdk17`).
Verified contents: **`git` and `ssh` only**. Absent: `terraform`, `ansible`,
`packer`, `kubectl`, `multipass`.

Those tools cannot simply be installed into the container, because they drive
**host-level** facilities:

- `multipass` needs the Multipass daemon socket (and client authentication)
- `docker` on the DB VM runs the Oracle XE container
- `kubectl` needs the host kubeconfig and routes to `10.2.243.0/24`
- the socat/systemd tasks configure host networking

**Jenkins therefore runs natively on the host** (apt package + systemd unit),
and the built-in node carries the label `homelab`, so the pipelines drive the
toolchain directly with no SSH indirection.

`bootstrap-agent.sh` remains only for the older containerised setup; it is not
needed for the native install.

Host setup the native install needs:

```bash
# JENKINS_HOME under /home — snap tools (multipass) refuse a home outside /home
sudo systemctl edit jenkins       # Environment="JENKINS_HOME=/home/jenkins"

# the CI user needs the cluster and passwordless sudo for multipass/socat
sudo -u jenkins mkdir -p /home/jenkins/.kube
sudo cp ~/.kube/config /home/jenkins/.kube/config
sudo chown -R jenkins:jenkins /home/jenkins/.kube
```

Terraform state lives at `/home/jenkins/tfstate/`, **outside any job workspace** —
each Jenkins job gets its own workspace, so per-workspace state let the teardown
job report success having destroyed nothing.

## Credentials

| ID | Kind | Used for |
|---|---|---|
| `wls-admin` | username/password | WebLogic administrator |
| `oracle-sys` | username/password | Oracle SYS |
| `oracle-app` | username/password | Application schema owner |

Secrets reach Ansible as environment variables via `withCredentials` and are
passed with `-e`. Nothing is written to disk or echoed.

## Safety defaults

- `APPLY` defaults to **false** — a build with default parameters plans only.
- Applying requires an interactive approval step.
- `disableConcurrentBuilds()` — concurrent Terraform runs corrupt state.
- Teardown requires typing `DESTROY` and defaults to keeping the database.

## Reading a failure

Check **Preflight** first. Most failures here are platform faults, not code:

- USB uplink carrier down → `sudo ip link set enx00e04c096078 up`
- k8s node NotReady → Flannel `subnet.env` corruption; restart the Flannel pod
- App returns 503 → managed servers likely in ADMIN mode:
  `kubectl get domain wlsdomain -n wls-domain -o jsonpath='{.status.servers[*].state}'`
