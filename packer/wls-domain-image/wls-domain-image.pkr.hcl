##
## Packer — build the WebLogic Model-in-Image domain image.
##
## CRITICAL: the WDT model must NOT define a JDBC datasource. Anything declared
## here is created at domain-build time and re-initialised on every pod start; if
## the database is unreachable the managed servers fall into ADMIN mode
## (BEA-149259) and application deployment is blocked entirely. The application
## owns its own JDBC connections instead.
##
## Uses the docker builder against the Oracle WebLogic base image, which is
## already present locally (pulled from container-registry.oracle.com).
##

packer {
  required_plugins {
    docker = {
      source  = "github.com/hashicorp/docker"
      version = "~> 1.1"
    }
  }
}

variable "base_image" {
  type        = string
  description = "Oracle WebLogic base image."
  default     = "container-registry.oracle.com/middleware/weblogic:14.1.2.0-generic-jdk17-ol9"
}

variable "image_name" {
  type        = string
  description = "Output image repository."
  default     = "wls-domain-image"
}

variable "image_tag" {
  type        = string
  description = "Output image tag. Bump for every model change so rollback is possible."
  default     = "2.0"
}

variable "domain_name" {
  type        = string
  description = "WebLogic domain name."
  default     = "wls_domain"
}

variable "cluster_name" {
  type        = string
  description = "WebLogic cluster name. Must match the Terraform cluster_name."
  default     = "WLSCluster"
}

variable "managed_server_count" {
  type        = number
  description = "Managed servers defined in the model (minimum 2 JVMs)."
  default     = 2
}

source "docker" "wls" {
  image  = var.base_image
  commit = true
  # WDT runs as the oracle user; root is needed only to place files.
  run_command = ["-d", "-i", "-t", "--user", "root", "--entrypoint", "/bin/bash", "{{.Image}}"]
  changes = [
    "USER oracle",
    "WORKDIR /u01/oracle",
    "ENV DOMAIN_HOME=/u01/domains/${var.domain_name}",
    "ENTRYPOINT [\"/u01/oracle/createAndStartEmptyDomain.sh\"]",
  ]
}

build {
  name    = "wls-domain-image"
  sources = ["source.docker.wls"]

  provisioner "file" {
    source      = "${path.root}/model/"
    destination = "/tmp/model/"
  }

  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '[packer] staging WDT model'",
      "mkdir -p /u01/wdt/models",
      "cp /tmp/model/*.yaml /u01/wdt/models/ 2>/dev/null || true",
      "cp /tmp/model/*.properties /u01/wdt/models/ 2>/dev/null || true",
      "chown -R oracle:root /u01/wdt || true",
      "echo '[packer] verifying no datasource is baked into the model'",
      # Fail the build rather than ship an image that can wedge the domain.
      "if grep -RiEq '^[[:space:]]*JDBCSystemResource[[:space:]]*:' /u01/wdt/models/; then",
      "  echo 'FATAL: WDT model declares a JDBCSystemResource.' >&2",
      "  echo 'A baked-in datasource forces ADMIN mode when the DB is unreachable.' >&2",
      "  exit 1",
      "fi",
      "echo '[packer] model staged clean'",
    ]
  }

  post-processor "docker-tag" {
    repository = var.image_name
    tags       = [var.image_tag, "latest"]
  }

  post-processor "manifest" {
    output     = "${path.root}/.generated/manifest.json"
    strip_path = true
    custom_data = {
      image        = "${var.image_name}:${var.image_tag}"
      domain_name  = var.domain_name
      cluster_name = var.cluster_name
      servers      = "${var.managed_server_count}"
    }
  }
}
