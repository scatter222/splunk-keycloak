#!/bin/bash
set -e

echo "=========================================="
echo "Splunk + KeyCloak + FreeIPA Installation"
echo "=========================================="
echo ""
echo "This script will install and configure:"
echo "  1. FreeIPA (LDAP + Kerberos)"
echo "  2. KeyCloak (SAML IdP)"
echo "  3. Splunk Enterprise (SAML SP)"
echo ""
echo "Total estimated time: 20-30 minutes"
echo "=========================================="
echo ""

SCRIPTS_DIR="/opt/install/scripts"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root"
  exit 1
fi

# Log everything
exec > >(tee -a /opt/install/installation.log)
exec 2>&1

echo "[$(date)] Starting installation..."

# Install FreeIPA
echo ""
echo "=========================================="
echo "Step 1/3: Installing FreeIPA"
echo "=========================================="
bash ${SCRIPTS_DIR}/01-install-freeipa.sh

# Install KeyCloak
echo ""
echo "=========================================="
echo "Step 2/3: Installing KeyCloak"
echo "=========================================="
bash ${SCRIPTS_DIR}/02-install-keycloak.sh

# Install Splunk
echo ""
echo "=========================================="
echo "Step 3/3: Installing Splunk"
echo "=========================================="
bash ${SCRIPTS_DIR}/03-install-splunk.sh

echo ""
echo "=========================================="
echo "ALL INSTALLATIONS COMPLETE!"
echo "=========================================="
echo ""
echo "Access your services:"
echo ""

source /opt/install/freeipa-config.env
source /opt/install/keycloak-config.env
source /opt/install/splunk-config.env

PUBLIC_IP=$(hostname -I | awk '{print $1}')

echo "FreeIPA Web UI:       https://${PUBLIC_IP}"
echo "  Username: admin"
echo "  Password: ${FREEIPA_ADMIN_PASSWORD}"
echo ""
echo "KeyCloak Admin:       ${KEYCLOAK_URL}"
echo "  Username: ${KEYCLOAK_ADMIN}"
echo "  Password: ${KEYCLOAK_ADMIN_PASSWORD}"
echo ""
echo "Splunk Web:           ${SPLUNK_URL}"
echo "  Username: ${SPLUNK_ADMIN_USER}"
echo "  Password: ${SPLUNK_ADMIN_PASSWORD}"
echo ""
echo "Test Users (FreeIPA):"
echo "  testuser1 / TestPass123!  (splunk-admins)"
echo "  testuser2 / TestPass123!  (splunk-users)"
echo "  testuser3 / TestPass123!  (splunk-users)"
echo ""
echo "=========================================="
echo "Next Steps:"
echo "  1. Run: bash ${SCRIPTS_DIR}/04-configure-keycloak-ldap.sh"
echo "  2. Run: bash ${SCRIPTS_DIR}/05-configure-saml.sh"
echo "  3. Test SSO login to Splunk!"
echo "=========================================="
echo ""
echo "[$(date)] Installation complete!"
echo "Full log: /opt/install/installation.log"
