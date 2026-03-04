#!/bin/bash
# Don't use set -e - we want to handle errors gracefully
set -u  # Exit on undefined variables

echo "======================================"
echo "Nextcloud Installation Script"
echo "======================================"

# Configuration
NEXTCLOUD_VERSION="30.0.4"
NEXTCLOUD_ADMIN="admin"
NEXTCLOUD_ADMIN_PASSWORD="Nextcloud123!@#"
NEXTCLOUD_PATH="/var/www/nextcloud"
NEXTCLOUD_DATA="/var/www/nextcloud-data"
DB_NAME="nextcloud"
DB_USER="nextcloud"
DB_PASSWORD="NCdb123!@#"
# Get the public IP for cloud VMs (falls back to private IP if not available)
PUBLIC_IP=$(curl -s --max-time 5 -4 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 -4 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# CRITICAL: Create config file FIRST so other scripts can use it even if this script fails
mkdir -p /opt/install
cat > /opt/install/nextcloud-config.env <<EOF
NEXTCLOUD_PATH=${NEXTCLOUD_PATH}
NEXTCLOUD_DATA=${NEXTCLOUD_DATA}
NEXTCLOUD_ADMIN=${NEXTCLOUD_ADMIN}
NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
NEXTCLOUD_URL=http://${PUBLIC_IP}
NEXTCLOUD_USER=apache
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
EOF
echo "Configuration file created at /opt/install/nextcloud-config.env"

# Ensure DNS is working (fix for FreeIPA DNS issues)
echo "Checking DNS resolution..."
if ! dig +short github.com > /dev/null 2>&1; then
  echo "DNS not resolving, attempting to fix..."
  systemctl restart named-pkcs11 || true
  sleep 3

  if ! dig +short github.com > /dev/null 2>&1; then
    echo "Using fallback DNS temporarily..."
    echo "nameserver 168.63.129.16" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi
echo "DNS check complete"

echo "[1/8] Installing Apache, PHP, and MariaDB..."
# Enable required repos
dnf install -y epel-release
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm || echo "Remi repo may already be installed"

# Enable PHP 8.2 from Remi
dnf module reset php -y || true
dnf module enable php:remi-8.2 -y || true

# Install packages
dnf install -y \
  httpd \
  mariadb-server mariadb \
  php php-gd php-mbstring php-intl php-pecl-apcu php-mysqlnd \
  php-xml php-json php-zip php-process php-bcmath php-gmp \
  php-imagick php-ldap php-opcache php-redis php-curl \
  php-pear php-cli php-common php-sodium \
  unzip wget curl jq policycoreutils-python-utils

echo "[2/8] Configuring PHP..."
# Tune PHP for Nextcloud
cat > /etc/php.d/99-nextcloud.ini <<EOF
memory_limit = 512M
upload_max_filesize = 16G
post_max_size = 16G
max_execution_time = 3600
max_input_time = 3600
output_buffering = Off
date.timezone = UTC
opcache.enable = 1
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 1
EOF

echo "[3/8] Starting and configuring MariaDB..."
systemctl enable --now mariadb

# Create Nextcloud database and user
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "  Database '${DB_NAME}' created"

echo "[4/8] Downloading Nextcloud ${NEXTCLOUD_VERSION}..."
cd /tmp
curl -L -o nextcloud-${NEXTCLOUD_VERSION}.zip \
  https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip

echo "[5/8] Installing Nextcloud..."
unzip -q -o nextcloud-${NEXTCLOUD_VERSION}.zip -d /var/www/
rm nextcloud-${NEXTCLOUD_VERSION}.zip

# Create data directory outside webroot
mkdir -p ${NEXTCLOUD_DATA}

# Set ownership
chown -R apache:apache ${NEXTCLOUD_PATH}
chown -R apache:apache ${NEXTCLOUD_DATA}

echo "[6/8] Configuring Apache..."
cat > /etc/httpd/conf.d/nextcloud.conf <<'APACHEEOF'
<VirtualHost *:80>
    DocumentRoot /var/www/nextcloud

    <Directory /var/www/nextcloud>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>

        SetEnv HOME /var/www/nextcloud
        SetEnv HTTP_HOME /var/www/nextcloud
    </Directory>

    ErrorLog /var/log/httpd/nextcloud-error.log
    CustomLog /var/log/httpd/nextcloud-access.log combined
</VirtualHost>
APACHEEOF

# Disable the default welcome page
sed -i 's/^/#/' /etc/httpd/conf.d/welcome.conf 2>/dev/null || true

# Enable required Apache modules
dnf install -y mod_ssl || true

echo "[7/8] Configuring SELinux for Nextcloud..."
# Allow Apache to write to Nextcloud directories
setsebool -P httpd_unified 1 || true
setsebool -P httpd_can_network_connect 1 || true
setsebool -P httpd_can_network_connect_db 1 || true
setsebool -P httpd_can_sendmail 1 || true

# Set SELinux context for Nextcloud directories
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_PATH}/config(/.*)?" || true
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_PATH}/apps(/.*)?" || true
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_PATH}/.htaccess" || true
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_PATH}/.user.ini" || true
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_DATA}(/.*)?" || true
restorecon -R ${NEXTCLOUD_PATH} || true
restorecon -R ${NEXTCLOUD_DATA} || true

# Open HTTP port in firewall
firewall-cmd --permanent --add-service=http || true
firewall-cmd --permanent --add-service=https || true
firewall-cmd --reload || true

echo "[8/8] Running Nextcloud installer..."
systemctl enable --now httpd

# Run the Nextcloud CLI installer
cd ${NEXTCLOUD_PATH}
sudo -u apache php occ maintenance:install \
  --database "mysql" \
  --database-name "${DB_NAME}" \
  --database-user "${DB_USER}" \
  --database-pass "${DB_PASSWORD}" \
  --admin-user "${NEXTCLOUD_ADMIN}" \
  --admin-pass "${NEXTCLOUD_ADMIN_PASSWORD}" \
  --data-dir "${NEXTCLOUD_DATA}"

# Add the public IP as a trusted domain
sudo -u apache php occ config:system:set trusted_domains 1 --value="${PUBLIC_IP}"
sudo -u apache php occ config:system:set trusted_domains 2 --value="*"

# Set overwrite URL for proper redirect handling
sudo -u apache php occ config:system:set overwrite.cli.url --value="http://${PUBLIC_IP}"

# Overwrite settings for SAML compatibility (Nextcloud generates SP metadata URLs
# using localhost instead of public IP without these)
sudo -u apache php occ config:system:set overwritehost --value="${PUBLIC_IP}"
sudo -u apache php occ config:system:set overwriteprotocol --value="http"
sudo -u apache php occ config:system:set overwritecondaddr --value=".*"

# Set default phone region
sudo -u apache php occ config:system:set default_phone_region --value="US"

# Enable pretty URLs
sudo -u apache php occ config:system:set htaccess.RewriteBase --value="/"
sudo -u apache php occ maintenance:update:htaccess

# Restart Apache to apply everything
systemctl restart httpd

echo ""
echo "======================================"
echo "Nextcloud Installation Complete!"
echo "======================================"
echo "Nextcloud URL: http://${PUBLIC_IP}"
echo "Admin Username: ${NEXTCLOUD_ADMIN}"
echo "Admin Password: ${NEXTCLOUD_ADMIN_PASSWORD}"
echo ""
echo "Database: ${DB_NAME} (MariaDB)"
echo "Data Directory: ${NEXTCLOUD_DATA}"
echo ""
echo "Service status:"
systemctl status httpd --no-pager -l
echo ""
echo "Configuration file: /opt/install/nextcloud-config.env"
echo "======================================"
