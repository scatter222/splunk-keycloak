#!/bin/bash
# Don't use set -e - we want to handle errors gracefully
set -u  # Exit on undefined variables

echo "======================================"
echo "Splunk Enterprise Installation Script"
echo "======================================"

# Configuration
SPLUNK_VERSION="9.3.2"
SPLUNK_BUILD="d8bb32809498"
SPLUNK_ADMIN_USER="admin"
SPLUNK_ADMIN_PASSWORD="Splunk123!@#"
SPLUNK_HOME="/opt/splunk"
PUBLIC_IP=$(hostname -I | awk '{print $1}')

# CRITICAL: Create config file FIRST so other scripts can use it even if this script fails
mkdir -p /opt/install
cat > /opt/install/splunk-config.env <<EOF
SPLUNK_HOME=${SPLUNK_HOME}
SPLUNK_ADMIN_USER=${SPLUNK_ADMIN_USER}
SPLUNK_ADMIN_PASSWORD=${SPLUNK_ADMIN_PASSWORD}
SPLUNK_URL=http://${PUBLIC_IP}:8000
EOF
echo "Configuration file created at /opt/install/splunk-config.env"

# Ensure DNS is working (fix for FreeIPA DNS issues)
echo "Checking DNS resolution..."
if ! dig +short download.splunk.com > /dev/null 2>&1; then
  echo "DNS not resolving, attempting to fix..."
  # Ensure FreeIPA DNS service is running
  systemctl restart named-pkcs11 || true
  sleep 3

  # If still failing, temporarily use external DNS
  if ! dig +short download.splunk.com > /dev/null 2>&1; then
    echo "Using fallback DNS temporarily..."
    echo "nameserver 168.63.129.16" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi
echo "DNS check complete"

echo "[1/5] Downloading Splunk Enterprise ${SPLUNK_VERSION}..."
cd /opt
curl -L -o splunk.tgz "https://download.splunk.com/products/splunk/releases/${SPLUNK_VERSION}/linux/splunk-${SPLUNK_VERSION}-${SPLUNK_BUILD}-Linux-x86_64.tgz"

echo "[2/5] Extracting Splunk..."
tar -xzf splunk.tgz
rm splunk.tgz

echo "[3/5] Creating Splunk user and setting permissions..."
useradd -r -m -d ${SPLUNK_HOME} splunk || true
chown -R splunk:splunk ${SPLUNK_HOME}

echo "[4/5] Starting Splunk and accepting license..."
sudo -u splunk ${SPLUNK_HOME}/bin/splunk start --accept-license --answer-yes --no-prompt --seed-passwd ${SPLUNK_ADMIN_PASSWORD}

echo "[5/5] Enabling Splunk to start at boot with systemd..."

# Create systemd service file for Splunk
cat > /etc/systemd/system/Splunkd.service <<EOF
[Unit]
Description=Splunk Enterprise
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=splunk
Group=splunk
ExecStart=${SPLUNK_HOME}/bin/splunk _internal_launch_under_systemd
ExecStartPost=${SPLUNK_HOME}/bin/splunk search '| noop' -auth admin:${SPLUNK_ADMIN_PASSWORD} || true
Restart=on-failure
RestartSec=30
TimeoutStopSec=600
KillMode=mixed
KillSignal=SIGINT
SuccessExitStatus=51 52
RestartPreventExitStatus=51
RestartForceExitStatus=52
LimitNOFILE=65536
LimitNPROC=16384
LimitFSIZE=infinity
LimitCORE=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Splunkd service
systemctl daemon-reload
systemctl enable Splunkd
echo "Splunk systemd service created and enabled"

echo ""
echo "======================================"
echo "Splunk Installation Complete!"
echo "======================================"
echo "Splunk Web: http://${PUBLIC_IP}:8000"
echo "Admin Username: ${SPLUNK_ADMIN_USER}"
echo "Admin Password: ${SPLUNK_ADMIN_PASSWORD}"
echo ""
echo "Splunk is now running!"
echo "Note: Splunk will automatically start on system boot"
echo "Configuration file: /opt/install/splunk-config.env"
echo "======================================"
