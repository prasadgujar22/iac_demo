// ============================================================================
// Application-only redeploy — the fast inner loop.
//
// Rebuilds the WAR, redeploys to the existing WebLogic cluster, refreshes nginx
// routing and re-verifies. Touches no provisioning, so it is safe to run often.
//
// Requires the 'homelab' SSH agent (see jenkins/README.md).
// ============================================================================

pipeline {
    agent { label 'homelab' }

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '50'))
        timeout(time: 30, unit: 'MINUTES')
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

        stage('Deploy') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'oracle-app',
                    usernameVariable: 'ORA_APP_USER',
                    passwordVariable: 'ORA_APP_PASS')]) {
                    sh """#!/bin/bash
set -euo pipefail
                        cd ansible
                        ansible-playbook playbooks/deploy-app.yml \\
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
