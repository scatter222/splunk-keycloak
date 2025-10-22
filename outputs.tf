output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "vm_name" {
  description = "Name of the virtual machine"
  value       = azurerm_linux_virtual_machine.main.name
}

output "public_ip_address" {
  description = "Public IP address of the VM"
  value       = azurerm_public_ip.main.ip_address
}

output "private_ip_address" {
  description = "Private IP address of the VM"
  value       = azurerm_network_interface.main.private_ip_address
}

output "admin_username" {
  description = "Admin username for SSH"
  value       = var.admin_username
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.main.ip_address}"
}

output "splunk_web_url" {
  description = "URL for Splunk Web interface"
  value       = "http://${azurerm_public_ip.main.ip_address}:8000"
}

output "keycloak_url" {
  description = "URL for KeyCloak admin console"
  value       = "http://${azurerm_public_ip.main.ip_address}:8080"
}

output "freeipa_url" {
  description = "URL for FreeIPA web interface"
  value       = "https://${azurerm_public_ip.main.ip_address}"
}
