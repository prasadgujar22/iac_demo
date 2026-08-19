#!/usr/bin/env bash
#
# Create the Jenkins SSH agent that runs pipelines ON THE HOST.
#
# WHY THIS IS NECESSARY
# Jenkins runs in a Docker container (jenkins/jenkins:lts-jdk17) containing only
# git and ssh. The pipelines need terraform, ansible, packer, kubectl, lxc and
# multipass — all of which must execute on the host because they drive
# host-level hypervisors (LXD unix socket, Multipass daemon, libvirt). Installing
# them inside the container would not give them access to those sockets.
#
# So Jenkins connects BACK to the host over SSH and runs everything there.
#
set -euo pipefail

AGENT_NAME="${AGENT_NAME:-homelab}"
AGENT_LABEL="${AGENT_LABEL:-homelab}"
AGENT_HOME="${AGENT_HOME:-$HOME/jenkins-agent}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/jenkins_agent_ed25519}"
CONTAINER="${CONTAINER:-jenkins}"

echo "== Jenkins host-agent bootstrap =="

# 1. Dedicated keypair for the agent.
if [ -f "$KEY_PATH" ]; then
    echo "[1/5] key already exists: $KEY_PATH"
else
    echo "[1/5] generating $KEY_PATH"
    ssh-keygen -t ed25519 -N "" -C "jenkins-agent@$(hostname)" -f "$KEY_PATH"
fi

# 2. Authorise it for this user so Jenkins can log in.
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
if grep -qF "$(cat "${KEY_PATH}.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    echo "[2/5] key already authorised"
else
    cat "${KEY_PATH}.pub" >> "$HOME/.ssh/authorized_keys"
    echo "[2/5] key authorised"
fi

# 3. Agent workspace.
mkdir -p "$AGENT_HOME"
echo "[3/5] workspace: $AGENT_HOME"

# 4. Verify the loopback SSH path actually works before Jenkins depends on it.
echo "[4/5] testing ssh to localhost"
if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes \
       "$USER@127.0.0.1" 'echo ssh-ok' 2>/dev/null | grep -q ssh-ok; then
    echo "        ssh OK"
else
    echo "        FAILED: cannot ssh to localhost with $KEY_PATH" >&2
    echo "        Is sshd running?  sudo systemctl status ssh" >&2
    exit 1
fi

# 5. Reachability from inside the container. Jenkins in Docker cannot use
#    127.0.0.1 to mean the host, so the gateway address is required.
GW=$(sudo docker exec "$CONTAINER" sh -c "ip route | awk '/default/{print \$3}'" 2>/dev/null || true)
echo "[5/5] host address as seen from the container: ${GW:-<unknown>}"

cat <<EOF

------------------------------------------------------------------
Manual step (Jenkins UI) — credentials cannot be created safely
from a script without embedding secrets.

1. Manage Jenkins > Credentials > (global) > Add Credentials
     Kind:     SSH Username with private key
     ID:       homelab-agent-key
     Username: $USER
     Key:      paste the contents of $KEY_PATH

2. Manage Jenkins > Nodes > New Node
     Name:                  $AGENT_NAME
     Type:                  Permanent Agent
     Remote root directory: $AGENT_HOME
     Labels:                $AGENT_LABEL
     Launch method:         Launch agents via SSH
       Host:                ${GW:-<host-ip-from-container>}
       Credentials:         homelab-agent-key
       Host Key Strategy:   Non verifying  (homelab only)

3. Also add these credentials, used by the pipelines:
     wls-admin   (username/password) WebLogic administrator
     oracle-sys  (username/password) Oracle SYS
     oracle-app  (username/password) application schema owner

4. Passwordless sudo is required for the network/systemd tasks:
     $USER ALL=(ALL) NOPASSWD: ALL
------------------------------------------------------------------
EOF
