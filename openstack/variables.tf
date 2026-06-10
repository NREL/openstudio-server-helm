variable "openstack_user_name" {
  description = "The username for OpenStack. Can be set via TF_VAR_openstack_user_name environment variable."
  type        = string
  default     = null
}

variable "openstack_password" {
  description = "The password for OpenStack. Can be set via TF_VAR_openstack_password environment variable."
  type        = string
  sensitive   = true
  default     = null
}

variable "openstack_auth_url" {
  description = "The authentication URL for OpenStack. Set via tfvars or TF_VAR_openstack_auth_url environment variable."
  type        = string
  default     = null
  validation {
    condition     = var.openstack_auth_url != null
    error_message = "openstack_auth_url must be set via tfvars or TF_VAR_openstack_auth_url."
  }
  validation {
    condition     = var.openstack_auth_url == null || trimspace(var.openstack_auth_url) != ""
    error_message = "openstack_auth_url cannot be empty or whitespace."
  }
}

variable "openstack_tenant_name" {
  description = "The tenant name for OpenStack. Can be set via TF_VAR_openstack_tenant_name environment variable."
  type        = string
  default     = null
}

variable "openstack_user_domain_name" {
  description = "The user domain name for OpenStack. Can be set via TF_VAR_openstack_user_domain_name environment variable."
  type        = string
  default     = null
}

variable "openstack_project_domain_id" {
  description = "The project domain ID for OpenStack. Can be set via TF_VAR_openstack_project_domain_id environment variable."
  type        = string
  default     = null
}

variable "openstack_project_id" {
  description = "The project ID for OpenStack. Can be set via TF_VAR_openstack_project_id environment variable."
  type        = string
  default     = null
}

variable "openstack_region" {
  description = "The region for OpenStack. Can be set via TF_VAR_openstack_region environment variable."
  type        = string
  default     = "RegionOne"
}

variable "cluster_name" {
  description = "The name of the Kubernetes cluster."
  type        = string
  default     = "openstudio-server"
}

variable "master_flavor" {
  description = "The OpenStack flavor for the master node (should have sufficient resources for control plane)."
  type        = string
  default     = "CS.Wee" # 8 vCPUs, 32GB RAM
}

variable "web_count" {
  description = "The number of web nodes (for OpenStudio web services)."
  type        = number
  default     = 1
}

variable "web_flavor" {
  description = "The OpenStack flavor for web nodes (equivalent to EKS m7i.8xlarge for web workloads)."
  type        = string
  default     = "CS.2XMedium" # 32 vCPUs, 128GB RAM
}

variable "worker_count" {
  description = "The number of worker nodes (for compute-intensive simulations)."
  type        = number
  default     = 1
}

variable "worker_flavor" {
  description = "The OpenStack flavor for worker nodes (should be compute-optimized for simulations)."
  type        = string
  default     = "CM.XLarge" # 64 vCPUs, 128GB RAM, compute-optimized
}

variable "image_name" {
  description = "The name of the OpenStack image to use."
  type        = string
  default     = "ubuntu-jammy-kube-v1.33.2-250701-1108"
}

variable "volume_size" {
  description = "The size of the boot volume in GB."
  type        = number
  default     = 20
}

variable "key_pair" {
  description = "The name of the SSH key pair to use. Set via tfvars or TF_VAR_key_pair."
  type        = string
}

variable "os_username" {
  description = "The username for console access."
  type        = string
  default     = "ubuntu"
}

variable "os_password" {
  description = "The password for console access."
  type        = string
  sensitive   = true
  default     = null
}

variable "public_key" {
  description = "The SSH public key content. Set via tfvars or TF_VAR_public_key."
  type        = string
  sensitive   = true
}

variable "admin_access_cidr" {
  description = "Ingress CIDR for admin access (SSH/ICMP). REQUIRED: set via tfvars or TF_VAR_admin_access_cidr."
  type        = string
}

variable "k8s_api_access_cidr" {
  description = "Ingress CIDR for Kubernetes API port 6443. REQUIRED: set via tfvars or TF_VAR_k8s_api_access_cidr."
  type        = string
}

variable "nodeport_access_cidr" {
  description = "Ingress CIDR for NodePort services. REQUIRED: set via tfvars or TF_VAR_nodeport_access_cidr."
  type        = string
}
