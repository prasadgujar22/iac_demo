##
## Shared state location — see terraform/10-db-multipass/backend.tf for why.
##
terraform {
  backend "local" {
    path = "/home/jenkins/tfstate/05-k8s-multipass.tfstate"
  }
}
