# Resource Group
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# Virtual Network
resource "azurerm_virtual_network" "main" {
  name                = "${var.vm_name}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# Subnet
resource "azurerm_subnet" "main" {
  name                 = "${var.vm_name}-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Public IP
resource "azurerm_public_ip" "main" {
  name                = "${var.vm_name}-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# Network Security Group
resource "azurerm_network_security_group" "main" {
  name                = "${var.vm_name}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  # SSH
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.allowed_ssh_ips
    destination_address_prefix = "*"
  }

  # Splunk Web (8000)
  security_rule {
    name                       = "Splunk-Web"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8000"
    source_address_prefixes    = var.allowed_http_ips
    destination_address_prefix = "*"
  }

  # Splunk Management (8089)
  security_rule {
    name                       = "Splunk-Management"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8089"
    source_address_prefixes    = var.allowed_http_ips
    destination_address_prefix = "*"
  }

  # KeyCloak (8080)
  security_rule {
    name                       = "KeyCloak"
    priority                   = 1004
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefixes    = var.allowed_http_ips
    destination_address_prefix = "*"
  }

  # FreeIPA Web UI (443)
  security_rule {
    name                       = "FreeIPA-HTTPS"
    priority                   = 1005
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefixes    = var.allowed_http_ips
    destination_address_prefix = "*"
  }

  # HTTP (for redirects and Let's Encrypt if needed)
  security_rule {
    name                       = "HTTP"
    priority                   = 1006
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefixes    = var.allowed_http_ips
    destination_address_prefix = "*"
  }

  # LDAP (389) - for FreeIPA
  security_rule {
    name                       = "LDAP"
    priority                   = 1007
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "389"
    source_address_prefixes    = var.allowed_http_ips
    destination_address_prefix = "*"
  }

  # LDAPS (636) - for FreeIPA
  security_rule {
    name                       = "LDAPS"
    priority                   = 1008
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "636"
    source_address_prefixes    = var.allowed_http_ips
    destination_address_prefix = "*"
  }

  # Kerberos (88) - for FreeIPA
  security_rule {
    name                       = "Kerberos"
    priority                   = 1009
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "88"
    source_address_prefixes    = var.allowed_http_ips
    destination_address_prefix = "*"
  }
}

# Network Interface
resource "azurerm_network_interface" "main" {
  name                = "${var.vm_name}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.main.id
  }
}

# Associate NSG with Network Interface
resource "azurerm_network_interface_security_group_association" "main" {
  network_interface_id      = azurerm_network_interface.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

# Virtual Machine
resource "azurerm_linux_virtual_machine" "main" {
  name                = var.vm_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = var.tags

  network_interface_ids = [
    azurerm_network_interface.main.id,
  ]

  # Use SSH key if provided, otherwise use password
  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key != null ? var.ssh_public_key : file("~/.ssh/id_rsa.pub")
  }

  disable_password_authentication = var.ssh_public_key != null ? true : false

  os_disk {
    name                 = "${var.vm_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  # Using Rocky Linux 9 - excellent for FreeIPA and enterprise apps
  source_image_reference {
    publisher = "resf"
    offer     = "rockylinux-x86_64"
    sku       = "9-base"
    version   = "latest"
  }

  # Marketplace plan required for Rocky Linux
  plan {
    name      = "9-base"
    product   = "rockylinux-x86_64"
    publisher = "resf"
  }

  # Basic initialization
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # Update system
    dnf update -y

    # Install basic tools
    dnf install -y git wget curl vim tmux htop net-tools

    # Set timezone to UTC
    timedatectl set-timezone UTC

    # Increase file limits for Splunk
    cat >> /etc/security/limits.conf <<LIMITS
    * soft nofile 65536
    * hard nofile 65536
    * soft nproc 16384
    * hard nproc 16384
    LIMITS

    # Create installation directory
    mkdir -p /opt/install
    chown ${var.admin_username}:${var.admin_username} /opt/install

    echo "VM initialization complete - $(date)" > /opt/install/init-complete.txt
  EOF
  )
}
