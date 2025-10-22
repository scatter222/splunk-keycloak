# Production Implementation Guide: Splunk + KeyCloak + FreeIPA SSO

## Overview

This guide shows how to configure SAML SSO for Splunk using KeyCloak as the Identity Provider (IdP) and FreeIPA as the user directory.

## Architecture

```
User Browser
    ↓
Splunk (SAML Service Provider - SP)
    ↓ (SAML Authentication Request)
KeyCloak (SAML Identity Provider - IdP)
    ↓ (LDAP Query)
FreeIPA (User Directory - LDAP/Kerberos)
    ↓ (User Authentication)
KeyCloak (Issues SAML Assertion)
    ↓ (SAML Response)
Splunk (User Logged In)
```

---

## Prerequisites

Before starting, gather this information:

### FreeIPA Information
- **Domain**: e.g., `example.com`
- **Realm**: e.g., `EXAMPLE.COM`
- **Admin Password**: FreeIPA admin password
- **LDAP Bind DN**: `uid=admin,cn=users,cn=accounts,dc=example,dc=com`
- **Users Base DN**: `cn=users,cn=accounts,dc=example,dc=com`
- **Groups Base DN**: `cn=groups,cn=accounts,dc=example,dc=com`
- **FreeIPA Server IP/Hostname**: e.g., `ipa.example.com` or `192.168.1.10`

### KeyCloak Information
- **Admin Username**: Default is `admin`
- **Admin Password**: Your KeyCloak admin password
- **KeyCloak URL**: e.g., `https://keycloak.example.com` or `http://keycloak.example.com:8080`

### Splunk Information
- **Splunk URL**: e.g., `https://splunk.example.com:8000`
- **Admin Username**: Default is `admin`
- **Admin Password**: Your Splunk admin password

---

## Configuration Steps

### Phase 1: Configure FreeIPA

#### 1.1 Create Splunk User Groups in FreeIPA

```bash
# SSH to FreeIPA server
ssh root@ipa.example.com

# Authenticate as admin
kinit admin
# Enter FreeIPA admin password

# Create groups for Splunk access control
ipa group-add splunk-admins --desc="Splunk Administrators"
ipa group-add splunk-power-users --desc="Splunk Power Users"
ipa group-add splunk-users --desc="Splunk Regular Users"

# Add users to groups
ipa group-add-member splunk-admins --users=john,jane
ipa group-add-member splunk-users --users=bob,alice
```

#### 1.2 Verify FreeIPA LDAP Access

```bash
# Test LDAP connectivity
ldapsearch -x -H ldap://ipa.example.com:389 \
  -D "uid=admin,cn=users,cn=accounts,dc=example,dc=com" \
  -w "ADMIN_PASSWORD" \
  -b "cn=users,cn=accounts,dc=example,dc=com" \
  "(uid=john)"
```

**Variables for FreeIPA:**
- `FREEIPA_SERVER`: `ipa.example.com` (or IP)
- `FREEIPA_LDAP_PORT`: `389` (LDAP) or `636` (LDAPS)
- `FREEIPA_BIND_DN`: `uid=admin,cn=users,cn=accounts,dc=example,dc=com`
- `FREEIPA_BIND_PASSWORD`: FreeIPA admin password
- `FREEIPA_USERS_DN`: `cn=users,cn=accounts,dc=example,dc=com`
- `FREEIPA_GROUPS_DN`: `cn=groups,cn=accounts,dc=example,dc=com`

---

### Phase 2: Configure KeyCloak LDAP Federation

#### 2.1 Create Realm for Splunk

1. Login to KeyCloak Admin Console: `http://keycloak.example.com:8080/admin`
2. Click **Add Realm** (top left dropdown)
3. **Name**: `splunk`
4. **Enabled**: ON
5. Click **Create**

**Via CLI (`kcadm.sh`):**

```bash
# SSH to KeyCloak server
ssh root@keycloak.example.com

# Set KeyCloak home
export KEYCLOAK_HOME=/opt/keycloak

# Authenticate
${KEYCLOAK_HOME}/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password "KEYCLOAK_ADMIN_PASSWORD"

# Create realm
${KEYCLOAK_HOME}/bin/kcadm.sh create realms \
  -s realm=splunk \
  -s enabled=true \
  -s displayName="Splunk SSO Realm"
```

#### 2.2 Configure LDAP User Federation

**Via Web UI:**

1. In the `splunk` realm, go to **User Federation**
2. Click **Add provider** → **ldap**
3. Configure:

| Setting | Value |
|---------|-------|
| **Console Display Name** | `freeipa-ldap` |
| **Vendor** | `Red Hat Directory Server` |
| **Connection URL** | `ldap://ipa.example.com:389` |
| **Users DN** | `cn=users,cn=accounts,dc=example,dc=com` |
| **Bind Type** | `simple` |
| **Bind DN** | `uid=admin,cn=users,cn=accounts,dc=example,dc=com` |
| **Bind Credential** | FreeIPA admin password |
| **Edit Mode** | `READ_ONLY` |
| **Username LDAP attribute** | `uid` |
| **RDN LDAP attribute** | `uid` |
| **UUID LDAP attribute** | `ipaUniqueID` |
| **User Object Classes** | `inetOrgPerson, organizationalPerson` |

4. Click **Test connection** - should succeed
5. Click **Test authentication** - should succeed
6. Click **Save**

**Via CLI:**

```bash
${KEYCLOAK_HOME}/bin/kcadm.sh create components -r splunk \
  -s name=freeipa-ldap \
  -s providerId=ldap \
  -s providerType=org.keycloak.storage.UserStorageProvider \
  -s 'config.priority=["1"]' \
  -s 'config.enabled=["true"]' \
  -s 'config.editMode=["READ_ONLY"]' \
  -s 'config.vendor=["rhds"]' \
  -s 'config.usernameLDAPAttribute=["uid"]' \
  -s 'config.rdnLDAPAttribute=["uid"]' \
  -s 'config.uuidLDAPAttribute=["ipaUniqueID"]' \
  -s 'config.userObjectClasses=["inetOrgPerson, organizationalPerson"]' \
  -s 'config.connectionUrl=["ldap://ipa.example.com:389"]' \
  -s 'config.usersDn=["cn=users,cn=accounts,dc=example,dc=com"]' \
  -s 'config.authType=["simple"]' \
  -s 'config.bindDn=["uid=admin,cn=users,cn=accounts,dc=example,dc=com"]' \
  -s 'config.bindCredential=["FREEIPA_ADMIN_PASSWORD"]'
```

#### 2.3 Configure Group Mapper

**Via Web UI:**

1. In the LDAP provider, go to **Mappers** tab
2. Click **Add mapper**
3. Configure:

| Setting | Value |
|---------|-------|
| **Name** | `group-mapper` |
| **Mapper Type** | `group-ldap-mapper` |
| **LDAP Groups DN** | `cn=groups,cn=accounts,dc=example,dc=com` |
| **Group Name LDAP Attribute** | `cn` |
| **Group Object Classes** | `groupOfNames` |
| **Membership LDAP Attribute** | `member` |
| **Membership Attribute Type** | `DN` |
| **Mode** | `READ_ONLY` |

4. Click **Save**

**Via CLI:**

```bash
# Get LDAP provider ID
LDAP_ID=$(${KEYCLOAK_HOME}/bin/kcadm.sh get components -r splunk --fields id,name | grep -B1 "freeipa-ldap" | grep "id" | cut -d'"' -f4)

# Create group mapper
${KEYCLOAK_HOME}/bin/kcadm.sh create components -r splunk \
  -s name=group-mapper \
  -s providerId=group-ldap-mapper \
  -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
  -s "parentId=${LDAP_ID}" \
  -s 'config.mode=["READ_ONLY"]' \
  -s 'config.groups.dn=["cn=groups,cn=accounts,dc=example,dc=com"]' \
  -s 'config.group.name.ldap.attribute=["cn"]' \
  -s 'config.group.object.classes=["groupOfNames"]' \
  -s 'config.membership.ldap.attribute=["member"]' \
  -s 'config.membership.attribute.type=["DN"]'
```

#### 2.4 Sync Users from FreeIPA

```bash
# Trigger full sync
${KEYCLOAK_HOME}/bin/kcadm.sh create user-storage/${LDAP_ID}/sync?action=triggerFullSync -r splunk
```

**Verify in Web UI:**
1. Go to **Users** in the `splunk` realm
2. You should see all FreeIPA users listed

**Variables for KeyCloak LDAP:**
- `KEYCLOAK_REALM`: `splunk`
- `LDAP_CONNECTION_URL`: `ldap://ipa.example.com:389`
- `LDAP_BIND_DN`: `uid=admin,cn=users,cn=accounts,dc=example,dc=com`
- `LDAP_BIND_PASSWORD`: FreeIPA admin password
- `LDAP_USERS_DN`: `cn=users,cn=accounts,dc=example,dc=com`
- `LDAP_GROUPS_DN`: `cn=groups,cn=accounts,dc=example,dc=com`

---

### Phase 3: Configure KeyCloak SAML Client for Splunk

#### 3.1 Create SAML Client

**Via Web UI:**

1. In the `splunk` realm, go to **Clients**
2. Click **Create**
3. **Client ID**: `splunk-enterprise` (this is your Entity ID)
4. **Client Protocol**: `saml`
5. Click **Save**

#### 3.2 Configure SAML Client Settings

| Setting | Value |
|---------|-------|
| **Client ID** | `splunk-enterprise` |
| **Name** | `Splunk Enterprise` |
| **Enabled** | ON |
| **Sign Assertions** | ON |
| **Sign Documents** | OFF |
| **Client Signature Required** | OFF |
| **Force POST Binding** | ON |
| **Front Channel Logout** | ON |
| **Valid Redirect URIs** | `https://splunk.example.com:8000/*` |
| **Base URL** | `https://splunk.example.com:8000` |
| **Master SAML Processing URL** | `https://splunk.example.com:8000/saml/acs` |

**Via CLI:**

```bash
cat > /tmp/splunk-saml-client.json <<'EOF'
{
  "clientId": "splunk-enterprise",
  "name": "Splunk Enterprise",
  "enabled": true,
  "protocol": "saml",
  "frontchannelLogout": true,
  "attributes": {
    "saml.authnstatement": "true",
    "saml.server.signature": "true",
    "saml.signature.algorithm": "RSA_SHA256",
    "saml.client.signature": "false",
    "saml.assertion.signature": "true",
    "saml.encrypt": "false",
    "saml_force_name_id_format": "true",
    "saml_name_id_format": "username",
    "saml.force.post.binding": "true"
  },
  "redirectUris": ["https://splunk.example.com:8000/*"],
  "baseUrl": "https://splunk.example.com:8000",
  "adminUrl": "https://splunk.example.com:8000/saml/acs",
  "fullScopeAllowed": true
}
EOF

${KEYCLOAK_HOME}/bin/kcadm.sh create clients -r splunk -f /tmp/splunk-saml-client.json
```

#### 3.3 Add SAML Attribute Mappers

You need to map user attributes to SAML assertions:

**Required Mappers:**

1. **Username Mapper**
   - Name: `username`
   - Mapper Type: `User Property`
   - Property: `username`
   - SAML Attribute Name: `username`
   - SAML Attribute NameFormat: `Basic`

2. **Email Mapper**
   - Name: `email`
   - Mapper Type: `User Property`
   - Property: `email`
   - SAML Attribute Name: `email`
   - SAML Attribute NameFormat: `Basic`

3. **Role/Group Mapper**
   - Name: `role`
   - Mapper Type: `Role list`
   - Role attribute name: `role`
   - SAML Attribute NameFormat: `Basic`

**Via CLI:**

```bash
# Get client ID
CLIENT_ID=$(${KEYCLOAK_HOME}/bin/kcadm.sh get clients -r splunk --fields id,clientId | grep -B1 "splunk-enterprise" | grep "id" | cut -d'"' -f4)

# Add username mapper
${KEYCLOAK_HOME}/bin/kcadm.sh create clients/${CLIENT_ID}/protocol-mappers/models -r splunk \
  -s name=username \
  -s protocol=saml \
  -s protocolMapper=saml-user-property-mapper \
  -s 'config."attribute.nameformat"=Basic' \
  -s 'config."user.attribute"=username' \
  -s 'config."attribute.name"=username'

# Add email mapper
${KEYCLOAK_HOME}/bin/kcadm.sh create clients/${CLIENT_ID}/protocol-mappers/models -r splunk \
  -s name=email \
  -s protocol=saml \
  -s protocolMapper=saml-user-property-mapper \
  -s 'config."attribute.nameformat"=Basic' \
  -s 'config."user.attribute"=email' \
  -s 'config."attribute.name"=email'

# Add role mapper
${KEYCLOAK_HOME}/bin/kcadm.sh create clients/${CLIENT_ID}/protocol-mappers/models -r splunk \
  -s name=role \
  -s protocol=saml \
  -s protocolMapper=saml-role-list-mapper \
  -s 'config."attribute.nameformat"=Basic' \
  -s 'config."attribute.name"=role' \
  -s 'config."single"=false'
```

#### 3.4 Download KeyCloak SAML Metadata

You'll need this for Splunk configuration.

**Via Web UI:**
1. Go to **Realm Settings** → **SAML 2.0 Identity Provider Metadata**
2. Right-click and save the XML file

**Via CLI:**
```bash
curl -o /tmp/keycloak-idp-metadata.xml \
  "http://keycloak.example.com:8080/realms/splunk/protocol/saml/descriptor"
```

**Via Browser:**
Open: `http://keycloak.example.com:8080/realms/splunk/protocol/saml/descriptor`

**Variables for KeyCloak SAML:**
- `KEYCLOAK_REALM`: `splunk`
- `SAML_ENTITY_ID`: `splunk-enterprise`
- `SAML_ACS_URL`: `https://splunk.example.com:8000/saml/acs`
- `KEYCLOAK_IDP_SSO_URL`: `http://keycloak.example.com:8080/realms/splunk/protocol/saml`
- `KEYCLOAK_IDP_LOGOUT_URL`: `http://keycloak.example.com:8080/realms/splunk/protocol/saml`

---

### Phase 4: Configure Splunk SAML Authentication

#### 4.1 Extract KeyCloak Certificate

From the metadata XML you downloaded, extract the certificate:

```bash
# Extract certificate from metadata
grep -oP '(?<=<ds:X509Certificate>).*(?=</ds:X509Certificate>)' /tmp/keycloak-idp-metadata.xml | head -1 > /tmp/keycloak-cert-base64.txt

# Convert to PEM format
echo "-----BEGIN CERTIFICATE-----" > /tmp/keycloak.pem
cat /tmp/keycloak-cert-base64.txt >> /tmp/keycloak.pem
echo "-----END CERTIFICATE-----" >> /tmp/keycloak.pem
```

#### 4.2 Upload Certificate to Splunk

```bash
# SSH to Splunk server
ssh root@splunk.example.com

# Create directory for IdP certificates
mkdir -p /opt/splunk/etc/auth/idpCerts

# Copy certificate (use scp or paste content)
scp /tmp/keycloak.pem root@splunk.example.com:/opt/splunk/etc/auth/idpCerts/

# Set ownership
chown -R splunk:splunk /opt/splunk/etc/auth
```

#### 4.3 Configure Splunk SAML Settings

Create or edit `/opt/splunk/etc/system/local/authentication.conf`:

```ini
[authentication]
authType = SAML
authSettings = splunk_saml

[splunk_saml]
# REQUIRED: Your Splunk server's hostname (must match certificate if using HTTPS)
fqdn = splunk.example.com:8000

# REQUIRED: Port for SAML (usually same as Splunk Web)
redirectPort = 8000

# REQUIRED: Entity ID (must match KeyCloak client ID)
entityId = splunk-enterprise

# REQUIRED: KeyCloak SSO URL
idpSSOUrl = http://keycloak.example.com:8080/realms/splunk/protocol/saml

# REQUIRED: Path to KeyCloak certificate
idpCertPath = $SPLUNK_HOME/etc/auth/idpCerts/keycloak.pem

# OPTIONAL: Attribute query URL (leave empty if not used)
idpAttributeQueryUrl =

# REQUIRED: SAML NameID format
nameIdFormat = urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified

# REQUIRED: Should Splunk sign authentication requests?
signAuthnRequest = false

# REQUIRED: Should KeyCloak sign SAML assertions?
signedAssertion = true

# OPTIONAL: Attribute query settings
attributeQuerySSOUrl =
attributeQueryRequestSigned = false
attributeQueryResponseSigned = false

# OPTIONAL: Where to redirect after logout
redirectAfterLogoutToUrl =

# REQUIRED: Default role if no role mapping found
defaultRoleIfMissing = user

# OPTIONAL: Single Logout Service URL
singleLogoutServiceUrl = http://keycloak.example.com:8080/realms/splunk/protocol/saml
sloBinding = HTTPPost

# REQUIRED: Skip attribute query for these users (wildcard = all users)
skipAttributeQueryRequestForUsers = *

# REQUIRED: Signature algorithm
signatureAlgorithm = RSA-SHA256

# REQUIRED: SSO binding method
ssoBinding = HTTPPost

# REQUIRED: Replicate certificates across search head cluster
replicateCertificates = true
```

**Key Variables for Splunk:**
- `SPLUNK_FQDN`: `splunk.example.com:8000`
- `SPLUNK_ENTITY_ID`: `splunk-enterprise` (must match KeyCloak client ID)
- `KEYCLOAK_IDP_SSO_URL`: `http://keycloak.example.com:8080/realms/splunk/protocol/saml`
- `KEYCLOAK_CERT_PATH`: `$SPLUNK_HOME/etc/auth/idpCerts/keycloak.pem`

#### 4.4 Configure Splunk Role Mapping (Optional but Recommended)

Edit `/opt/splunk/etc/system/local/authorize.conf`:

Map FreeIPA groups to Splunk roles:

```ini
[roleMap_SAML]
# Map FreeIPA groups to Splunk roles
admin = splunk-admins
power = splunk-power-users
user = splunk-users

[role_admin]
# Inherits from admin role

[role_power]
# Inherits from power role

[role_user]
# Inherits from user role
```

#### 4.5 Restart Splunk

```bash
# Restart Splunk to apply SAML configuration
/opt/splunk/bin/splunk restart

# Or via systemd
systemctl restart Splunkd
```

---

## Testing the SSO Flow

### Step 1: Access Splunk

Open your browser: `https://splunk.example.com:8000`

### Step 2: Automatic Redirect

You should be automatically redirected to:
`http://keycloak.example.com:8080/realms/splunk/protocol/saml`

### Step 3: KeyCloak Login

Enter FreeIPA credentials:
- Username: `john` (or any FreeIPA user)
- Password: `<user's password>`

### Step 4: SAML Response

KeyCloak authenticates against FreeIPA via LDAP, then redirects back to Splunk with a SAML assertion.

### Step 5: Logged into Splunk

You should now be logged into Splunk as the FreeIPA user!

---

## Troubleshooting

### 1. Check Splunk SAML Logs

```bash
tail -f /opt/splunk/var/log/splunk/splunkd.log | grep -i saml
```

Common errors:
- **Certificate validation failed**: Certificate path incorrect or permissions wrong
- **Invalid issuer**: Entity ID mismatch between Splunk and KeyCloak
- **Invalid signature**: Certificate doesn't match or signing settings wrong

### 2. Check KeyCloak Logs

```bash
# For standalone KeyCloak
tail -f /opt/keycloak/data/log/keycloak.log

# For systemd-managed KeyCloak
journalctl -u keycloak -f
```

Look for:
- LDAP connection errors
- SAML client configuration issues
- User not found errors

### 3. Test LDAP Connectivity from KeyCloak

```bash
# From KeyCloak server
ldapsearch -x -H ldap://ipa.example.com:389 \
  -D "uid=admin,cn=users,cn=accounts,dc=example,dc=com" \
  -w "ADMIN_PASSWORD" \
  -b "cn=users,cn=accounts,dc=example,dc=com" \
  "(uid=john)"
```

### 4. Verify SAML Metadata

Compare these values:

**KeyCloak Metadata**: `http://keycloak.example.com:8080/realms/splunk/protocol/saml/descriptor`
**Splunk Configuration**: `/opt/splunk/etc/system/local/authentication.conf`

Ensure:
- Entity IDs match
- SSO URLs match
- Certificate is valid

### 5. Enable Debug Logging in Splunk

Edit `/opt/splunk/etc/log.cfg`:

```ini
[logger_SAML]
level = DEBUG
```

Restart Splunk and check logs for detailed SAML flow.

### 6. Test Direct KeyCloak Login

Go to: `http://keycloak.example.com:8080/realms/splunk/account`

Try logging in with FreeIPA credentials to verify LDAP federation works.

---

## Common Issues and Solutions

### Issue: "HTTPS Required" Error

**Problem**: KeyCloak requires HTTPS but you're using HTTP.

**Solution 1** - Disable HTTPS requirement (DEV ONLY):
```bash
${KEYCLOAK_HOME}/bin/kcadm.sh update realms/splunk -s sslRequired=NONE
```

**Solution 2** - Enable HTTPS properly (PRODUCTION):
1. Get SSL certificate for KeyCloak
2. Configure KeyCloak with HTTPS
3. Update all URLs to use `https://`

### Issue: Users Not Syncing from FreeIPA

**Problem**: KeyCloak can't connect to FreeIPA LDAP.

**Solutions**:
1. Check LDAP connection URL and port
2. Verify bind DN and password
3. Check firewall allows port 389/636
4. Test with `ldapsearch` command
5. Check FreeIPA logs: `journalctl -u ipa`

### Issue: Redirect Loop

**Problem**: Splunk redirects to KeyCloak, but KeyCloak redirects back without login.

**Solutions**:
1. Check Entity ID matches in both systems
2. Verify ACS URL in KeyCloak matches Splunk
3. Clear browser cookies
4. Check Splunk and KeyCloak are using consistent URLs (HTTP vs HTTPS)

### Issue: Certificate Errors

**Problem**: Splunk can't validate KeyCloak certificate.

**Solutions**:
1. Verify certificate file exists and has correct permissions
2. Certificate must be in PEM format
3. Check certificate path in authentication.conf
4. Ensure certificate matches KeyCloak's signing certificate

### Issue: Role Mapping Not Working

**Problem**: Users log in but have wrong permissions.

**Solutions**:
1. Verify group mapper configured in KeyCloak
2. Check authorize.conf roleMap_SAML section
3. Verify users are in correct FreeIPA groups
4. Check Splunk receives role attribute in SAML assertion

---

## Security Best Practices

### 1. Use HTTPS Everywhere

- Splunk: `https://splunk.example.com:8000`
- KeyCloak: `https://keycloak.example.com:8443`
- FreeIPA: Already uses HTTPS by default

### 2. Certificate Management

- Use proper SSL certificates (not self-signed in production)
- Rotate certificates regularly
- Use strong key sizes (2048-bit minimum)

### 3. Network Security

- Place KeyCloak and FreeIPA on internal network
- Use firewall rules to restrict access
- Consider VPN for administrative access

### 4. Password Policies

- Enforce strong passwords in FreeIPA
- Enable MFA in KeyCloak if needed
- Regular password rotation

### 5. Audit Logging

- Enable audit logging in Splunk
- Monitor KeyCloak logs for suspicious activity
- Review FreeIPA logs regularly

---

## Summary Checklist

### Phase 1: FreeIPA Setup
- [ ] Create groups for Splunk access (splunk-admins, splunk-users, etc.)
- [ ] Add users to appropriate groups
- [ ] Verify LDAP connectivity with ldapsearch
- [ ] Note down: domain, realm, bind DN, users DN, groups DN

### Phase 2: KeyCloak LDAP Federation
- [ ] Create realm (e.g., "splunk")
- [ ] Add LDAP user federation provider
- [ ] Configure connection to FreeIPA
- [ ] Add group mapper
- [ ] Trigger user sync
- [ ] Verify users appear in KeyCloak

### Phase 3: KeyCloak SAML Client
- [ ] Create SAML client (entity ID: splunk-enterprise)
- [ ] Configure valid redirect URIs
- [ ] Set Master SAML Processing URL (ACS URL)
- [ ] Add attribute mappers (username, email, role)
- [ ] Download SAML metadata descriptor

### Phase 4: Splunk SAML Configuration
- [ ] Extract certificate from KeyCloak metadata
- [ ] Upload certificate to Splunk
- [ ] Create authentication.conf with SAML settings
- [ ] Configure entity ID to match KeyCloak
- [ ] Set IdP SSO URL
- [ ] Configure role mapping (optional)
- [ ] Restart Splunk

### Phase 5: Testing
- [ ] Access Splunk URL
- [ ] Verify redirect to KeyCloak
- [ ] Login with FreeIPA credentials
- [ ] Verify redirect back to Splunk
- [ ] Confirm logged in with correct permissions
- [ ] Test with multiple users/roles

---

## Quick Reference: Variable Mapping

| Component | Variable | Example Value | Used In |
|-----------|----------|---------------|---------|
| **FreeIPA** | Domain | `example.com` | All configs |
| | Realm | `EXAMPLE.COM` | FreeIPA/Kerberos |
| | Server | `ipa.example.com` | KeyCloak LDAP |
| | Bind DN | `uid=admin,cn=users,cn=accounts,dc=example,dc=com` | KeyCloak LDAP |
| | Users DN | `cn=users,cn=accounts,dc=example,dc=com` | KeyCloak LDAP |
| | Groups DN | `cn=groups,cn=accounts,dc=example,dc=com` | KeyCloak LDAP |
| **KeyCloak** | Server URL | `http://keycloak.example.com:8080` | Splunk config |
| | Realm | `splunk` | All KeyCloak configs |
| | Entity ID | `splunk-enterprise` | SAML client & Splunk |
| | SSO URL | `http://keycloak.example.com:8080/realms/splunk/protocol/saml` | Splunk config |
| **Splunk** | Server URL | `https://splunk.example.com:8000` | KeyCloak client |
| | ACS URL | `https://splunk.example.com:8000/saml/acs` | KeyCloak client |
| | Entity ID | `splunk-enterprise` | Matches KeyCloak |
| | Certificate Path | `$SPLUNK_HOME/etc/auth/idpCerts/keycloak.pem` | Splunk config |

---

## Files to Backup

- `/opt/splunk/etc/system/local/authentication.conf`
- `/opt/splunk/etc/system/local/authorize.conf`
- `/opt/splunk/etc/auth/idpCerts/keycloak.pem`
- KeyCloak realm export (can be exported from Admin Console)
- FreeIPA group membership records

---

## Next Steps for Production

1. **Enable HTTPS** on all components
2. **Configure proper DNS** names instead of IPs
3. **Set up load balancing** for KeyCloak if needed
4. **Enable session timeout** policies
5. **Configure logout** properly (SLO - Single Logout)
6. **Set up monitoring** for SSO health
7. **Document** your specific configuration
8. **Train users** on SSO login flow
9. **Plan certificate rotation** schedule
10. **Set up backup** procedures

---

## Support and Resources

- **Splunk SAML Docs**: https://docs.splunk.com/Documentation/Splunk/latest/Security/ConfigureSplunkToUseSAML
- **KeyCloak SAML Docs**: https://www.keycloak.org/docs/latest/server_admin/#saml-clients
- **FreeIPA Docs**: https://www.freeipa.org/page/Documentation

---

**Document Version**: 1.0
**Last Updated**: October 2025
**Tested With**:
- FreeIPA 4.12.2
- KeyCloak 23.0.7
- Splunk Enterprise 9.3.2
