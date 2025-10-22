# Upload scripts to VM after it's created
resource "null_resource" "upload_scripts" {
  depends_on = [azurerm_linux_virtual_machine.main]

  # Trigger re-upload if any script changes
  triggers = {
    script_hash = sha256(join("", [
      for f in fileset("${path.module}/scripts", "*.sh") : filesha256("${path.module}/scripts/${f}")
    ]))
  }

  connection {
    type        = "ssh"
    user        = var.admin_username
    host        = azurerm_public_ip.main.ip_address
    private_key = file("~/.ssh/id_rsa")
  }

  # Upload entire scripts directory
  provisioner "file" {
    source      = "${path.module}/scripts"
    destination = "/tmp/scripts"
  }

  # Move scripts to /opt/install and make executable
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /opt/install",
      "sudo rm -rf /opt/install/scripts",
      "sudo mv /tmp/scripts /opt/install/scripts",
      "sudo chmod +x /opt/install/scripts/*.sh",
      "ls -la /opt/install/scripts/",
      "echo 'Scripts uploaded successfully to /opt/install/scripts'"
    ]
  }
}

output "scripts_uploaded" {
  description = "Confirmation that scripts were uploaded"
  value       = "Scripts uploaded to /opt/install/scripts on VM"
  depends_on  = [null_resource.upload_scripts]
}

output "installation_command" {
  description = "Command to run full installation"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.main.ip_address} 'sudo bash /opt/install/scripts/00-install-all.sh'"
  depends_on  = [null_resource.upload_scripts]
}
