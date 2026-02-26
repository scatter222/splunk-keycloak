#!/bin/bash
###############################################################################
# setup-nextcloud-saml.sh
#
# Configures Keycloak with a SAML client for Nextcloud, then configures
# Nextcloud's user_saml app to use it.
#
# Usage:
#   1. Edit the variables below to match your environment
#   2. chmod +x setup-nextcloud-saml.sh
#   3. sudo ./setup-nextcloud-saml.sh
#
# Assumes:
#   - Keycloak is already running and reachable
#   - Nextcloud is already installed
#   - curl and jq are available
###############################################################################

set -euo pipefail

#==============================================================================
# CONFIGURATION — EDIT THESE TO MATCH YOUR ENVIRONMENT
#==============================================================================

# Keycloak settings
KEYCLOAK_URL="http://localhost:8080"          # Keycloak base URL
KEYCLOAK_REALM="master"                       # Realm where FreeIPA federation exists
KEYCLOAK_ADMIN="admin"                        # Keycloak admin username
KEYCLOAK_ADMIN_PASSWORD="admin"               # Keycloak admin password

# Nextcloud settings
NEXTCLOUD_URL="https://nextcloud.example.com" # Public URL of your Nextcloud
NEXTCLOUD_PATH="/var/www/nextcloud"            # Nextcloud installation path
NEXTCLOUD_USER="www-data"                      # User that runs Nextcloud (www-data or apache)

# SAML Client ID (Nextcloud's entity ID)
SAML_CLIENT_ID="${NEXTCLOUD_URL}/apps/user_saml/saml/metadata"

#==============================================================================
# PREFLIGHT CHECKS
#==============================================================================

echo "============================================"
echo " Nextcloud SAML + Keycloak Setup Script"
echo "============================================"
echo ""

# Check for required tools
for cmd in curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: '$cmd' is required but not installed."
        echo "  Install with: sudo dnf install $cmd   (Rocky/RHEL)"
        echo "             or: sudo apt install $cmd   (Debian/Ubuntu)"
        exit 1
    fi
done

# Check Nextcloud occ is available
if [ ! -f "${NEXTCLOUD_PATH}/occ" ]; then
    echo "ERROR: Nextcloud occ not found at ${NEXTCLOUD_PATH}/occ"
    echo "  Update NEXTCLOUD_PATH in this script."
    exit 1
fi

# Helper to run occ commands
occ() {
    sudo -u "${NEXTCLOUD_USER}" php "${NEXTCLOUD_PATH}/occ" "$@"
}

#==============================================================================
# STEP 1: Get Keycloak admin access token
#==============================================================================

echo "[1/6] Authenticating with Keycloak..."

KC_TOKEN=$(curl -s -X POST \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" | jq -r '.access_token')

if [ "$KC_TOKEN" = "null" ] || [ -z "$KC_TOKEN" ]; then
    echo "ERROR: Failed to authenticate with Keycloak."
    echo "  Check KEYCLOAK_URL, KEYCLOAK_ADMIN, and KEYCLOAK_ADMIN_PASSWORD."
    exit 1
fi

echo "  ✓ Authenticated with Keycloak"

#==============================================================================
# STEP 2: Create the SAML client in Keycloak
#==============================================================================

echo "[2/6] Creating SAML client in Keycloak..."

# Check if client already exists
EXISTING=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SAML_CLIENT_ID}', safe=''))")")

# Build the client JSON
CLIENT_JSON=$(cat <<EOF
{
    "clientId": "${SAML_CLIENT_ID}",
    "name": "Nextcloud",
    "description": "Nextcloud SAML Service Provider",
    "protocol": "saml",
    "enabled": true,
    "rootUrl": "${NEXTCLOUD_URL}",
    "baseUrl": "${NEXTCLOUD_URL}",
    "redirectUris": ["${NEXTCLOUD_URL}/*"],
    "adminUrl": "${NEXTCLOUD_URL}/apps/user_saml/saml/acs",
    "attributes": {
        "saml.authnstatement": "true",
        "saml.server.signature": "true",
        "saml.assertion.signature": "true",
        "saml.force.post.binding": "true",
        "saml.client.signature": "false",
        "saml_name_id_format": "username",
        "saml_single_logout_service_url_post": "${NEXTCLOUD_URL}/apps/user_saml/saml/sls",
        "saml_assertion_consumer_url_post": "${NEXTCLOUD_URL}/apps/user_saml/saml/acs",
        "saml_single_logout_service_url_redirect": "${NEXTCLOUD_URL}/apps/user_saml/saml/sls"
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
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" | \
    jq -r --arg cid "$SAML_CLIENT_ID" '.[] | select(.clientId == $cid) | .id')

if [ -n "$EXISTING_CLIENTS" ]; then
    echo "  Client already exists (ID: ${EXISTING_CLIENTS}). Updating..."
    KC_CLIENT_UUID="$EXISTING_CLIENTS"
    curl -s -X PUT \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_JSON" \
        "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}"
    echo "  ✓ Client updated"
else
    # Create new client
    HTTP_CODE=$(curl -s -o /tmp/kc_response.txt -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$CLIENT_JSON" \
        "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients")

    if [ "$HTTP_CODE" = "201" ]; then
        echo "  ✓ Client created"
    else
        echo "  ERROR: Failed to create client (HTTP ${HTTP_CODE})"
        cat /tmp/kc_response.txt
        exit 1
    fi

    # Get the UUID of the new client
    KC_CLIENT_UUID=$(curl -s \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" | \
        jq -r --arg cid "$SAML_CLIENT_ID" '.[] | select(.clientId == $cid) | .id')
fi

echo "  Client UUID: ${KC_CLIENT_UUID}"

#==============================================================================
# STEP 3: Add SAML protocol mappers
#==============================================================================

echo "[3/6] Adding SAML attribute mappers..."

add_mapper() {
    local NAME="$1"
    local ATTRIBUTE_NAME="$2"
    local USER_PROPERTY="$3"
    local MAPPER_TYPE="${4:-saml-user-property-idp-mapper}"

    # For user-property mappers
    if [ "$MAPPER_TYPE" = "saml-user-property-idp-mapper" ]; then
        MAPPER_JSON=$(cat <<MAPEOF
{
    "name": "${NAME}",
    "protocol": "saml",
    "protocolMapper": "saml-user-property-idp-mapper",
    "config": {
        "user.attribute": "${USER_PROPERTY}",
        "friendly.name": "${NAME}",
        "attribute.name": "${ATTRIBUTE_NAME}",
        "attribute.nameformat": "Basic"
    }
}
MAPEOF
)
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$MAPPER_JSON" \
        "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}/protocol-mappers/models")

    if [ "$HTTP_CODE" = "201" ]; then
        echo "  ✓ Mapper '${NAME}' created"
    elif [ "$HTTP_CODE" = "409" ]; then
        echo "  - Mapper '${NAME}' already exists, skipping"
    else
        echo "  ⚠ Mapper '${NAME}' returned HTTP ${HTTP_CODE}"
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
    "protocolMapper": "saml-group-idp-mapper",
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
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}/protocol-mappers/models")

if [ "$HTTP_CODE" = "201" ]; then
    echo "  ✓ Mapper 'groups' created"
elif [ "$HTTP_CODE" = "409" ]; then
    echo "  - Mapper 'groups' already exists, skipping"
else
    echo "  ⚠ Mapper 'groups' returned HTTP ${HTTP_CODE}"
fi

#==============================================================================
# STEP 4: Retrieve IdP certificate from Keycloak
#==============================================================================

echo "[4/6] Retrieving Keycloak IdP signing certificate..."

# Fetch the SAML descriptor and extract the X509 certificate
SAML_DESCRIPTOR=$(curl -s "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor")

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
# Find the signing cert in the IDPSSODescriptor
for kd in root.findall('.//md:IDPSSODescriptor/md:KeyDescriptor[@use=\"signing\"]/ds:KeyInfo/ds:X509Data/ds:X509Certificate', ns):
    print(kd.text.strip())
    break
else:
    # Fallback: try any X509Certificate
    for kd in root.findall('.//ds:X509Certificate', ns):
        print(kd.text.strip())
        break
")

if [ -z "$IDP_CERT" ]; then
    echo "  ⚠ WARNING: Could not extract IdP certificate automatically."
    echo "    You can get it manually from:"
    echo "    Keycloak Admin → Realm Settings → Keys → RS256 → Certificate"
    echo "    Or from: ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor"
    IDP_CERT="PASTE_YOUR_CERTIFICATE_HERE"
else
    echo "  ✓ IdP certificate retrieved"
fi

# Build the full PEM-formatted certificate for Nextcloud
IDP_CERT_FORMATTED="-----BEGIN CERTIFICATE-----
${IDP_CERT}
-----END CERTIFICATE-----"

#==============================================================================
# STEP 5: Enable and configure Nextcloud user_saml app
#==============================================================================

echo "[5/6] Configuring Nextcloud SAML..."

# Enable the user_saml app
echo "  Enabling user_saml app..."
occ app:enable user_saml 2>/dev/null || echo "  (app may already be enabled)"

# Set SAML type to "environment-variable" = 1, "saml" = 1
# type 1 = Built-in SAML, which uses the php-saml library
occ config:app:set user_saml type --value="saml" 2>/dev/null || true

# IDP settings
echo "  Setting Identity Provider configuration..."

# IdP Entity ID
occ config:app:set user_saml idp-entityId \
    --value="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}"

# IdP SSO URL
occ config:app:set user_saml idp-singleSignOnService.url \
    --value="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/saml"

# IdP SLO URL
occ config:app:set user_saml idp-singleLogoutService.url \
    --value="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/saml"

# IdP Certificate
occ config:app:set user_saml idp-x509cert \
    --value="${IDP_CERT_FORMATTED}"

# SP settings
echo "  Setting Service Provider configuration..."

# SP Entity ID (must match the Keycloak Client ID)
occ config:app:set user_saml sp-entityId \
    --value="${SAML_CLIENT_ID}"

# SP Name ID Format
occ config:app:set user_saml sp-name-id-format \
    --value="urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified"

# Attribute mapping
echo "  Setting attribute mappings..."

occ config:app:set user_saml general-uid_mapping \
    --value="uid"

occ config:app:set user_saml saml-attribute-mapping-displayName_mapping \
    --value="firstName"

occ config:app:set user_saml saml-attribute-mapping-email_mapping \
    --value="email"

occ config:app:set user_saml saml-attribute-mapping-group_mapping \
    --value="groups"

# Security settings
echo "  Setting security options..."

# Allow users to be auto-provisioned on first login
occ config:app:set user_saml general-require_provisioned_account \
    --value="0"

# Allow multiple user backends (so local admin still works)
occ config:app:set user_saml general-allow_multiple_user_back_ends \
    --value="1"

echo "  ✓ Nextcloud SAML configuration complete"

#==============================================================================
# STEP 6: Summary
#==============================================================================

echo ""
echo "============================================"
echo " SETUP COMPLETE"
echo "============================================"
echo ""
echo " Keycloak SAML Client:"
echo "   Client ID:  ${SAML_CLIENT_ID}"
echo "   Realm:      ${KEYCLOAK_REALM}"
echo "   Admin URL:  ${KEYCLOAK_URL}/admin/master/console/#/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}"
echo ""
echo " Nextcloud:"
echo "   Login URL:  ${NEXTCLOUD_URL}/login"
echo "   SP Metadata: ${NEXTCLOUD_URL}/apps/user_saml/saml/metadata"
echo ""
echo " IdP Metadata URL:"
echo "   ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor"
echo ""
echo "============================================"
echo " NEXT STEPS"
echo "============================================"
echo ""
echo " 1. Open ${NEXTCLOUD_URL}/login in your browser"
echo " 2. You should see an 'SSO & SAML log in' button"
echo " 3. Click it — you'll be redirected to Keycloak"
echo " 4. Log in with a FreeIPA user"
echo ""
echo " TROUBLESHOOTING:"
echo " - If login fails, check Keycloak Events tab for errors"
echo " - Ensure the SP Entity ID matches exactly between Keycloak and Nextcloud"
echo " - If using HTTP for Keycloak, Nextcloud may reject non-HTTPS IdP URLs"
echo "   → Fix: occ config:app:set user_saml security-wantNameIdEncrypted --value=\"0\""
echo " - Local admin login is still available at: ${NEXTCLOUD_URL}/login?direct=1"
echo ""
