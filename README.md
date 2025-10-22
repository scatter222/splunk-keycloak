# Splunk + KeyCloak + FreeIPA SSO Lab

This project sets up an Azure VM to test SAML-based SSO integration between Splunk, KeyCloak, and FreeIPA.

## Architecture

```
User → Splunk (SAML SP) → KeyCloak (SAML IdP) → FreeIPA (User Directory)
```

- **FreeIPA**: LDAP directory + Kerberos authentication
- **KeyCloak**: SAML Identity Provider that authenticates against FreeIPA
- **Splunk**: Service Provider consuming SAML assertions from KeyCloak

## Prerequisites

1. **Azure CLI** - [Install Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
2. **Terraform** - [Install Terraform](https://www.terraform.io/downloads)
3. **Azure Subscription** - Active Azure account with permissions to create resources

## VM Specifications

- **OS**: Rocky Linux 9
- **Size**: Standard_D4s_v3 (4 vCPUs, 16GB RAM)
- **Disk**: 128GB Premium SSD
- **Network**: Public IP with NSG rules for all required services

### Ports Opened

| Service | Port | Purpose |
|---------|------|---------|
| SSH | 22 | Remote administration |
| HTTP | 80 | Web redirects |
| HTTPS | 443 | FreeIPA Web UI |
| Kerberos | 88 | FreeIPA authentication |
| LDAP | 389 | FreeIPA directory |
| LDAPS | 636 | FreeIPA secure directory |
| Splunk Web | 8000 | Splunk UI |
| KeyCloak | 8080 | KeyCloak admin/auth |
| Splunk Mgmt | 8089 | Splunk API |

## Setup Instructions

### 1. Authenticate with Azure

```bash
az login
az account list --output table
az account set --subscription "Your-Subscription-ID"
```

### 2. Configure Terraform Variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and customize:
- Your IP address for `allowed_ssh_ips` and `allowed_http_ips` (IMPORTANT!)
- SSH public key path
- Azure region
- Resource names and tags

### 3. Accept Rocky Linux Marketplace Terms

```bash
az vm image terms accept --publisher resf --offer rockylinux-x86_64 --plan 9-base
```

### 4. Initialize and Deploy

```bash
# Initialize Terraform
terraform init

# Preview changes
terraform plan

# Deploy infrastructure
terraform apply
```

### 5. Get Connection Details

```bash
terraform output
```

This will show:
- SSH connection command
- Public IP address
- URLs for Splunk, KeyCloak, and FreeIPA

## Connecting to the VM

```bash
# Use the output from terraform
ssh azureuser@<public-ip>

# Or use the SSH command from outputs
terraform output -raw ssh_command | bash
```

## Next Steps

After the VM is provisioned, you'll need to:

1. **Install and configure FreeIPA**
   - Set up domain and realm
   - Create test users

2. **Install and configure KeyCloak**
   - Set up LDAP federation to FreeIPA
   - Configure SAML IdP

3. **Install and configure Splunk**
   - Enable SAML authentication
   - Configure KeyCloak as SAML IdP

4. **Test SSO flow**
   - Log into Splunk using FreeIPA credentials via KeyCloak

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

## Cost Estimation

Standard_D4s_v3 in East US: ~$175/month (estimate)

Remember to destroy resources when not in use to avoid unnecessary charges!

## Security Notes

- Default configuration allows access from all IPs (`0.0.0.0/0`)
- **IMPORTANT**: Update `allowed_ssh_ips` and `allowed_http_ips` in `terraform.tfvars` to restrict access to your IP
- SSH key authentication is recommended over passwords
- This is a lab environment - additional hardening needed for production

## Troubleshooting

### "VMMarketplaceInvalidInput" or "Plan information required" error
You need to accept the marketplace terms first:
```bash
az vm image terms accept --publisher resf --offer rockylinux-x86_64 --plan 9-base
```

### SSH connection issues
- Check NSG rules allow your IP
- Verify SSH key was added correctly
- Check VM is running: `az vm list -d --output table`

### Terraform state issues
- State is stored locally in `terraform.tfstate`
- Don't delete this file or you'll lose track of your resources
- Consider using remote state for team environments
