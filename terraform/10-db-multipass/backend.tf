##
## Shared state location.
##
## Jenkins gives every JOB its own workspace, so state written by one job is
## invisible to another. That made the teardown pipeline report
##   Destroy complete! Resources: 0 destroyed.
## while every VM kept running — a false success, the worst kind of failure.
##
## Pinning the state outside any workspace means the plan/apply job and the
## teardown job share one view of reality, and a workspace wipe cannot orphan
## live infrastructure.
##
terraform {
  backend "local" {
    path = "/home/jenkins/tfstate/10-db-multipass.tfstate"
  }
}
