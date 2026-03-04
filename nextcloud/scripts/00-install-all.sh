#!/bin/bash
set -e

echo "=========================================="
echo "Nextcloud + KeyCloak + FreeIPA Installation"
echo "=========================================="
echo ""
echo "This script will install and configure:"
echo "  1. FreeIPA (LDAP + Kerberos)"
echo "  2. KeyCloak (SAML IdP)"
echo "  3. Nextcloud (File Sharing / Collaboration)"
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
echo "Step 1/5: Installing FreeIPA"
echo "=========================================="
bash ${SCRIPTS_DIR}/01-install-freeipa.sh

# Install KeyCloak
echo ""
echo "=========================================="
echo "Step 2/5: Installing KeyCloak"
echo "=========================================="
bash ${SCRIPTS_DIR}/02-install-keycloak.sh

# Install Nextcloud
echo ""
echo "=========================================="
echo "Step 3/5: Installing Nextcloud"
echo "=========================================="
bash ${SCRIPTS_DIR}/03-install-nextcloud.sh

# Configure Keycloak LDAP federation
echo ""
echo "=========================================="
echo "Step 4/5: Configuring Keycloak LDAP Federation"
echo "=========================================="
bash ${SCRIPTS_DIR}/04-configure-keycloak-ldap.sh

# Configure Nextcloud SAML SSO
echo ""
echo "=========================================="
echo "Step 5/5: Configuring Nextcloud SAML SSO"
echo "=========================================="
bash ${SCRIPTS_DIR}/05-configure-nextcloud-saml.sh

echo ""
echo "=========================================="
echo "ALL INSTALLATIONS COMPLETE!"
echo "=========================================="
echo ""
echo "Access your services:"
echo ""

source /opt/install/freeipa-config.env
source /opt/install/keycloak-config.env
source /opt/install/nextcloud-config.env

PUBLIC_IP=$(hostname -I | awk '{print $1}')

echo "FreeIPA Web UI:       https://${PUBLIC_IP}"
echo "  Username: admin"
echo "  Password: ${FREEIPA_ADMIN_PASSWORD}"
echo ""
echo "KeyCloak Admin:       ${KEYCLOAK_URL}"
echo "  Username: ${KEYCLOAK_ADMIN}"
echo "  Password: ${KEYCLOAK_ADMIN_PASSWORD}"
echo ""
echo "Nextcloud:            ${NEXTCLOUD_URL}"
echo "  Username: ${NEXTCLOUD_ADMIN}"
echo "  Password: ${NEXTCLOUD_ADMIN_PASSWORD}"
echo ""
echo "Test Users (FreeIPA):"
echo "  testuser1 / TestPass123!  (nextcloud-admins)"
echo "  testuser2 / TestPass123!  (nextcloud-users)"
echo "  testuser3 / TestPass123!  (nextcloud-users)"
echo ""
echo "=========================================="
echo "Test SSO:"
echo "  1. Open http://${PUBLIC_IP}/login in your browser"
echo "  2. Click 'SSO & SAML log in'"
echo "  3. Log in with testuser1 / TestPass123!"
echo ""
echo "Direct admin login: http://${PUBLIC_IP}/login?direct=1"
echo "=========================================="
echo ""
echo "[$(date)] Installation complete!"
echo "Full log: /opt/install/installation.log"
