##
## Stack 20 — WebLogic domain on Kubernetes
##
## Encodes two hard-won constraints:
##
## 1. NEVER bake a JDBC datasource into the domain image's WDT model. If the
##    database is unreachable at pod start, WebLogic initialises the datasource,
##    fails, and forces the managed servers into ADMIN mode (BEA-149259) — which
##    silently blocks all application deployment. This stack therefore ships a
##    WDT override ConfigMap that DELETES the datasource ('!OracleDS'), and the
##    application manages its own JDBC connections instead.
##
## 2. The CRD apiVersion differs per kind: Domain is weblogic.oracle/v9 while
##    Cluster is weblogic.oracle/v1. Using v1 for Domain fails with
##    "no matches for kind Domain in version weblogic.oracle/v1".
##
## Domain/Cluster are managed as kubernetes_manifest so Terraform owns them
## declaratively rather than shelling out to kubectl.
##

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    local      = { source = "hashicorp/local", version = "~> 2.4" }
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context != "" ? var.kube_context : null
}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "wls" {
  metadata {
    name = var.namespace
    labels = {
      "weblogic-operator" = "enabled"
      "managed-by"        = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# Credentials
#
# Passwords are generated, never hardcoded, and never emitted to logs or plan
# output. Terraform state contains them, so state must be treated as sensitive.
# ---------------------------------------------------------------------------
resource "random_password" "wls_admin" {
  length           = 20
  special          = true
  override_special = "_-" # WLST/boot.properties choke on some symbols
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
}

resource "random_password" "runtime_encryption" {
  length  = 32
  special = false # must survive being passed through WDT
}

resource "kubernetes_secret" "wls_credentials" {
  metadata {
    name      = "${var.domain_uid}-weblogic-credentials"
    namespace = kubernetes_namespace.wls.metadata[0].name
  }
  data = {
    username = var.admin_username
    password = random_password.wls_admin.result
  }
  type = "Opaque"

  lifecycle {
    # Rotating this on an EXISTING domain breaks it: the password is baked into
    # each server's boot.properties at domain-creation time, so the managed
    # servers can no longer authenticate to the admin server. Terraform would
    # otherwise overwrite an imported secret with a freshly generated password.
    # To rotate deliberately, change it in WebLogic first, then update here.
    ignore_changes = [data]
  }
}

resource "kubernetes_secret" "runtime_encryption" {
  metadata {
    name      = "${var.domain_uid}-runtime-encryption-secret"
    namespace = kubernetes_namespace.wls.metadata[0].name
  }
  data = { password = random_password.runtime_encryption.result }
  type = "Opaque"

  lifecycle {
    # Changing this invalidates the encrypted WDT model of an existing domain,
    # forcing a full re-introspection and domain rebuild. Never rotate it
    # implicitly on a running domain.
    ignore_changes = [data]
  }
}

# ---------------------------------------------------------------------------
# WDT model override — delete the baked-in datasource
#
# The '!' prefix is WDT's delete directive. Runtime WLST deletion does NOT work
# here: cmo.destroy() raises AttributeError and delete() reports "mbeanType
# cannot be null". Even if it succeeded, the model would recreate the datasource
# on the next restart. This must be fixed at model level.
# ---------------------------------------------------------------------------
resource "kubernetes_config_map" "wdt_override" {
  metadata {
    name      = "${var.domain_uid}-wdt-override"
    namespace = kubernetes_namespace.wls.metadata[0].name
  }
  data = {
    "model-drop-datasources.yaml" = yamlencode({
      resources = {
        JDBCSystemResource = {
          for ds in var.drop_datasources : "!${ds}" => null
        }
      }
    })
  }
}

# ---------------------------------------------------------------------------
# Cluster resource (apiVersion v1 — differs from Domain)
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "cluster" {
  manifest = {
    apiVersion = "weblogic.oracle/v1"
    kind       = "Cluster"
    metadata = {
      name      = "${var.domain_uid}-${lower(var.cluster_name)}"
      namespace = kubernetes_namespace.wls.metadata[0].name
    }
    spec = {
      clusterName = var.cluster_name
      replicas    = var.replicas
      serverPod = {
        resources = {
          requests = { cpu = var.ms_cpu_request, memory = var.ms_mem_request }
          limits   = { cpu = var.ms_cpu_limit, memory = var.ms_mem_limit }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.wls]
}

# ---------------------------------------------------------------------------
# Domain resource (apiVersion v9)
#
# webLogicCredentialsSecret is MANDATORY. Omitting it makes the introspector job
# invalid before it can run:
#   Job "<uid>-introspector" is invalid:
#     spec.template.spec.volumes[0].secret.secretName: Required value
#     volumeMounts[0].name: Not found: "weblogic-credentials-volume"
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "domain" {
  manifest = {
    apiVersion = "weblogic.oracle/v9"
    kind       = "Domain"
    metadata = {
      name      = var.domain_uid
      namespace = kubernetes_namespace.wls.metadata[0].name
    }
    spec = {
      domainUID            = var.domain_uid
      domainHome           = var.domain_home
      domainHomeSourceType = "FromModel"
      image                = var.domain_image
      imagePullPolicy      = "IfNotPresent"

      webLogicCredentialsSecret = {
        name = kubernetes_secret.wls_credentials.metadata[0].name
      }

      includeServerOutInPodLog = true
      httpAccessLogInLogHome   = true
      replicas                 = var.replicas

      adminServer = {
        # When true, the operator's readiness/liveness probes hard-require a
        # dedicated SSL "administration channel" on port 9002. WebLogic
        # 14.1.2 keeps binding that channel to 127.0.0.1 only regardless of
        # ListenAddress settings in the WDT model, so the probe gets
        # "connection refused" against the pod IP forever even though the
        # server is genuinely RUNNING. Disabling this makes the operator
        # probe the regular admin port instead, which correctly binds to the
        # pod IP. The only capability lost is kubectl port-forward-style
        # direct access to the admin channel — irrelevant here since the
        # admin console is already reachable via its NodePort.
        adminChannelPortForwardingEnabled = false
        serverStartPolicy                 = "IfNeeded"
        # Without an explicit request, the scheduler has no idea AdminServer's
        # JVM (-Xmx1536m) needs real memory, and happily stacks it onto the
        # same node as a managed server — which is exactly how the 3GB worker
        # ended up hosting AdminServer *and* ms2 simultaneously, thrashed
        # under memory pressure, and got its kubelet OOM-killed mid-deploy
        # (kubectl exec into the pod died with exit 137). Requesting/limiting
        # comparably to a managed server lets the scheduler bin-pack correctly
        # across the master (4G) and worker (3G) nodes.
        serverPod = {
          resources = {
            requests = { cpu = var.ms_cpu_request, memory = "1024Mi" }
            limits   = { cpu = var.ms_cpu_limit, memory = "1792Mi" }
          }
        }
        adminService = {
          channels = [{ channelName = "default", nodePort = var.admin_nodeport }]
        }
      }

      clusters = [{ name = kubernetes_manifest.cluster.manifest.metadata.name }]

      configuration = {
        model = {
          domainType              = "WLS"
          runtimeEncryptionSecret = kubernetes_secret.runtime_encryption.metadata[0].name
          configMap               = kubernetes_config_map.wdt_override.metadata[0].name
        }
        overrideDistributionStrategy = "Dynamic"
      }

      failureRetryIntervalSeconds   = 120
      failureRetryLimitMinutes      = 1440
      maxClusterConcurrentShutdown  = 1
      maxClusterConcurrentStartup   = 0
      maxClusterUnavailable         = 1
      replaceVariablesInJavaOptions = false
    }
  }

  # Wait for the operator to report the domain Available rather than returning
  # as soon as the CR is accepted.
  wait {
    condition {
      type   = "Available"
      status = "True"
    }
  }
  timeouts { create = var.domain_ready_timeout }

  depends_on = [
    kubernetes_secret.wls_credentials,
    kubernetes_secret.runtime_encryption,
    kubernetes_config_map.wdt_override,
    kubernetes_manifest.cluster,
  ]
}

# ---------------------------------------------------------------------------
# Per-managed-server NodePort services
#
# The nginx tier needs to address INDIVIDUAL managed servers for JSESSIONID
# route-ID affinity, which the operator's shared cluster service cannot provide.
# Selecting on weblogic.serverName pins each service to exactly one JVM.
# ---------------------------------------------------------------------------
resource "kubernetes_service" "managed_server" {
  for_each = { for i, s in var.managed_servers : s.name => merge(s, { idx = i }) }

  metadata {
    name      = "${var.domain_uid}-${each.key}-nodeport"
    namespace = kubernetes_namespace.wls.metadata[0].name
    labels    = { "managed-by" = "terraform", "wls-server" = each.key }
  }

  spec {
    type = "NodePort"
    selector = {
      "weblogic.domainUID"  = var.domain_uid
      "weblogic.serverName" = each.key
    }
    port {
      port        = var.ms_listen_port
      target_port = var.ms_listen_port
      node_port   = each.value.nodeport
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_manifest.domain]
}

# ---------------------------------------------------------------------------
# Handoff for the nginx tier and Ansible
# ---------------------------------------------------------------------------
resource "local_file" "wls_facts" {
  filename = "${path.module}/.generated/wls_facts.yaml"
  content = yamlencode({
    namespace      = var.namespace
    domain_uid     = var.domain_uid
    cluster_name   = var.cluster_name
    admin_nodeport = var.admin_nodeport
    ms_listen_port = var.ms_listen_port
    managed_servers = [
      for s in var.managed_servers : {
        name     = s.name
        nodeport = s.nodeport
        lan_ip   = s.lan_ip
        lan_port = s.lan_port
      }
    ]
  })
  file_permission = "0644"
}
