// ============================================================================
// Application-only redeploy.
//
// Rebuilds the WAR, bakes it into a new domain image, rolls the running domain
// onto that image, then refreshes nginx routing and re-verifies. Provisioning
// (VMs, cluster, database) is untouched.
//
// Why an image build rather than a WLST deploy: the domain is Model-in-Image,
// so every pod regenerates $DOMAIN_HOME from the WDT model on each start. An
// application deployed at runtime lives only in that ephemeral domain home, so
// any pod restart silently brought the pod back with no application. The WAR
// is therefore part of the image (appDeployments in the model), and rolling
// out a change means a new image tag on the Domain resource.
//
// Cost of that: this job is no longer seconds-fast -- it is a packer build plus
// a rolling restart of the cluster. In exchange the deployment actually
// survives pod restarts, node drains and rescheduling.
//
// Requires the 'homelab' SSH agent (see jenkins/README.md).
// ============================================================================

pipeline {
    agent { label 'homelab' }

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '50'))
        timeout(time: 60, unit: 'MINUTES')
    }

    environment {
        // 'homelab' is this controller's own built-in node; its process PATH
        // depends on how Jenkins was launched (a LaunchAgent plist Homebrew
        // regenerates, stripped of any PATH override, on every `brew
        // services restart`) rather than anything the pipeline controls, so
        // it must be set explicitly here -- see jenkins/Jenkinsfile for the
        // full explanation. Without this, kubectl/helm/mvn are invisible.
        PATH = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:${env.PATH}"
    }

    parameters {
        string(name: 'APP_BRANCH', defaultValue: 'main',
               description: 'Application branch to build.')
        choice(name: 'DB_MODE', choices: ['oracle', 'h2'],
               description: 'Database backend for this deployment.')
        booleanParam(name: 'SKIP_VERIFY', defaultValue: false,
               description: 'Skip end-to-end verification. Not recommended.')
    }

    stages {
        stage('Preflight') {
            steps { sh './scripts/preflight.sh' }
        }

        stage('Domain health gate') {
            steps {
                // Deploying into a domain whose servers are in ADMIN mode appears to
                // succeed but the application never activates. Refuse to proceed.
                sh """#!/bin/bash
set -euo pipefail
                    STATES=\$(kubectl get domain wlsdomain -n wls-domain \\
                        -o jsonpath='{range .status.servers[*]}{.serverName}={.state} {end}')
                    echo "domain server states: \$STATES"
                    if echo "\$STATES" | grep -q "ADMIN"; then
                        echo "FATAL: a server is in ADMIN mode - deployment would not activate." >&2
                        echo "Usually a datasource baked into the WDT model failing to reach its DB." >&2
                        exit 1
                    fi
                    echo "\$STATES" | grep -q "RUNNING" || { echo "FATAL: no RUNNING servers" >&2; exit 1; }
                """
            }
        }

        stage('Build application image') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'oracle-app',
                    usernameVariable: 'ORA_APP_USER',
                    passwordVariable: 'ORA_APP_PASS')]) {
                    sh """#!/bin/bash
set -euo pipefail
                        cd ansible
                        ansible-playbook playbooks/build-app.yml \\
                          -e "db_mode=\${DB_MODE}" \\
                          -e "app_repo_version=\${APP_BRANCH}" \\
                          -e "oracle_app_user=\${ORA_APP_USER}" \\
                          -e "oracle_app_password=\${ORA_APP_PASS}"
                    """
                }
                sh '''#!/bin/bash
set -euo pipefail
                    cd packer/wls-domain-image
                    mkdir -p .generated
                    test -s .generated/archive.zip
                    # 3.x, not 2.x: homelab-iac tags its images 2.<its build
                    # number>, and the two jobs number independently -- sharing
                    # a series would let them overwrite each other's images.
                    packer build -var "image_tag=3.${BUILD_NUMBER}" .
                '''
                script { env.DOMAIN_IMAGE = "wls-domain-image:3.${env.BUILD_NUMBER}" }
            }
        }

        stage('Load image onto k8s nodes') {
            steps {
                // No registry in this homelab: packer only produces a local
                // docker image on this host, while the nodes pull from their
                // own containerd with imagePullPolicy IfNotPresent. Import it
                // onto every node or the new pods ErrImagePull.
                sh '''#!/bin/bash
set -euo pipefail
                    mp() { if multipass "$@" 2>/dev/null; then return 0; else sudo -n multipass "$@"; fi; }
                    MASTER_VM=$(echo 'var.master_name' | terraform -chdir=terraform/05-k8s-multipass console -no-color | tr -d '"')
                    WORKER_VMS=$(echo 'join(" ", var.worker_names)' | terraform -chdir=terraform/05-k8s-multipass console -no-color | tr -d '"')
                    TAG="wls-domain-image:3.${BUILD_NUMBER}"
                    TAR="packer/wls-domain-image/.generated/domain-image-3.${BUILD_NUMBER}.tar"
                    docker save "$TAG" -o "$TAR"
                    for vm in "$MASTER_VM" $WORKER_VMS; do
                        echo "[image] loading $TAG onto $vm"
                        mp transfer "$TAR" "$vm":/tmp/domain-image.tar
                        mp exec "$vm" -- sudo ctr -n k8s.io images import /tmp/domain-image.tar
                        mp exec "$vm" -- rm -f /tmp/domain-image.tar
                    done
                    rm -f "$TAR"
                '''
            }
        }

        stage('Roll the domain onto the new image') {
            steps {
                // Changing spec.image is what makes the operator restart the
                // servers onto the new application. Terraform waits for the
                // domain to report Available again, so this stage finishing
                // means the roll actually completed.
                sh """#!/bin/bash
set -euo pipefail
                    terraform -chdir=terraform/20-wls-k8s init -reconfigure -no-color -input=false
                    terraform -chdir=terraform/20-wls-k8s apply -no-color -auto-approve \\
                      -var "domain_image=${env.DOMAIN_IMAGE}"
                """
            }
        }

        stage('Refresh routing') {
            steps {
                // JVM route ids change when servers restart, so nginx must be
                // re-templated against the new ones or session affinity breaks.
                withCredentials([usernamePassword(
                    credentialsId: 'oracle-app',
                    usernameVariable: 'ORA_APP_USER',
                    passwordVariable: 'ORA_APP_PASS')]) {
                    sh """#!/bin/bash
set -euo pipefail
                        cd ansible
                        # --skip-tags verify: the Verify stage below owns
                        # verification (and honours SKIP_VERIFY). Running it
                        # here too would repeat the destructive pod-kill check.
                        ansible-playbook playbooks/deploy-app.yml --skip-tags verify \\
                          -e "db_mode=\${DB_MODE}" \\
                          -e "app_repo_version=\${APP_BRANCH}" \\
                          -e "oracle_app_user=\${ORA_APP_USER}" \\
                          -e "oracle_app_password=\${ORA_APP_PASS}"
                    """
                }
            }
        }

        stage('Verify') {
            when { expression { !params.SKIP_VERIFY } }
            steps {
                sh """#!/bin/bash
set -euo pipefail
                    cd ansible
                    ansible-playbook playbooks/site.yml --tags verify -e "db_mode=\${DB_MODE}"
                """
            }
        }
    }

    post {
        success {
            script {
                // Resolve the real Multipass proxy IP the same way Jenkinsfile's
                // main pipeline banner does; this host has no physical LAN, so the
                // upstream 192.168.29.200 address is unreachable here.
                def proxyIp = sh(
                    script: '''#!/bin/bash
set -uo pipefail
terraform -chdir=terraform/30-nginx-multipass init -reconfigure -no-color -input=false >/dev/null 2>&1
terraform -chdir=terraform/30-nginx-multipass output -raw proxy_internal_ip 2>/dev/null
''',
                    returnStdout: true
                ).trim()
                if (!proxyIp) { proxyIp = '192.168.29.200' }
                echo "Deployed. http://${proxyIp}/customer-onboarding/login"
            }
        }
        failure {
            echo 'Deploy failed. If the app returns 503, check whether the managed servers fell into ADMIN mode: kubectl get domain wlsdomain -n wls-domain -o jsonpath="{.status.servers[*].state}"'
        }
    }
}
