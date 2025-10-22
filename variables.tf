variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-splunk-auth-lab"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "vm_name" {
  description = "Name of the virtual machine"
  type        = string
  default     = "vm-splunk-auth"
}

variable "vm_size" {
  description = "Size of the virtual machine"
  type        = string
  default     = "Standard_D4s_v3" # 4 vCPUs, 16GB RAM - good for running all 3 services
}

variable "admin_username" {
  description = "Admin username for the VM"
  type        = string
  default     = "azureuser"
}

variable "admin_password" {
  description = "Admin password for the VM (use SSH keys in production)"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for authentication (recommended over password)"
  type        = string
  default     = null
}

variable "os_disk_size_gb" {
  description = "Size of the OS disk in GB"
  type        = number
  default     = 128
}

variable "allowed_ssh_ips" {
  description = "List of IP addresses/ranges allowed to SSH to the VM"
  type        = list(string)
  default     = ["0.0.0.0/0"] # CHANGE THIS - allows all IPs by default
}

variable "allowed_http_ips" {
  description = "List of IP addresses/ranges allowed HTTP/HTTPS access"
  type        = list(string)
  default     = ["0.0.0.0/0"] # CHANGE THIS - allows all IPs by default
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Lab"
    Project     = "SplunkAuth"
    Purpose     = "SSO-Testing"
  }
}
