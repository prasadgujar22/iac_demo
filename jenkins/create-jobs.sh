#!/usr/bin/env bash
#
# Register (or update) the Jenkins jobs for this repo.
#
# WHY THIS EXISTS
# Jobs created by hand in the Jenkins UI live only on the controller's disk.
# Nothing in version control describes them, so a lost controller means
# reconstructing them from memory. This script makes the job definitions
# reproducible from the repo, the same way the pipelines themselves are.
#
# Idempotent: creates a job if absent, updates it in place if present. Existing
# build history is preserved.
#
# Usage:
#   ./jenkins/create-jobs.sh                      # uses $JENKINS_URL / prompts
#   JENKINS_URL=http://host:8080 \
#   JENKINS_USER=admin JENKINS_TOKEN=... ./jenkins/create-jobs.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${HERE}/job-template.xml"

JENKINS_URL="${JENKINS_URL:-http://192.168.29.159:8080}"
JENKINS_USER="${JENKINS_USER:-admin}"
REPO_URL="${REPO_URL:-https://github.com/prasadgujar22/iac_demo.git}"
BRANCH="${BRANCH:-*/main}"

# The CLI must be addressed by the SAME URL configured in Jenkins, or the
# handshake fails with "Unexpected request origin (check your reverse proxy
# settings)" — which reads like a proxy problem and is not one.
CLI_JAR="${CLI_JAR:-/tmp/jenkins-cli.jar}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"

if [ -z "${JENKINS_TOKEN:-}" ]; then
    # Fall back to the initial admin password if it is still present.
    for f in /var/lib/jenkins/secrets/initialAdminPassword \
             /home/jenkins/secrets/initialAdminPassword; do
        if sudo test -r "$f" 2>/dev/null; then
            JENKINS_TOKEN="$(sudo cat "$f")"
            break
        fi
    done
fi
[ -n "${JENKINS_TOKEN:-}" ] || die "set JENKINS_TOKEN (API token or admin password)"

if [ ! -f "$CLI_JAR" ]; then
    echo "==> fetching jenkins-cli.jar"
    curl -fsSL "${JENKINS_URL}/jnlpJars/jenkins-cli.jar" -o "$CLI_JAR" \
        || die "could not download the CLI from ${JENKINS_URL}"
fi

cli() { java -jar "$CLI_JAR" -s "$JENKINS_URL" -auth "${JENKINS_USER}:${JENKINS_TOKEN}" "$@"; }

# name | Jenkinsfile | description
#
# homelab-start and homelab-shutdown were retired: their VM start/stop logic
# is now folded directly into homelab-iac (Start VMs stage, always runs
# early) and homelab-teardown (ACTION=SHUTDOWN), so one job each covers the
# full lifecycle instead of needing a separate non-destructive job.
JOBS=(
  "homelab-iac|jenkins/Jenkinsfile|Full infrastructure: starts stopped VMs, preflight, validate, plan, apply (creates whatever tier is missing, including the k8s cluster), configure, deploy, verify"
  "homelab-app|jenkins/Jenkinsfile.app|Application redeploy only: rebuild the WAR, redeploy to ms1+ms2, refresh routing, verify"
  "homelab-teardown|jenkins/Jenkinsfile.teardown|ACTION=DESTROY: destroys every tier in reverse order (requires CONFIRM=DESTROY plus an approval). ACTION=SHUTDOWN: non-destructive, just stops every VM"
)

existing="$(cli list-jobs 2>/dev/null || true)"

for spec in "${JOBS[@]}"; do
    IFS='|' read -r name script desc <<< "$spec"

    tmp="$(mktemp)"
    sed -e "s|@@DESCRIPTION@@|${desc}|" \
        -e "s|@@REPO_URL@@|${REPO_URL}|" \
        -e "s|@@BRANCH@@|${BRANCH}|" \
        -e "s|@@SCRIPT_PATH@@|${script}|" \
        "$TEMPLATE" > "$tmp"

    if grep -qx "$name" <<< "$existing"; then
        cli update-job "$name" < "$tmp" && echo "  updated: $name"
    else
        cli create-job "$name" < "$tmp" && echo "  created: $name"
    fi
    rm -f "$tmp"
done

cat <<'NOTE'

Jobs registered. Two things to be aware of:

  1. Parameters do not exist until a job has run ONCE. Jenkins learns them from
     the Jenkinsfile's parameters{} block on the first build, so an initial
     `build <job> -p KEY=VALUE` fails with "not parameterized". Run each job
     bare once; the defaults are safe (APPLY=false plans only, and teardown
     aborts unless CONFIRM=DESTROY).

  2. These credentials must exist before the pipelines will run:
       oracle-sys   username/password   Oracle SYS
       oracle-app   username/password   Application schema owner
       wls-admin    username/password   WebLogic administrator
NOTE
