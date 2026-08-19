# Jenkins pipelines

| Pipeline | File | Purpose |
|---|---|---|
| Full infrastructure | `Jenkinsfile` | Preflight, validate, optional Packer build, Terraform plan/apply, Ansible configure, verify |
| Application redeploy | `Jenkinsfile.app` | Rebuild the WAR, redeploy, refresh routing, verify. The fast inner loop. |
| Teardown | `Jenkinsfile.teardown` | Destroy in reverse order. Requires typing `DESTROY`. |

## The agent requirement is not optional

Jenkins here runs as a Docker container (`jenkins/jenkins:lts-jdk17`). Verified
contents: **`git` and `ssh` only**. Absent: `terraform`, `ansible`, `packer`,
`kubectl`, `lxc`, `multipass`.

Those tools cannot simply be installed into the container, because they drive
**host-level** facilities:

- `lxc` needs the LXD unix socket
- `multipass` needs the Multipass daemon
- `kubectl` needs the host kubeconfig and routes to `10.2.243.0/24`
- the socat/systemd tasks configure host networking

So every pipeline declares `agent { label 'homelab' }` and runs on an SSH agent
pointing back at the host. Running on Jenkins' built-in node fails by design —
better an explicit "no such label" than a half-provisioned stack.

```bash
./bootstrap-agent.sh      # generates the key, authorises it, prints UI steps
```

Note the agent host address must be the **container's gateway**, not
`127.0.0.1` — inside a container that means the container itself.

## Credentials

| ID | Kind | Used for |
|---|---|---|
| `homelab-agent-key` | SSH private key | Agent connection |
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
