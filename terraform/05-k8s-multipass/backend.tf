##
## Shared state location — see terraform/10-db-multipass/backend.tf for why.
##
terraform {
  backend "local" {
    path = "/Users/prasad_mac/.homelab-iac/tfstate/05-k8s-multipass.tfstate"
  }
}
