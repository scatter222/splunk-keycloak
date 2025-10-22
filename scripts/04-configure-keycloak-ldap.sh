#!/bin/bash
set -e

echo "======================================"
echo "KeyCloak LDAP Federation Setup"
echo "======================================"

# Load configuration
source /opt/install/freeipa-config.env
source /opt/install/keycloak-config.env

KCADM="${KEYCLOAK_HOME}/bin/kcadm.sh"
PUBLIC_IP=$(hostname -I | awk '{print $1}')
# Use localhost for kcadm.sh - it runs locally
KEYCLOAK_LOCAL_URL="http://localhost:8080"

echo "[1/6] Authenticating to KeyCloak..."
${KCADM} config credentials --server ${KEYCLOAK_LOCAL_URL} --realm master --user ${KEYCLOAK_ADMIN} --password ${KEYCLOAK_ADMIN_PASSWORD}

echo "[2/6] Creating new realm 'splunk'..."
${KCADM} create realms -s realm=splunk -s enabled=true -s displayName="Splunk SSO Realm" || echo "Realm may already exist"

echo "[3/6] Configuring LDAP user federation..."
# Get LDAP bind DN
LDAP_BIND_DN="uid=admin,cn=users,cn=accounts,dc=splunkauth,dc=lab"
LDAP_BIND_PASSWORD="${FREEIPA_ADMIN_PASSWORD}"
LDAP_USERS_DN="cn=users,cn=accounts,dc=splunkauth,dc=lab"
LDAP_GROUPS_DN="cn=groups,cn=accounts,dc=splunkauth,dc=lab"

${KCADM} create components -r splunk -s name=ldap-freeipa -s providerId=ldap -s providerType=org.keycloak.storage.UserStorageProvider \
  -s 'config.priority=["1"]' \
  -s 'config.enabled=["true"]' \
  -s 'config.cachePolicy=["DEFAULT"]' \
  -s 'config.evictionDay=[""]' \
  -s 'config.evictionHour=[""]' \
  -s 'config.evictionMinute=[""]' \
  -s 'config.maxLifespan=[""]' \
  -s 'config.batchSizeForSync=["1000"]' \
  -s 'config.editMode=["READ_ONLY"]' \
  -s 'config.syncRegistrations=["false"]' \
  -s 'config.vendor=["rhds"]' \
  -s 'config.usernameLDAPAttribute=["uid"]' \
  -s 'config.rdnLDAPAttribute=["uid"]' \
  -s 'config.uuidLDAPAttribute=["ipaUniqueID"]' \
  -s 'config.userObjectClasses=["inetOrgPerson, organizationalPerson"]' \
  -s "config.connectionUrl=[\"ldap://${PUBLIC_IP}:389\"]" \
  -s "config.usersDn=[\"${LDAP_USERS_DN}\"]" \
  -s "config.authType=[\"simple\"]" \
  -s "config.bindDn=[\"${LDAP_BIND_DN}\"]" \
  -s "config.bindCredential=[\"${LDAP_BIND_PASSWORD}\"]" \
  -s 'config.searchScope=["1"]' \
  -s 'config.useTruststoreSpi=["ldapsOnly"]' \
  -s 'config.connectionPooling=["true"]' \
  -s 'config.pagination=["true"]' \
  -s 'config.allowKerberosAuthentication=["false"]' \
  -s 'config.debug=["false"]' \
  -s 'config.useKerberosForPasswordAuthentication=["false"]' || echo "LDAP provider may already exist"

echo "[4/6] Getting LDAP storage provider ID..."
LDAP_ID=$(${KCADM} get components -r splunk --fields id,name | grep -B1 "ldap-freeipa" | grep "id" | cut -d'"' -f4)

if [ -z "$LDAP_ID" ]; then
  echo "ERROR: Could not find LDAP provider ID"
  exit 1
fi

echo "LDAP Provider ID: ${LDAP_ID}"

echo "[5/6] Configuring group mapper..."
${KCADM} create components -r splunk -s name=group-mapper -s providerId=group-ldap-mapper -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
  -s "parentId=${LDAP_ID}" \
  -s 'config.mode=["READ_ONLY"]' \
  -s "config.groups.dn=[\"${LDAP_GROUPS_DN}\"]" \
  -s 'config.group.name.ldap.attribute=["cn"]' \
  -s 'config.group.object.classes=["groupOfNames"]' \
  -s 'config.preserve.group.inheritance=["true"]' \
  -s 'config.ignore.missing.groups=["false"]' \
  -s 'config.membership.ldap.attribute=["member"]' \
  -s 'config.membership.attribute.type=["DN"]' \
  -s 'config.membership.user.ldap.attribute=["uid"]' \
  -s 'config.groups.ldap.filter=[""]' \
  -s 'config.user.roles.retrieve.strategy=["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"]' \
  -s 'config.mapped.group.attributes=[""]' \
  -s 'config.drop.non.existing.groups.during.sync=["false"]' || echo "Group mapper may already exist"

echo "[6/6] Synchronizing users and groups from LDAP..."
${KCADM} create user-storage/${LDAP_ID}/sync?action=triggerFullSync -r splunk

echo ""
echo "======================================"
echo "KeyCloak LDAP Configuration Complete!"
echo "======================================"
echo ""
echo "Test the configuration:"
echo "  1. Go to: ${KEYCLOAK_URL}/admin/master/console/#/splunk"
echo "  2. Navigate to Users"
echo "  3. You should see: testuser1, testuser2, testuser3"
echo ""
echo "======================================"
