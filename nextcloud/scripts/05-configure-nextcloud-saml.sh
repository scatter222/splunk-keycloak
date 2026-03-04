#!/bin/bash
###############################################################################
# 05-configure-nextcloud-saml.sh
#
# Configures Keycloak with a SAML client for Nextcloud, then configures
# Nextcloud's user_saml app to use it.
#
# Assumes:
#   - Keycloak is already running with the 'nextcloud' realm and LDAP configured
#   - Nextcloud is already installed
#   - Scripts 01-04 have been run
###############################################################################

set -euo pipefail

echo "======================================"
echo "Nextcloud SAML + Keycloak Setup"
echo "======================================"

# Load configuration from previous scripts
source /opt/install/keycloak-config.env
source /opt/install/nextcloud-config.env

KEYCLOAK_REALM="nextcloud"

# Get the public IP for browser-facing URLs
PUBLIC_IP=$(curl -s --max-time 10 -4 https://api.ipify.org 2>/dev/null || curl -s --max-time 10 -4 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo "Detected public IP: ${PUBLIC_IP}"

NEXTCLOUD_PUBLIC_URL="http://${PUBLIC_IP}"
# Use localhost for Keycloak API calls (runs on same machine)
KC_API="http://localhost:8081"
# Use public IP for browser-facing SAML URLs
KC_BROWSER="http://${PUBLIC_IP}:8081"

# SAML Client ID (Nextcloud's entity ID)
SAML_CLIENT_ID="${NEXTCLOUD_PUBLIC_URL}/apps/user_saml/saml/metadata"

# Check for required tools
for cmd in curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: '$cmd' is required but not installed."
        echo "  Install with: sudo dnf install $cmd"
        exit 1
    fi
done

# Check Nextcloud occ is available
if [ ! -f "${NEXTCLOUD_PATH}/occ" ]; then
    echo "ERROR: Nextcloud occ not found at ${NEXTCLOUD_PATH}/occ"
    exit 1
fi

# Helper to run occ commands
occ() {
    sudo -u "${NEXTCLOUD_USER}" php "${NEXTCLOUD_PATH}/occ" "$@"
}

#==============================================================================
# STEP 1: Get Keycloak admin access token
#==============================================================================

echo "[1/7] Authenticating with Keycloak..."

KC_TOKEN=$(curl -s -X POST \
    "${KC_API}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" | jq -r '.access_token')

if [ "$KC_TOKEN" = "null" ] || [ -z "$KC_TOKEN" ]; then
    echo "ERROR: Failed to authenticate with Keycloak."
    exit 1
fi

echo "  Authenticated with Keycloak"

#==============================================================================
# STEP 2: Create the SAML client in Keycloak
#==============================================================================

echo "[2/7] Creating SAML client in Keycloak..."

# Build the client JSON
CLIENT_JSON=$(cat <<EOF
{
    "clientId": "${SAML_CLIENT_ID}",
    "name": "Nextcloud",
    "description": "Nextcloud SAML Service Provider",
    "protocol": "saml",
    "enabled": true,
    "rootUrl": "${NEXTCLOUD_PUBLIC_URL}",
    "baseUrl": "${NEXTCLOUD_PUBLIC_URL}",
    "redirectUris": ["${NEXTCLOUD_PUBLIC_URL}/*"],
    "adminUrl": "${NEXTCLOUD_PUBLIC_URL}/apps/user_saml/saml/acs",
    "attributes": {
        "saml.authnstatement": "true",
        "saml.server.signature": "true",
        "saml.assertion.signature": "true",
        "saml.force.post.binding": "true",
        "saml.client.signature": "false",
        "saml_name_id_format": "username",
        "saml_single_logout_service_url_post": "${NEXTCLOUD_PUBLIC_URL}/apps/user_saml/saml/sls",
        "saml_assertion_consumer_url_post": "${NEXTCLOUD_PUBLIC_URL}/apps/user_saml/saml/acs",
        "saml_single_logout_service_url_redirect": "${NEXTCLOUD_PUBLIC_URL}/apps/user_saml/saml/sls"
    },
    "fullScopeAllowed": true,
    "frontchannelLogout": true
}
EOF
)

# Check if client already exists
EXISTING_CLIENTS=$(curl -s \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    "${KC_API}/admin/realms/${KEYCLOAK_REALM}/clients" | \
    jq -r --arg cid "$SAML_CLIENT_ID" '.[] | select(.clientId == $cid) | .id')

if [ -n "$EXISTING_CLIENTS" ]; then
    echo "  Client already exists (ID: ${EXISTING_CLIENTS}). Updating..."
    KC_CLIENT_UUID="$EXISTING_CLIENTS"
    curl -s -X PUT \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_JSON" \
        "${KC_API}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}"
    echo "  Client updated"
else
    # Create new client
    HTTP_CODE=$(curl -s -o /tmp/kc_response.txt -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_JSON" \
        "${KC_API}/admin/realms/${KEYCLOAK_REALM}/clients")

    if [ "$HTTP_CODE" = "201" ]; then
        echo "  Client created"
    else
        echo "  ERROR: Failed to create client (HTTP ${HTTP_CODE})"
        cat /tmp/kc_response.txt
        exit 1
    fi

    # Get the UUID of the new client
    KC_CLIENT_UUID=$(curl -s \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KC_API}/admin/realms/${KEYCLOAK_REALM}/clients" | \
        jq -r --arg cid "$SAML_CLIENT_ID" '.[] | select(.clientId == $cid) | .id')
fi

echo "  Client UUID: ${KC_CLIENT_UUID}"

# Disable SSL requirement on the realm — Keycloak defaults to sslRequired: "external"
# which blocks HTTP-based SAML flows
echo "  Disabling SSL requirement on '${KEYCLOAK_REALM}' realm..."
curl -s -X PUT \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"realm":"'"${KEYCLOAK_REALM}"'","sslRequired":"none"}' \
    "${KC_API}/admin/realms/${KEYCLOAK_REALM}"
echo "  SSL requirement disabled"

#==============================================================================
# STEP 3: Add SAML protocol mappers
#==============================================================================

echo "[3/7] Adding SAML attribute mappers..."

add_mapper() {
    local NAME="$1"
    local ATTRIBUTE_NAME="$2"
    local USER_PROPERTY="$3"

    MAPPER_JSON=$(cat <<MAPEOF
{
    "name": "${NAME}",
    "protocol": "saml",
    "protocolMapper": "saml-user-property-mapper",
    "config": {
        "user.attribute": "${USER_PROPERTY}",
        "friendly.name": "${NAME}",
        "attribute.name": "${ATTRIBUTE_NAME}",
        "attribute.nameformat": "Basic"
    }
}
MAPEOF
)

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$MAPPER_JSON" \
        "${KC_API}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}/protocol-mappers/models")

    if [ "$HTTP_CODE" = "201" ]; then
        echo "  Mapper '${NAME}' created"
    elif [ "$HTTP_CODE" = "409" ]; then
        echo "  Mapper '${NAME}' already exists, skipping"
    else
        echo "  WARNING: Mapper '${NAME}' returned HTTP ${HTTP_CODE}"
    fi
}

# Add user property mappers
add_mapper "username"  "uid"       "username"
add_mapper "email"     "email"     "email"
add_mapper "firstName" "firstName" "firstName"
add_mapper "lastName"  "lastName"  "lastName"

# Add group list mapper (different type)
GROUP_MAPPER_JSON=$(cat <<EOF
{
    "name": "groups",
    "protocol": "saml",
    "protocolMapper": "saml-group-membership-mapper",
    "config": {
        "attribute.name": "groups",
        "attribute.nameformat": "Basic",
        "single": "true",
        "full.path": "false",
        "friendly.name": "groups"
    }
}
EOF
)

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$GROUP_MAPPER_JSON" \
    "${KC_API}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}/protocol-mappers/models")

if [ "$HTTP_CODE" = "201" ]; then
    echo "  Mapper 'groups' created"
elif [ "$HTTP_CODE" = "409" ]; then
    echo "  Mapper 'groups' already exists, skipping"
else
    echo "  WARNING: Mapper 'groups' returned HTTP ${HTTP_CODE}"
fi

# Fix the role_list client scope mapper — default has single: false which creates
# duplicate <Attribute Name="Role"> elements. onelogin/php-saml rejects this with
# "Found an Attribute element with duplicated Name"
echo "  Fixing role_list scope mapper (single=true)..."

# Find the role_list client scope ID
ROLE_LIST_SCOPE_ID=$(curl -s \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    "${KC_API}/admin/realms/${KEYCLOAK_REALM}/client-scopes" | \
    jq -r '.[] | select(.name == "role_list") | .id')

if [ -n "$ROLE_LIST_SCOPE_ID" ]; then
    # Find the role list mapper within that scope
    ROLE_LIST_MAPPER=$(curl -s \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KC_API}/admin/realms/${KEYCLOAK_REALM}/client-scopes/${ROLE_LIST_SCOPE_ID}/protocol-mappers/models")

    ROLE_MAPPER_ID=$(echo "$ROLE_LIST_MAPPER" | jq -r '.[] | select(.name == "role list") | .id')

    if [ -n "$ROLE_MAPPER_ID" ]; then
        # Get full mapper, update single to true, PUT it back
        MAPPER_JSON=$(echo "$ROLE_LIST_MAPPER" | jq --arg id "$ROLE_MAPPER_ID" '.[] | select(.id == $id) | .config.single = "true"')
        curl -s -X PUT \
            -H "Authorization: Bearer ${KC_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$MAPPER_JSON" \
            "${KC_API}/admin/realms/${KEYCLOAK_REALM}/client-scopes/${ROLE_LIST_SCOPE_ID}/protocol-mappers/models/${ROLE_MAPPER_ID}"
        echo "  role_list mapper updated (single=true)"
    else
        echo "  WARNING: role list mapper not found in role_list scope"
    fi
else
    echo "  WARNING: role_list client scope not found"
fi

#==============================================================================
# STEP 4: Retrieve IdP certificate from Keycloak
#==============================================================================

echo "[4/7] Retrieving Keycloak IdP signing certificate..."

# Fetch the SAML descriptor using localhost API
SAML_DESCRIPTOR=$(curl -s "${KC_API}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor")

# Extract the X509 certificate from the SAML metadata XML
IDP_CERT=$(echo "$SAML_DESCRIPTOR" | \
    python3 -c "
import sys, xml.etree.ElementTree as ET
ns = {
    'md': 'urn:oasis:names:tc:SAML:2.0:metadata',
    'ds': 'http://www.w3.org/2000/09/xmldsig#'
}
tree = ET.parse(sys.stdin)
root = tree.getroot()
for kd in root.findall('.//md:IDPSSODescriptor/md:KeyDescriptor[@use=\"signing\"]/ds:KeyInfo/ds:X509Data/ds:X509Certificate', ns):
    print(kd.text.strip())
    break
else:
    for kd in root.findall('.//ds:X509Certificate', ns):
        print(kd.text.strip())
        break
")

if [ -z "$IDP_CERT" ]; then
    echo "  WARNING: Could not extract IdP certificate automatically."
    echo "    Get it from: ${KC_BROWSER}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor"
    IDP_CERT="PASTE_YOUR_CERTIFICATE_HERE"
else
    echo "  IdP certificate retrieved"
fi

# Build the full PEM-formatted certificate for Nextcloud
IDP_CERT_FORMATTED="-----BEGIN CERTIFICATE-----
${IDP_CERT}
-----END CERTIFICATE-----"

#==============================================================================
# STEP 5: Enable and configure Nextcloud user_saml app
#==============================================================================

echo "[5/7] Configuring Nextcloud SAML..."

# Add public IP as trusted domain
occ config:system:set trusted_domains 1 --value="${PUBLIC_IP}"

# Enable the user_saml app
echo "  Enabling user_saml app..."
occ app:enable user_saml 2>/dev/null || echo "  (app may already be enabled)"

# Global user_saml settings
occ config:app:set user_saml type --value="saml" 2>/dev/null || true
occ config:app:set user_saml general-allow_multiple_user_back_ends --value="1"
occ config:app:set user_saml general-require_provisioned_account --value="0"

# user_saml v7.x stores providers in oc_user_saml_configurations table
# Must use occ saml:config:create + saml:config:set (NOT config:app:set)
echo "  Creating SAML provider entry..."
PROVIDER_ID=$(occ saml:config:create)
echo "  Provider ID: ${PROVIDER_ID}"

echo "  Setting Identity Provider configuration..."
occ saml:config:set "${PROVIDER_ID}" \
    --general-idp0_display_name="Keycloak SSO" \
    --idp-entityId="${KC_BROWSER}/realms/${KEYCLOAK_REALM}" \
    --idp-singleSignOnService.url="${KC_BROWSER}/realms/${KEYCLOAK_REALM}/protocol/saml" \
    --idp-singleLogoutService.url="${KC_BROWSER}/realms/${KEYCLOAK_REALM}/protocol/saml" \
    --idp-x509cert="${IDP_CERT_FORMATTED}" \
    --sp-entityId="${SAML_CLIENT_ID}" \
    --sp-name-id-format="urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified" \
    --general-uid_mapping="uid" \
    --saml-attribute-mapping-displayName_mapping="firstName" \
    --saml-attribute-mapping-email_mapping="email" \
    --saml-attribute-mapping-group_mapping="groups"

echo "  Nextcloud SAML configuration complete"

#==============================================================================
# STEP 6: Patch user_saml cookie for HTTP compatibility
#==============================================================================

echo "[6/7] Patching user_saml cookie SameSite for HTTP..."

# user_saml sets saml_data cookie with SameSite=None, which requires HTTPS.
# On HTTP, the browser silently drops the cookie, causing "Cookie was not present" errors.
# Since we're same-site (same IP, different port), Lax works fine.
SAML_CONTROLLER="${NEXTCLOUD_PATH}/apps/user_saml/lib/Controller/SAMLController.php"
if [ -f "$SAML_CONTROLLER" ]; then
    if grep -q "'saml_data', \$data, null, 'None'" "$SAML_CONTROLLER" 2>/dev/null; then
        sed -i "s/'saml_data', \$data, null, 'None'/'saml_data', \$data, null, 'Lax'/g" "$SAML_CONTROLLER"
        echo "  SameSite patched from None to Lax"
    elif grep -q "'None'" "$SAML_CONTROLLER" 2>/dev/null; then
        sed -i "s/'None'/'Lax'/g" "$SAML_CONTROLLER"
        echo "  SameSite patched (generic replacement)"
    else
        echo "  WARNING: Could not find SameSite=None in SAMLController.php (may already be patched)"
    fi
else
    echo "  WARNING: SAMLController.php not found at ${SAML_CONTROLLER}"
fi

#==============================================================================
# STEP 7: Summary
#==============================================================================

echo ""
echo "======================================"
echo "SETUP COMPLETE"
echo "======================================"
echo ""
echo "Keycloak SAML Client:"
echo "  Client ID:  ${SAML_CLIENT_ID}"
echo "  Realm:      ${KEYCLOAK_REALM}"
echo "  Admin URL:  ${KC_BROWSER}/admin/master/console/#/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}"
echo ""
echo "Nextcloud:"
echo "  Login URL:  ${NEXTCLOUD_PUBLIC_URL}/login"
echo "  SP Metadata: ${NEXTCLOUD_PUBLIC_URL}/apps/user_saml/saml/metadata"
echo ""
echo "IdP Metadata URL:"
echo "  ${KC_BROWSER}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor"
echo ""
echo "======================================"
echo "NEXT STEPS"
echo "======================================"
echo ""
echo "  1. Open ${NEXTCLOUD_PUBLIC_URL}/login in your browser"
echo "  2. You should see an 'SSO & SAML log in' button"
echo "  3. Click it - you'll be redirected to Keycloak"
echo "  4. Log in with a FreeIPA user (e.g. testuser1 / TestPass123!)"
echo ""
echo "TROUBLESHOOTING:"
echo "  - If login fails, check Keycloak Events tab for errors"
echo "  - Local admin login: ${NEXTCLOUD_PUBLIC_URL}/login?direct=1"
echo ""
