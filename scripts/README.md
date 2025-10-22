# Installation Scripts

These scripts automate the installation and configuration of FreeIPA, KeyCloak, and Splunk with SAML SSO.

## Scripts Overview

| Script | Purpose | Duration |
|--------|---------|----------|
| `00-install-all.sh` | Master script - runs all installations | 20-30 min |
| `01-install-freeipa.sh` | Installs and configures FreeIPA | 10-15 min |
| `02-install-keycloak.sh` | Installs and configures KeyCloak | 2-3 min |
| `03-install-splunk.sh` | Installs Splunk Enterprise | 2-3 min |
| `04-configure-keycloak-ldap.sh` | Connects KeyCloak to FreeIPA LDAP | 1 min |
| `05-configure-saml.sh` | Configures SAML SSO between services | 2 min |

## Quick Start

### Option 1: Run Everything (Recommended)

```bash
# Upload scripts to VM
scp -r scripts azureuser@172.190.18.4:/tmp/

# SSH to VM
ssh azureuser@172.190.18.4

# Move scripts and run
sudo mv /tmp/scripts /opt/install/scripts
sudo chmod +x /opt/install/scripts/*.sh
sudo bash /opt/install/scripts/00-install-all.sh
```

### Option 2: Manual Step-by-Step

```bash
# Upload scripts
scp -r scripts azureuser@172.190.18.4:/tmp/
ssh azureuser@172.190.18.4
sudo mv /tmp/scripts /opt/install/scripts
sudo chmod +x /opt/install/scripts/*.sh

# Install components
sudo bash /opt/install/scripts/01-install-freeipa.sh
sudo bash /opt/install/scripts/02-install-keycloak.sh
sudo bash /opt/install/scripts/03-install-splunk.sh

# Configure SAML SSO
sudo bash /opt/install/scripts/04-configure-keycloak-ldap.sh
sudo bash /opt/install/scripts/05-configure-saml.sh
```

## Default Credentials

All credentials are stored in `/opt/install/*.env` files on the VM after installation.

### FreeIPA
- **URL**: `https://<VM-IP>`
- **Admin User**: `admin`
- **Admin Password**: `Admin123!@#`
- **Domain**: `splunkauth.lab`
- **Test Users**: `testuser1`, `testuser2`, `testuser3` (password: `TestPass123!`)

### KeyCloak
- **URL**: `http://<VM-IP>:8080`
- **Admin User**: `admin`
- **Admin Password**: `KeyCloak123!@#`
- **Realm**: `splunk`

### Splunk
- **URL**: `http://<VM-IP>:8000`
- **Admin User**: `admin`
- **Admin Password**: `Splunk123!@#`

## Testing SSO

1. Open Splunk in browser: `http://<VM-IP>:8000`
2. You should be redirected to KeyCloak login
3. Login with: `testuser1` / `TestPass123!`
4. You'll be redirected back to Splunk, logged in!

## Troubleshooting

### FreeIPA Installation Issues
- Check logs: `journalctl -u ipa`
- Verify DNS: `dig @localhost splunkauth.lab`

### KeyCloak Not Starting
- Check logs: `journalctl -u keycloak`
- Verify Java: `java -version` (should be Java 17+)

### Splunk SAML Issues
- Check Splunk logs: `tail -f /opt/splunk/var/log/splunk/splunkd.log`
- Verify certificate: `ls -l /opt/splunk/etc/auth/idpCerts/`
- Test direct login: `http://<VM-IP>:8000/en-US/account/login`

### LDAP Federation Issues
- Test LDAP connectivity: `ldapsearch -x -H ldap://<VM-IP>:389 -D "uid=admin,cn=users,cn=accounts,dc=splunkauth,dc=lab" -w Admin123!@# -b "cn=users,cn=accounts,dc=splunkauth,dc=lab"`
- Check KeyCloak Admin Console → User Federation → ldap-freeipa

## Configuration Files

After installation, configuration is stored in:
- FreeIPA: `/etc/ipa/`
- KeyCloak: `/opt/keycloak/conf/`
- Splunk: `/opt/splunk/etc/system/local/authentication.conf`

## Architecture Flow

```
User → Splunk (SAML SP) → KeyCloak (SAML IdP) → FreeIPA (LDAP)
                ↓                                    ↑
           SAML Response                         LDAP Query
                ↓                                    ↑
         Authenticated User ← ← ← ← ← ← ← ← ← ← ← ← ←
```

## Important Notes

- All passwords are for LAB USE ONLY - change them in production!
- FreeIPA requires a fully qualified domain name
- KeyCloak runs in dev mode for simplicity
- Splunk is configured with HTTP (not HTTPS) for lab testing
