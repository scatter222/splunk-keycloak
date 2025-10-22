#!/bin/bash
set -e

echo "======================================"
echo "SAML SSO Configuration"
echo "======================================"

# Load configuration
source /opt/install/keycloak-config.env
source /opt/install/splunk-config.env

KCADM="${KEYCLOAK_HOME}/bin/kcadm.sh"
PUBLIC_IP=$(hostname -I | awk '{print $1}')
# Use localhost for kcadm.sh - it runs locally
KEYCLOAK_LOCAL_URL="http://localhost:8080"
SPLUNK_ACS_URL="http://${PUBLIC_IP}:8000/saml/acs"
SPLUNK_ENTITY_ID="splunk-enterprise"

echo "[1/5] Authenticating to KeyCloak..."
${KCADM} config credentials --server ${KEYCLOAK_LOCAL_URL} --realm master --user ${KEYCLOAK_ADMIN} --password ${KEYCLOAK_ADMIN_PASSWORD}

echo "[2/5] Creating SAML client for Splunk in KeyCloak..."
cat > /tmp/splunk-saml-client.json <<EOF
{
  "clientId": "${SPLUNK_ENTITY_ID}",
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
    "saml.signing.certificate": "",
    "saml.signing.private.key": ""
  },
  "redirectUris": ["${SPLUNK_ACS_URL}"],
  "baseUrl": "http://${PUBLIC_IP}:8000",
  "adminUrl": "",
  "fullScopeAllowed": true,
  "protocolMappers": [
    {
      "name": "username",
      "protocol": "saml",
      "protocolMapper": "saml-user-property-mapper",
      "consentRequired": false,
      "config": {
        "attribute.nameformat": "Basic",
        "user.attribute": "username",
        "attribute.name": "username"
      }
    },
    {
      "name": "email",
      "protocol": "saml",
      "protocolMapper": "saml-user-property-mapper",
      "consentRequired": false,
      "config": {
        "attribute.nameformat": "Basic",
        "user.attribute": "email",
        "attribute.name": "email"
      }
    },
    {
      "name": "firstName",
      "protocol": "saml",
      "protocolMapper": "saml-user-property-mapper",
      "consentRequired": false,
      "config": {
        "attribute.nameformat": "Basic",
        "user.attribute": "firstName",
        "attribute.name": "firstName"
      }
    },
    {
      "name": "lastName",
      "protocol": "saml",
      "protocolMapper": "saml-user-property-mapper",
      "consentRequired": false,
      "config": {
        "attribute.nameformat": "Basic",
        "user.attribute": "lastName",
        "attribute.name": "lastName"
      }
    },
    {
      "name": "role list",
      "protocol": "saml",
      "protocolMapper": "saml-role-list-mapper",
      "consentRequired": false,
      "config": {
        "single": "false",
        "attribute.nameformat": "Basic",
        "attribute.name": "role"
      }
    }
  ]
}
EOF

${KCADM} create clients -r splunk -f /tmp/splunk-saml-client.json || echo "Client may already exist"

echo "[3/5] Downloading KeyCloak SAML metadata..."
curl -s "${KEYCLOAK_URL}/realms/splunk/protocol/saml/descriptor" > /tmp/keycloak-idp-metadata.xml

echo "[4/5] Configuring Splunk SAML authentication..."

# Create Splunk auth configuration
cat > /tmp/authentication.conf <<EOF
[authentication]
authType = SAML
authSettings = splunk_saml

[splunk_saml]
fqdn = ${PUBLIC_IP}:8000
redirectPort = 8000
entityId = ${SPLUNK_ENTITY_ID}
idpSSOUrl = ${KEYCLOAK_URL}/realms/splunk/protocol/saml
idpCertPath = \$SPLUNK_HOME/etc/auth/idpCerts/keycloak.pem
idpAttributeQueryUrl =
nameIdFormat = urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified
signAuthnRequest = false
signedAssertion = true
attributeQuerySSOUrl =
attributeQueryRequestSigned = false
attributeQueryResponseSigned = false
redirectAfterLogoutToUrl =
defaultRoleIfMissing = user
singleLogoutServiceUrl = ${KEYCLOAK_URL}/realms/splunk/protocol/saml
sloBinding = HTTPPost
skipAttributeQueryRequestForUsers = *
signatureAlgorithm = RSA-SHA256
ssoBinding = HTTPPost
replicateCertificates = true
EOF

# Copy configuration to Splunk
cp /tmp/authentication.conf ${SPLUNK_HOME}/etc/system/local/authentication.conf
chown splunk:splunk ${SPLUNK_HOME}/etc/system/local/authentication.conf

# Extract and save IdP certificate
mkdir -p ${SPLUNK_HOME}/etc/auth/idpCerts
openssl x509 -in /tmp/keycloak-idp-metadata.xml -text > ${SPLUNK_HOME}/etc/auth/idpCerts/keycloak.pem 2>/dev/null || {
  # If extraction from XML fails, download directly from KeyCloak
  echo "Extracting certificate from KeyCloak..."
  CERT_URL="${KEYCLOAK_URL}/realms/splunk/protocol/saml/descriptor"
  curl -s "$CERT_URL" | grep -oP '(?<=<ds:X509Certificate>).*(?=</ds:X509Certificate>)' | head -1 | base64 -d | openssl x509 -inform DER -out ${SPLUNK_HOME}/etc/auth/idpCerts/keycloak.pem
}

chown -R splunk:splunk ${SPLUNK_HOME}/etc/auth

echo "[5/5] Restarting Splunk to apply SAML configuration..."
sudo -u splunk ${SPLUNK_HOME}/bin/splunk restart

echo ""
echo "======================================"
echo "SAML SSO Configuration Complete!"
echo "======================================"
echo ""
echo "SAML Details:"
echo "  Entity ID: ${SPLUNK_ENTITY_ID}"
echo "  ACS URL: ${SPLUNK_ACS_URL}"
echo "  IdP SSO URL: ${KEYCLOAK_URL}/realms/splunk/protocol/saml"
echo ""
echo "Test SSO:"
echo "  1. Open: http://${PUBLIC_IP}:8000"
echo "  2. You should be redirected to KeyCloak"
echo "  3. Login with: testuser1 / TestPass123!"
echo "  4. You'll be redirected back to Splunk, logged in!"
echo ""
echo "Direct login (if needed):"
echo "  Admin: ${SPLUNK_ADMIN_USER} / ${SPLUNK_ADMIN_PASSWORD}"
echo ""
echo "======================================"
