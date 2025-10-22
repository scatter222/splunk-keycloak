#!/bin/bash
# Don't use set -e - we want to handle errors gracefully
set -u  # Exit on undefined variables

echo "======================================"
echo "KeyCloak Installation Script"
echo "======================================"

# Configuration
KEYCLOAK_VERSION="23.0.7"
KEYCLOAK_ADMIN="admin"
KEYCLOAK_ADMIN_PASSWORD="KeyCloak123!@#"
KEYCLOAK_HOME="/opt/keycloak"
PUBLIC_IP=$(hostname -I | awk '{print $1}')

# CRITICAL: Create config file FIRST so other scripts can use it even if this script fails
mkdir -p /opt/install
cat > /opt/install/keycloak-config.env <<EOF
KEYCLOAK_HOME=${KEYCLOAK_HOME}
KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
KEYCLOAK_URL=http://${PUBLIC_IP}:8080
EOF
echo "Configuration file created at /opt/install/keycloak-config.env"

# Ensure DNS is working (fix for FreeIPA DNS issues)
echo "Checking DNS resolution..."
if ! dig +short github.com > /dev/null 2>&1; then
  echo "DNS not resolving, attempting to fix..."
  # Ensure FreeIPA DNS service is running
  systemctl restart named-pkcs11 || true
  sleep 3

  # If still failing, temporarily use external DNS
  if ! dig +short github.com > /dev/null 2>&1; then
    echo "Using fallback DNS temporarily..."
    echo "nameserver 168.63.129.16" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi
echo "DNS check complete"

echo "[1/6] Installing Java (required for KeyCloak)..."
dnf install -y java-17-openjdk java-17-openjdk-devel

echo "[2/6] Downloading KeyCloak ${KEYCLOAK_VERSION}..."
cd /opt
curl -L -o keycloak-${KEYCLOAK_VERSION}.tar.gz https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz
tar -xzf keycloak-${KEYCLOAK_VERSION}.tar.gz
mv keycloak-${KEYCLOAK_VERSION} keycloak
rm keycloak-${KEYCLOAK_VERSION}.tar.gz

echo "[3/6] Configuring KeyCloak..."
cd ${KEYCLOAK_HOME}

# Set admin credentials
export KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN}
export KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}

echo "[4/6] Creating KeyCloak systemd service..."
cat > /etc/systemd/system/keycloak.service <<EOF
[Unit]
Description=KeyCloak Application Server
After=network.target

[Service]
Type=simple
User=root
Environment="KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN}"
Environment="KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}"
ExecStart=${KEYCLOAK_HOME}/bin/kc.sh start-dev --http-host=0.0.0.0 --http-port=8080
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "[5/6] Starting KeyCloak service..."
systemctl daemon-reload
systemctl enable keycloak
systemctl start keycloak

echo "[6/6] Waiting for KeyCloak to start (this may take 30-60 seconds)..."
sleep 30
until curl -sf http://localhost:8080 > /dev/null; do
  echo "  Waiting for KeyCloak to respond..."
  sleep 5
done

echo ""
echo "======================================"
echo "KeyCloak Installation Complete!"
echo "======================================"
echo "KeyCloak Admin Console: http://${PUBLIC_IP}:8080"
echo "Admin Username: ${KEYCLOAK_ADMIN}"
echo "Admin Password: ${KEYCLOAK_ADMIN_PASSWORD}"
echo ""
echo "Service status:"
systemctl status keycloak --no-pager -l
echo ""
echo "Configuration file: /opt/install/keycloak-config.env"
echo "======================================"
