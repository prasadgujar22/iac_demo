#
# Homelab IaC — local driver. Jenkins runs the same targets.
#
.DEFAULT_GOAL := help
SHELL := /bin/bash

DB_MODE     ?= oracle
APP_BRANCH  ?= main
TF          := terraform
AP          := ansible-playbook

# 10-db is skipped in h2 mode: there is no database to provision.
ifeq ($(DB_MODE),oracle)
STACKS := 10-db-multipass 20-wls-k8s 30-nginx-multipass
else
STACKS := 20-wls-k8s 30-nginx-multipass
endif

.PHONY: help preflight validate init plan infra app verify destroy fmt clean ssh-key import

SSH_KEY ?= $(HOME)/.ssh/homelab_iac_ed25519

ssh-key: ## Generate the dedicated homelab-iac SSH keypair (idempotent)
	@if [ -f "$(SSH_KEY)" ]; then \
	  echo "key already exists: $(SSH_KEY)"; \
	else \
	  ssh-keygen -t ed25519 -N "" -C "homelab-iac@$$(hostname)" -f "$(SSH_KEY)"; \
	  echo "created $(SSH_KEY)"; \
	fi
	@chmod 600 "$(SSH_KEY)"; chmod 644 "$(SSH_KEY).pub"

help: ## Show available targets
	@echo "Homelab IaC — nginx (MicroCloud) / WebLogic (k8s) / Oracle XE (Multipass)"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "Variables: DB_MODE=$(DB_MODE) APP_BRANCH=$(APP_BRANCH)"

preflight: ## Verify toolchain and platform health (read-only)
	@./scripts/preflight.sh

validate: ## Static validation of terraform, ansible and packer
	@set -euo pipefail; \
	for d in terraform/*/; do \
	  echo "--- $$d"; \
	  $(TF) -chdir="$$d" init -backend=false -no-color >/dev/null; \
	  $(TF) -chdir="$$d" validate -no-color; \
	done
	@cd ansible && $(AP) playbooks/site.yml --syntax-check
	@cd ansible && $(AP) playbooks/deploy-app.yml --syntax-check
	@cd packer/wls-domain-image && packer init . >/dev/null && packer validate .
	@echo "validate: all artifacts OK"

init: ## terraform init for every stack
	@for s in $(STACKS); do $(TF) -chdir=terraform/$$s init -no-color; done

plan: preflight init ## Plan all stacks (no changes made)
	@for s in $(STACKS); do \
	  echo "=== plan $$s ==="; \
	  $(TF) -chdir=terraform/$$s plan -no-color; \
	done

infra: preflight init ## Provision infrastructure (prompts before applying)
	@printf "Apply infrastructure changes (DB_MODE=$(DB_MODE))? [y/N] "; \
	  read a; \
	  case "$$a" in \
	    [yY]|[yY][eE][sS]) ;; \
	    *) echo "aborted (answer y or yes)"; exit 1 ;; \
	  esac
	@for s in $(STACKS); do \
	  echo "=== apply $$s ==="; \
	  $(TF) -chdir=terraform/$$s apply -auto-approve -no-color || { \
	    echo ""; \
	    echo "!! apply failed for $$s"; \
	    echo "!! If the error is 'already exists', the resource was created"; \
	    echo "!! outside Terraform. Adopt it into state with:  make import"; \
	    exit 1; \
	  }; \
	done
	@cd ansible && $(AP) playbooks/site.yml -e "db_mode=$(DB_MODE)" -e "app_repo_version=$(APP_BRANCH)"

import: init ## Adopt existing hand-built infrastructure into Terraform state
	@./scripts/import-existing.sh

app: ## Build and deploy the application only
	@cd ansible && $(AP) playbooks/deploy-app.yml \
	  -e "db_mode=$(DB_MODE)" -e "app_repo_version=$(APP_BRANCH)"

verify: ## End-to-end verification incl. session affinity
	@cd ansible && $(AP) playbooks/site.yml --tags verify -e "db_mode=$(DB_MODE)"

image: ## Rebuild the WebLogic domain image with Packer
	@cd packer/wls-domain-image && packer build .

fmt: ## Format terraform and packer sources
	@$(TF) fmt -recursive terraform/
	@packer fmt packer/wls-domain-image/

destroy: ## Destroy infrastructure (DESTRUCTIVE — prompts twice)
	@echo "This destroys the nginx and WebLogic tiers."
	@read -p "Type DESTROY to continue: " a; \
	  [[ "$$a" == "DESTROY" ]] || { echo "aborted"; exit 1; }
	@$(TF) -chdir=terraform/30-nginx-multipass destroy -auto-approve -no-color
	@$(TF) -chdir=terraform/20-wls-k8s destroy -auto-approve -no-color
	@echo "Database tier retained. To remove it (DELETES ALL DATA):"
	@echo "  terraform -chdir=terraform/10-db-multipass destroy"

clean: ## Remove generated files and local build output
	@rm -rf terraform/*/.generated packer/*/.generated /tmp/homelab-iac-build
	@echo "cleaned"
