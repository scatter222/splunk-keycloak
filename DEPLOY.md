# Deployment Instructions

## Your VM is Ready!

**VM Public IP**: 172.190.18.4
**SSH Command**: `ssh azureuser@172.190.18.4`

## Step 1: Upload Scripts to VM

From your PowerShell in this directory:

```powershell
scp -r scripts azureuser@172.190.18.4:/tmp/
```

## Step 2: SSH into VM

```powershell
ssh azureuser@172.190.18.4
```

## Step 3: Run the Installation (on the VM)

```bash
# Move scripts to installation directory
sudo mv /tmp/scripts /opt/install/scripts

# Make scripts executable
sudo chmod +x /opt/install/scripts/*.sh

# Run the master installation script (20-30 minutes)
sudo bash /opt/install/scripts/00-install-all.sh
```

This will:
1. Install FreeIPA (10-15 min)
2. Install KeyCloak (2-3 min)
3. Install Splunk (2-3 min)

## Step 4: Configure SAML SSO (on the VM)

After the installation completes:

```bash
# Configure KeyCloak to use FreeIPA LDAP
sudo bash /opt/install/scripts/04-configure-keycloak-ldap.sh

# Configure SAML between KeyCloak and Splunk
sudo bash /opt/install/scripts/05-configure-saml.sh
```

## Step 5: Test Your SSO!

Open in your browser:
- **Splunk**: http://172.190.18.4:8000

You should be automatically redirected to KeyCloak, where you can login with:
- **Username**: `testuser1`
- **Password**: `TestPass123!`

After successful authentication, you'll be redirected back to Splunk, logged in!

## Access Your Services

### FreeIPA
- **URL**: https://172.190.18.4
- **Admin**: `admin` / `Admin123!@#`

### KeyCloak
- **URL**: http://172.190.18.4:8080
- **Admin**: `admin` / `KeyCloak123!@#`
- **Realm**: `splunk`

### Splunk
- **URL**: http://172.190.18.4:8000
- **Admin**: `admin` / `Splunk123!@#`
- **Via SSO**: Login with `testuser1`, `testuser2`, or `testuser3` (password: `TestPass123!`)

## Test Users

Created in FreeIPA and available for SSO:
- `testuser1` / `TestPass123!` (member of `splunk-admins`)
- `testuser2` / `TestPass123!` (member of `splunk-users`)
- `testuser3` / `TestPass123!` (member of `splunk-users`)

## Quick Commands

```bash
# Check installation progress
tail -f /opt/install/installation.log

# Check service status
sudo systemctl status ipa
sudo systemctl status keycloak
sudo systemctl status Splunkd

# View saved credentials
cat /opt/install/freeipa-config.env
cat /opt/install/keycloak-config.env
cat /opt/install/splunk-config.env
```

## Troubleshooting

See `scripts/README.md` for detailed troubleshooting steps.

## Architecture

```
User Browser
    ↓
Splunk (SAML SP) on port 8000
    ↓ (SAML AuthN Request)
KeyCloak (SAML IdP) on port 8080
    ↓ (LDAP Query)
FreeIPA (LDAP + Kerberos) on ports 389/636/443
    ↓
User Authenticated → SAML Response → Logged into Splunk!
```
