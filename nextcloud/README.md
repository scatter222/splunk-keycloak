# Nextcloud + Keycloak + FreeIPA SSO Lab

Single Azure VM running Nextcloud with SAML-based SSO through Keycloak, backed by FreeIPA for user/group management.

## Architecture

```
User Browser
    |
Nextcloud (Apache, port 80)         -- SAML Service Provider
    |  (SAML Auth Request)
Keycloak (port 8081)                 -- SAML Identity Provider
    |  (LDAP Query)
FreeIPA (LDAP 389 / Kerberos 88)    -- User Directory
    |
[User Authenticated]
    |  (SAML Assertion)
Keycloak -> Nextcloud (User Logged In)
```

## Prerequisites

- Azure CLI authenticated (`az login`)
- Terraform >= 1.0
- SSH key pair at `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub`

## Quick Start

```bash
cd nextcloud/

# 1. Configure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars - set allowed_ssh_ips and allowed_http_ips to your IP

# 2. Deploy VM
terraform init
terraform plan
terraform apply

# 3. SSH in and install everything (~20-30 min)
ssh azureuser@<PUBLIC_IP>
sudo bash /opt/install/scripts/00-install-all.sh
```

## Services & Credentials

| Service   | URL                          | Username   | Password          |
|-----------|------------------------------|------------|--------------------|
| FreeIPA   | `https://<IP>`               | admin      | Admin123!@#        |
| Keycloak  | `http://<IP>:8081`           | admin      | KeyCloakAdmin123     |
| Nextcloud | `http://<IP>`                | admin      | Nextcloud123!@#    |

### Test Users (FreeIPA)

| User      | Password     | Group             |
|-----------|-------------|-------------------|
| testuser1 | TestPass123! | nextcloud-admins  |
| testuser2 | TestPass123! | nextcloud-users   |
| testuser3 | TestPass123! | nextcloud-users   |

## Scripts

| Script | Purpose | Duration |
|--------|---------|----------|
| `00-install-all.sh` | Master orchestrator (runs 01-05) | 20-30 min |
| `01-install-freeipa.sh` | FreeIPA server + DNS + test users | 10-15 min |
| `02-install-keycloak.sh` | Keycloak 23.0.7 installation | 2-3 min |
| `03-install-nextcloud.sh` | Nextcloud + Apache + MariaDB + PHP | 3-5 min |
| `04-configure-keycloak-ldap.sh` | Keycloak LDAP federation with FreeIPA | 1 min |
| `05-configure-nextcloud-saml.sh` | SAML SSO between Keycloak and Nextcloud | 1-2 min |

## Testing SSO

1. Open `http://<PUBLIC_IP>/login` in your browser
2. Click "SSO & SAML log in"
3. You'll be redirected to Keycloak
4. Log in with `testuser1` / `TestPass123!`
5. You'll be redirected back to Nextcloud, logged in

Local admin login is always available at: `http://<IP>/login?direct=1`

## Troubleshooting

- **SAML login fails**: Check Keycloak admin -> Events tab for errors
- **DNS issues after FreeIPA install**: Scripts have built-in DNS fallback
- **Nextcloud "untrusted domain"**: Run `sudo -u apache php /var/www/nextcloud/occ config:system:set trusted_domains 1 --value="<IP>"`
- **SELinux blocking Apache**: Run `setsebool -P httpd_unified 1`

## Cleanup

```bash
terraform destroy
```
