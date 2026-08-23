variable "kubeconfig_path" {
  description = "Path to kubeconfig for the Multipass k8s cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Optional kube context override. Empty uses the current context."
  type        = string
  default     = ""
}

variable "namespace" {
  description = "Namespace for the WebLogic domain."
  type        = string
  default     = "wls-domain"
}

variable "domain_uid" {
  description = "WebLogic domainUID. Prefixes all operator-created resources."
  type        = string
  default     = "wlsdomain"
}

variable "domain_home" {
  description = "Domain home path inside the image."
  type        = string
  default     = "/u01/domains/wls_domain"
}

variable "domain_image" {
  description = "Model-in-Image domain image, produced by the Packer stage."
  type        = string

  # This default is the source of truth for every run that does NOT build an
  # image (the Jenkinsfile only passes -var domain_image when BUILD_IMAGE=true),
  # so it must always name a tag that (a) exists in containerd on every k8s node
  # -- nothing here pushes to a registry and pods pull IfNotPresent -- and
  # (b) contains the application.
  #
  # (b) is new and is why 2.6 is no longer valid: every 2.x image predates
  # baking the WAR into the image, so its WDT model declares no appDeployments.
  # Rolling the domain onto one now would bring the cluster up healthy and
  # completely empty -- HTTP 404 on every application URL, with nothing in the
  # logs that looks like a failure.
  default = "wls-domain-image:9.1"
}

variable "db_url" {
  description = <<-EOT
    JDBC URL injected into every server pod as the DB_URL environment variable.

    The application prefers this over the dbUrl context-param baked into its
    web.xml at build time (see DatabaseConfig). That matters because the WAR
    ships inside the domain image: without this, the database host is frozen at
    image-build time, and a database VM that comes back on a different address
    (Multipass pins addresses per VM but does not reserve them) leaves the image
    dialling the old one -- ORA-17820 at runtime, with a perfectly healthy
    cluster.

    Empty (the default) injects nothing at all, leaving the application on its
    web.xml fallback. That is the correct behaviour for DB_MODE=h2, which has
    no database to point at, and it keeps a bare `terraform apply` working.

    Changing this rolls the domain: the operator restarts pods when serverPod
    env changes, which is exactly how the new address reaches the application.
  EOT
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "WebLogic cluster name as defined in the WDT model."
  type        = string
  default     = "WLSCluster"
}

variable "admin_username" {
  description = "WebLogic administrator username. The password is generated."
  type        = string
  default     = "prasadmin"
}

variable "replicas" {
  description = "Managed server count. The brief requires a minimum of 2 JVMs."
  type        = number
  default     = 2

  validation {
    condition     = var.replicas >= 2
    error_message = "The application must run on at least 2 managed servers (JVMs)."
  }
}

variable "drop_datasources" {
  description = <<-EOT
    JDBC datasources to DELETE from the domain image's WDT model.

    Any datasource baked into the model is initialised at pod start; if its
    database is unreachable the managed servers drop into ADMIN mode and all
    application deployment is blocked. Let the application own its JDBC config.

    Defaults to empty: packer/wls-domain-image/model/wls-domain-model.yaml
    deliberately ships with NO JDBCSystemResource at all (see its header
    comment), so a delete directive here has nothing to delete. WDT's
    updateDomain.sh then logs "Unable to delete JDBCSystemResource <name>,
    name does not exist" as a WARNING but still exits 1, which the operator's
    modelInImage.sh treats as a hard introspection failure. Only set this if a
    *different* domain image actually bakes in a named datasource.
  EOT
  type        = list(string)
  default     = []
}

variable "managed_servers" {
  description = <<-EOT
    Managed servers to expose individually.

    Each needs its own NodePort so nginx can route by WebLogic JVM route ID for
    session affinity; the shared cluster service cannot target a single JVM.
    lan_ip/lan_port describe the socat bridge that publishes it on the LAN.
  EOT
  type = list(object({
    name     = string
    nodeport = number
    lan_ip   = string
    lan_port = number
  }))
  default = [
    { name = "ms1", nodeport = 30701, lan_ip = "192.168.29.201", lan_port = 8090 },
    { name = "ms2", nodeport = 30702, lan_ip = "192.168.29.202", lan_port = 8090 },
  ]

  validation {
    condition     = length(var.managed_servers) >= 2
    error_message = "At least 2 managed servers must be declared."
  }
  validation {
    condition     = length(distinct([for s in var.managed_servers : s.nodeport])) == length(var.managed_servers)
    error_message = "Each managed server needs a unique nodePort."
  }
}

variable "ms_listen_port" {
  description = "Managed server HTTP listen port."
  type        = number
  default     = 7003
}

variable "admin_nodeport" {
  description = "NodePort exposing the admin console."
  type        = number
  default     = 30070
}

variable "ms_cpu_request" {
  type        = string
  description = "CPU request per managed server pod."
  default     = "250m"
}

variable "ms_cpu_limit" {
  type        = string
  description = "CPU limit per managed server pod."
  default     = "1"
}

variable "ms_mem_request" {
  description = "Memory request. Each JVM runs -Xmx1536m, so keep headroom."
  type        = string
  default     = "1536Mi"
}

variable "ms_mem_limit" {
  type        = string
  description = "Memory limit per managed server pod."
  default     = "2560Mi"
}

variable "domain_ready_timeout" {
  description = "How long to wait for the domain to report Available (introspector + JVM starts)."
  type        = string
  default     = "20m"
}
