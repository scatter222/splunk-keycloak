#!/bin/bash
# Don't use set -e - we want to handle errors gracefully and always create config files
set -u  # Exit on undefined variables

echo "======================================"
echo "FreeIPA Installation Script"
echo "======================================"

# Configuration
DOMAIN="splunkauth.lab"
REALM="SPLUNKAUTH.LAB"
ADMIN_PASSWORD="Admin123!@#"
DS_PASSWORD="DirMgr123!@#"
HOSTNAME="ipa.${DOMAIN}"

# CRITICAL: Create config file FIRST so other scripts can use it even if this script fails
mkdir -p /opt/install
cat > /opt/install/freeipa-config.env <<EOF
FREEIPA_DOMAIN=${DOMAIN}
FREEIPA_REALM=${REALM}
FREEIPA_ADMIN_PASSWORD=${ADMIN_PASSWORD}
FREEIPA_DS_PASSWORD=${DS_PASSWORD}
FREEIPA_HOSTNAME=${HOSTNAME}
EOF
echo "Configuration file created at /opt/install/freeipa-config.env"

echo "[1/7] Setting hostname..."
# Get the actual IP address (not localhost)
IP_ADDRESS=$(hostname -I | awk '{print $1}')
echo "Detected IP: ${IP_ADDRESS}"

# Set hostname
hostnamectl set-hostname ${HOSTNAME}

# Update /etc/hosts with proper IP
sed -i '/ipa.splunkauth.lab/d' /etc/hosts
echo "${IP_ADDRESS} ${HOSTNAME} ipa" >> /etc/hosts
echo "127.0.0.1 localhost localhost.localdomain" > /tmp/hosts.new
grep -v "127.0.0.1" /etc/hosts >> /tmp/hosts.new || true
mv /tmp/hosts.new /etc/hosts
echo "${IP_ADDRESS} ${HOSTNAME} ipa" >> /etc/hosts

cat /etc/hosts

echo "[2/7] Updating system..."
dnf update -y

echo "[3/7] Installing FreeIPA server packages..."
dnf install -y freeipa-server freeipa-server-dns

echo "[4/7] Configuring firewall..."
dnf install -y firewalld
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=freeipa-ldap
firewall-cmd --permanent --add-service=freeipa-ldaps
firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=kerberos
firewall-cmd --reload

echo "[5/7] Installing FreeIPA server (this will take 5-10 minutes)..."
ipa-server-install \
  --realm=${REALM} \
  --domain=${DOMAIN} \
  --ds-password=${DS_PASSWORD} \
  --admin-password=${ADMIN_PASSWORD} \
  --hostname=${HOSTNAME} \
  --setup-dns \
  --forwarder=168.63.129.16 \
  --forwarder=8.8.8.8 \
  --no-reverse \
  --no-ntp \
  --unattended

echo "[5.5/7] Configuring DNS forwarders and verifying connectivity..."
echo "${ADMIN_PASSWORD}" | kinit admin

# Add additional DNS forwarders for redundancy
ipa dnsconfig-mod --forwarder=168.63.129.16 --forwarder=8.8.8.8 --forwarder=1.1.1.1 || echo "Forwarders already configured"

# Restart DNS service to ensure forwarders are active
systemctl restart named-pkcs11

# Wait for DNS to be ready
sleep 5

# Test external DNS resolution
echo "Testing DNS resolution..."
if ! dig +short github.com @127.0.0.1 > /dev/null; then
  echo "WARNING: External DNS not resolving through FreeIPA, but continuing..."
fi

echo "[6/7] Creating test users..."

# Create test users (with error handling - users might already exist)
ipa user-add testuser1 --first=Test --last=User1 --email=testuser1@${DOMAIN} --password <<EOF || echo "testuser1 may already exist"
TestPass123!
TestPass123!
EOF

ipa user-add testuser2 --first=Test --last=User2 --email=testuser2@${DOMAIN} --password <<EOF || echo "testuser2 may already exist"
TestPass123!
TestPass123!
EOF

ipa user-add testuser3 --first=Test --last=User3 --email=testuser3@${DOMAIN} --password <<EOF || echo "testuser3 may already exist"
TestPass123!
TestPass123!
EOF

echo "[7/7] Creating test groups..."
ipa group-add splunk-admins --desc="Splunk Administrators" || echo "splunk-admins group may already exist"
ipa group-add splunk-users --desc="Splunk Users" || echo "splunk-users group may already exist"

ipa group-add-member splunk-admins --users=testuser1 || echo "testuser1 may already be in group"
ipa group-add-member splunk-users --users=testuser2,testuser3 || echo "testuser2/3 may already be in group"

echo ""
echo "======================================"
echo "FreeIPA Installation Complete!"
echo "======================================"
echo "Domain: ${DOMAIN}"
echo "Realm: ${REALM}"
echo "Admin Username: admin"
echo "Admin Password: ${ADMIN_PASSWORD}"
echo ""
echo "Test Users:"
echo "  testuser1 / TestPass123! (in splunk-admins group)"
echo "  testuser2 / TestPass123! (in splunk-users group)"
echo "  testuser3 / TestPass123! (in splunk-users group)"
echo ""
echo "FreeIPA Web UI: https://$(hostname -I | awk '{print $1}')"
echo "Configuration file: /opt/install/freeipa-config.env"
echo "======================================"
