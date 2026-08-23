##
## Shared state location — see 30-nginx-multipass/backend.tf for why state must
## not live in a Jenkins job workspace.
##
## This stack has a second reason to be pinned here: the observability pipeline
## deploys AND destroys it as a unit, from two different ACTION runs of the same
## job. A workspace-local state would let a DESTROY run find nothing to destroy
## and report success while the VM kept running.
##
terraform {
  backend "local" {
    path = "/Users/prasad_mac/.homelab-iac/tfstate/40-obs-multipass.tfstate"
  }
}
