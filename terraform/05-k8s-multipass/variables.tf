variable "image" {
  description = "Multipass image alias. Must match a kubeadm-supported Ubuntu release."
  type        = string
  default     = "24.04"
}

variable "k8s_minor_version" {
  description = "Kubernetes minor version line, as published under pkgs.k8s.io (e.g. v1.31)."
  type        = string
  default     = "v1.31"
}

variable "pod_cidr" {
  description = "Pod network CIDR. Must match the Flannel manifest's default network."
  type        = string
  default     = "10.244.0.0/16"
}

variable "master_name" {
  description = "Multipass instance name for the k8s control-plane node."
  type        = string
  default     = "k8s-master"
}

variable "master_cpus" {
  type    = number
  default = 2
}

variable "master_memory" {
  description = "RAM for the control-plane node."
  type        = string
  default     = "4G"
}

variable "master_disk" {
  type    = string
  default = "20G"
}

variable "worker_names" {
  description = "Multipass instance names for k8s worker nodes."
  type        = list(string)
  default     = ["k8s-worker-1"]
}

variable "worker_cpus" {
  type    = number
  default = 2
}

variable "worker_memory" {
  description = "RAM per worker node."
  type        = string
  default     = "3G"
}

variable "worker_disk" {
  type    = string
  default = "20G"
}

variable "launch_timeout" {
  description = "Seconds multipass may take to launch before failing."
  type        = number
  default     = 600
}

variable "kubeadm_timeout" {
  description = "Seconds to wait for kubeadm init / join / node-ready."
  type        = number
  default     = 600
}

variable "install_weblogic_operator" {
  description = "Install the WebLogic Kubernetes Operator via Helm once the cluster is up."
  type        = bool
  default     = true
}

variable "weblogic_operator_version" {
  description = "weblogic-kubernetes-operator Helm chart version."
  type        = string
  default     = "4.3.15"
}

variable "kubeconfig_path" {
  description = "Local kubeconfig file to write/merge the new cluster's admin context into."
  type        = string
  default     = "~/.kube/config"
}

variable "ssh_public_key_path" {
  description = "Public key injected via cloud-init. Create it with `make ssh-key`."
  type        = string
  default     = "~/.ssh/homelab_iac_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Matching private key, written into the generated inventory."
  type        = string
  default     = "~/.ssh/homelab_iac_ed25519"
}
