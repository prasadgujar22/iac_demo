#!/usr/bin/env bash
#
# Adopt EXISTING infrastructure into Terraform state.
#
# The WebLogic domain, nginx VM and OVN forward on this host were created by
# hand before the IaC repo existed. Terraform does not know about them, so
# `apply` tries to CREATE them and fails with "already exists".
#
# This script imports them instead. It is idempotent: resources already in state
# are skipped, and it never creates or destroys anything.
#
# Usage:  ./scripts/import-existing.sh [stack]
#         stack = 20-wls-k8s | 30-nginx-microcloud | all   (default: all)
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:-all}"

NS="${NS:-wls-domain}"
UID_="${DOMAIN_UID:-wlsdomain}"
LXD_INSTANCE="${LXD_INSTANCE:-webserver}"
LXD_NETWORK="${LXD_NETWORK:-default}"
LXD_FORWARD="${LXD_FORWARD:-192.168.29.200}"

ok()   { printf "  \033[32m[imported]\033[0m %s\n" "$*"; }
skip() { printf "  \033[33m[in state]\033[0m %s\n" "$*"; }
miss() { printf "  \033[36m[absent]  \033[0m %s\n" "$*"; }
fail() { printf "  \033[31m[FAILED]  \033[0m %s\n" "$*"; }

# import <stack-dir> <terraform-address> <resource-id> <existence-check-cmd>
import_one() {
    local dir="$1" addr="$2" id="$3" check="$4"

    if terraform -chdir="$dir" state list 2>/dev/null | grep -qxF "$addr"; then
        skip "$addr"
        return 0
    fi
    if ! eval "$check" >/dev/null 2>&1; then
        miss "$addr (nothing live to import)"
        return 0
    fi
    if terraform -chdir="$dir" import -no-color -input=false "$addr" "$id" >/dev/null 2>&1; then
        ok "$addr"
    else
        fail "$addr  (retry manually: terraform -chdir=$dir import '$addr' '$id')"
        return 1
    fi
}

RC=0

# ---------------------------------------------------------------------------
# 20-wls-k8s
# ---------------------------------------------------------------------------
if [[ "$STACK" == "all" || "$STACK" == "20-wls-k8s" ]]; then
    D="$ROOT/terraform/20-wls-k8s"
    echo "== 20-wls-k8s =="
    terraform -chdir="$D" init -no-color -input=false >/dev/null 2>&1

    import_one "$D" "kubernetes_namespace.wls" "$NS" \
        "kubectl get ns $NS" || RC=1

    import_one "$D" "kubernetes_secret.wls_credentials" "$NS/${UID_}-weblogic-credentials" \
        "kubectl get secret ${UID_}-weblogic-credentials -n $NS" || RC=1

    import_one "$D" "kubernetes_secret.runtime_encryption" "$NS/${UID_}-runtime-encryption-secret" \
        "kubectl get secret ${UID_}-runtime-encryption-secret -n $NS" || RC=1

    import_one "$D" "kubernetes_config_map.wdt_override" "$NS/${UID_}-wdt-override" \
        "kubectl get configmap ${UID_}-wdt-override -n $NS" || RC=1

    # NodePort services are a for_each map, so the address carries the key.
    for ms in ms1 ms2; do
        import_one "$D" "kubernetes_service.managed_server[\"$ms\"]" "$NS/${UID_}-${ms}-nodeport" \
            "kubectl get svc ${UID_}-${ms}-nodeport -n $NS" || RC=1
    done

    # kubernetes_manifest CANNOT be imported - the provider does not support it.
    # Remove the hand-made CRs and let Terraform recreate them, or leave them
    # managed outside Terraform. See the note printed at the end.
    echo "  [note]     Domain/Cluster CRs cannot be imported (kubernetes_manifest limitation)"
fi

# ---------------------------------------------------------------------------
# 30-nginx-microcloud
# ---------------------------------------------------------------------------
if [[ "$STACK" == "all" || "$STACK" == "30-nginx-microcloud" ]]; then
    D="$ROOT/terraform/30-nginx-microcloud"
    echo "== 30-nginx-microcloud =="
    terraform -chdir="$D" init -no-color -input=false >/dev/null 2>&1

    import_one "$D" "lxd_instance.nginx" "$LXD_INSTANCE" \
        "sudo lxc info $LXD_INSTANCE" || RC=1

    # The LXD provider requires a leading [remote:][project] segment, so the ID
    # is "/<network>/<listen_address>" — a bare "network/address" is rejected
    # with "Import ID does not contain all required fields".
    import_one "$D" "lxd_network_forward.proxy" "/${LXD_NETWORK}/${LXD_FORWARD}" \
        "sudo lxc network forward show $LXD_NETWORK $LXD_FORWARD" || RC=1
fi

echo
if [ "$RC" -eq 0 ]; then
    echo "import complete. Now run 'make plan' and review carefully:"
else
    echo "one or more imports FAILED (see above). Run 'make plan' before applying:"
fi
cat <<'EOT'

  Expect the plan to show CHANGES to imported resources - the live objects were
  created by hand and will differ from the code (labels, annotations, resource
  limits). Review each diff before applying; some are cosmetic, others may
  restart pods.

  The WebLogic Domain and Cluster CRs cannot be imported: the Terraform
  kubernetes_manifest resource has no import support. Options:
    a) leave them managed outside Terraform (comment out those resources), or
    b) delete and let Terraform recreate them - THIS RESTARTS THE DOMAIN:
         kubectl delete domain wlsdomain -n wls-domain
         kubectl delete cluster wlsdomain-wlscluster -n wls-domain
       (the Cluster CR survives a Domain delete, so remove both)
EOT
exit "$RC"
