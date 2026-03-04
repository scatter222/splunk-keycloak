#!/bin/bash
###############################################################################
# diagnose-saml.sh
#
# Comprehensive diagnostic script for Nextcloud + Keycloak SAML SSO.
# Checks every configuration point across both systems and reports exactly
# what's wrong with specific fix commands.
#
# Run from the Nextcloud box as root:
#   sudo bash diagnose-saml.sh
#
# Edit the variables below to match your environment.
###############################################################################

#==============================================================================
# CONFIGURATION — EDIT THESE TO MATCH YOUR ENVIRONMENT
#==============================================================================

# Keycloak (reachable from this Nextcloud box)
KEYCLOAK_URL="http://KEYCLOAK_HOST:8081"        # Browser-facing Keycloak URL (what users see)
KEYCLOAK_API_URL=""                             # API URL for admin calls (leave empty to use KEYCLOAK_URL)
                                                # If Keycloak is on THIS box, set to http://localhost:8081
                                                # to avoid master realm SSL requirement issues
KEYCLOAK_ADMIN="admin"                          # Keycloak admin username
KEYCLOAK_ADMIN_PASSWORD="KeyCloakAdmin123"      # Keycloak admin password
KEYCLOAK_REALM="nextcloud"                      # Realm name

# Nextcloud
NEXTCLOUD_URL="http://NEXTCLOUD_HOST"           # Browser-facing Nextcloud URL
NEXTCLOUD_PATH="/var/www/nextcloud"             # Nextcloud install path
NEXTCLOUD_USER="apache"                         # Web server user (apache or www-data)

# SP Entity ID (usually auto-derived — only override if you customised it)
EXPECTED_SP_ENTITY_ID=""  # Leave empty to auto-derive as ${NEXTCLOUD_URL}/apps/user_saml/saml/metadata

#==============================================================================
# DO NOT EDIT BELOW THIS LINE
#==============================================================================

# Derive SP entity ID if not overridden
if [ -z "$EXPECTED_SP_ENTITY_ID" ]; then
    EXPECTED_SP_ENTITY_ID="${NEXTCLOUD_URL}/apps/user_saml/saml/metadata"
fi

# Derive API URL if not overridden
if [ -z "$KEYCLOAK_API_URL" ]; then
    KEYCLOAK_API_URL="${KEYCLOAK_URL}"
fi

# Colours (disable if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FAILURES=()
WARNINGS=()

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    if [ -n "$2" ]; then
        echo -e "        ${CYAN}Fix:${NC} $2"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$1")
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    if [ -n "$2" ]; then
        echo -e "        ${CYAN}Fix:${NC} $2"
    fi
    WARN_COUNT=$((WARN_COUNT + 1))
    WARNINGS+=("$1")
}

section() {
    echo ""
    echo -e "${BOLD}[$1] $2${NC}"
}

occ() {
    sudo -u "${NEXTCLOUD_USER}" php "${NEXTCLOUD_PATH}/occ" "$@" 2>/dev/null
}

echo ""
echo "============================================================"
echo "  Nextcloud + Keycloak SAML SSO Diagnostic"
echo "============================================================"
echo ""
echo "  Keycloak:  ${KEYCLOAK_URL}  (realm: ${KEYCLOAK_REALM})"
if [ "$KEYCLOAK_API_URL" != "$KEYCLOAK_URL" ]; then
    echo "  KC API:    ${KEYCLOAK_API_URL}  (for admin calls)"
fi
echo "  Nextcloud: ${NEXTCLOUD_URL}  (path: ${NEXTCLOUD_PATH})"
echo "  SP Entity: ${EXPECTED_SP_ENTITY_ID}"
echo ""

# Validate config isn't still placeholder
if [[ "$KEYCLOAK_URL" == *"KEYCLOAK_HOST"* ]] || [[ "$NEXTCLOUD_URL" == *"NEXTCLOUD_HOST"* ]]; then
    echo -e "${RED}ERROR: You must edit the variables at the top of this script first.${NC}"
    echo "  Set KEYCLOAK_URL and NEXTCLOUD_URL to your actual hosts."
    exit 1
fi

###############################################################################
# 1. PREREQUISITES
###############################################################################
section "1/18" "Prerequisites"

for cmd in curl jq php python3; do
    if command -v "$cmd" &>/dev/null; then
        pass "$cmd is installed"
    else
        fail "$cmd is not installed" "sudo dnf install $cmd  # or: sudo apt install $cmd"
    fi
done

if [ -f "${NEXTCLOUD_PATH}/occ" ]; then
    pass "Nextcloud occ found at ${NEXTCLOUD_PATH}/occ"
else
    fail "Nextcloud occ not found at ${NEXTCLOUD_PATH}/occ" "Check NEXTCLOUD_PATH variable"
fi

# Test occ works
if [ -f "${NEXTCLOUD_PATH}/occ" ]; then
    OCC_TEST=$(occ status --output=json 2>/dev/null)
    if echo "$OCC_TEST" | jq -e '.installed' &>/dev/null; then
        pass "occ runs successfully (Nextcloud installed)"
    else
        fail "occ fails to run — check PHP and permissions" "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ status"
    fi
fi

###############################################################################
# 2. NEXTCLOUD HTTP REACHABILITY
###############################################################################
section "2/18" "Nextcloud HTTP reachability"

NC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${NEXTCLOUD_URL}/login" 2>/dev/null)
if [ "$NC_HTTP" = "200" ] || [ "$NC_HTTP" = "303" ] || [ "$NC_HTTP" = "302" ]; then
    pass "Nextcloud responds at ${NEXTCLOUD_URL} (HTTP ${NC_HTTP})"
else
    fail "Nextcloud not reachable at ${NEXTCLOUD_URL} (HTTP ${NC_HTTP})" "Check Apache/nginx is running: systemctl status httpd"
fi

# Check redirect doesn't go to wrong host
NC_REDIRECT=$(curl -s -o /dev/null -w "%{redirect_url}" --max-time 10 "${NEXTCLOUD_URL}/" 2>/dev/null)
if [ -n "$NC_REDIRECT" ]; then
    # Extract host from redirect URL
    REDIRECT_HOST=$(echo "$NC_REDIRECT" | sed -E 's|https?://([^/]+).*|\1|')
    NC_EXPECTED_HOST=$(echo "$NEXTCLOUD_URL" | sed -E 's|https?://([^/]+).*|\1|')
    if [ "$REDIRECT_HOST" = "$NC_EXPECTED_HOST" ]; then
        pass "Nextcloud redirects to correct host (${REDIRECT_HOST})"
    else
        fail "Nextcloud redirects to WRONG host: ${REDIRECT_HOST} (expected ${NC_EXPECTED_HOST})" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:system:set overwritehost --value='${NC_EXPECTED_HOST}'"
    fi
fi

###############################################################################
# 3. KEYCLOAK HTTP REACHABILITY
###############################################################################
section "3/18" "Keycloak HTTP reachability"

KC_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${KEYCLOAK_URL}/" 2>/dev/null)
if [ "$KC_HTTP" = "200" ] || [ "$KC_HTTP" = "302" ] || [ "$KC_HTTP" = "303" ]; then
    pass "Keycloak responds at ${KEYCLOAK_URL} (HTTP ${KC_HTTP})"
else
    fail "Keycloak not reachable at ${KEYCLOAK_URL} (HTTP ${KC_HTTP})" \
         "Check Keycloak is running and firewall allows the port"
fi

###############################################################################
# 4. KEYCLOAK ADMIN AUTH
###############################################################################
section "4/18" "Keycloak admin authentication"

KC_TOKEN=""
KC_TOKEN_RESPONSE=$(curl -s --max-time 10 -X POST \
    "${KEYCLOAK_API_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" 2>/dev/null)

KC_TOKEN=$(echo "$KC_TOKEN_RESPONSE" | jq -r '.access_token' 2>/dev/null)

if [ -n "$KC_TOKEN" ] && [ "$KC_TOKEN" != "null" ]; then
    pass "Admin token obtained from Keycloak"
else
    KC_ERROR=$(echo "$KC_TOKEN_RESPONSE" | jq -r '.error_description // .error // "unknown"' 2>/dev/null)
    fail "Failed to get admin token: ${KC_ERROR}" \
         "Check KEYCLOAK_ADMIN and KEYCLOAK_ADMIN_PASSWORD"
    echo ""
    echo -e "${RED}Cannot continue Keycloak checks without a valid token. Fix auth first.${NC}"
    # Skip to Nextcloud-only checks
    KC_TOKEN=""
fi

###############################################################################
# 5. REALM CONFIGURATION
###############################################################################
section "5/18" "Keycloak realm configuration"

if [ -n "$KC_TOKEN" ]; then
    REALM_JSON=$(curl -s --max-time 10 \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KEYCLOAK_API_URL}/admin/realms/${KEYCLOAK_REALM}" 2>/dev/null)

    REALM_EXISTS=$(echo "$REALM_JSON" | jq -r '.realm // empty' 2>/dev/null)

    if [ "$REALM_EXISTS" = "$KEYCLOAK_REALM" ]; then
        pass "Realm '${KEYCLOAK_REALM}' exists"
    else
        fail "Realm '${KEYCLOAK_REALM}' not found" \
             "Create it: kcadm.sh create realms -s realm=${KEYCLOAK_REALM} -s enabled=true"
    fi

    REALM_ENABLED=$(echo "$REALM_JSON" | jq -r '.enabled // empty' 2>/dev/null)
    if [ "$REALM_ENABLED" = "true" ]; then
        pass "Realm is enabled"
    else
        fail "Realm is NOT enabled" \
             "Enable it in Keycloak admin console → Realm Settings"
    fi

    SSL_REQ=$(echo "$REALM_JSON" | jq -r '.sslRequired // empty' 2>/dev/null)
    if [ "$SSL_REQ" = "none" ]; then
        pass "SSL requirement is 'none' (HTTP SAML flows allowed)"
    elif [ "$SSL_REQ" = "external" ] || [ "$SSL_REQ" = "all" ]; then
        # Check if Nextcloud URL is HTTPS
        if [[ "$NEXTCLOUD_URL" == https://* ]]; then
            pass "SSL requirement is '${SSL_REQ}' (OK since Nextcloud uses HTTPS)"
        else
            fail "SSL requirement is '${SSL_REQ}' — blocks HTTP SAML flows" \
                 "curl -s -X PUT -H 'Authorization: Bearer TOKEN' -H 'Content-Type: application/json' -d '{\"realm\":\"${KEYCLOAK_REALM}\",\"sslRequired\":\"none\"}' ${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}"
        fi
    else
        warn "SSL requirement is '${SSL_REQ}' (unexpected value)"
    fi
else
    warn "Skipping realm checks (no Keycloak token)"
fi

###############################################################################
# 6. LDAP FEDERATION
###############################################################################
section "6/18" "Keycloak LDAP federation"

if [ -n "$KC_TOKEN" ] && [ -n "$REALM_EXISTS" ]; then
    LDAP_COMPONENTS=$(curl -s --max-time 10 \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KEYCLOAK_API_URL}/admin/realms/${KEYCLOAK_REALM}/components?type=org.keycloak.storage.UserStorageProvider" 2>/dev/null)

    LDAP_COUNT=$(echo "$LDAP_COMPONENTS" | jq 'length' 2>/dev/null)

    if [ "$LDAP_COUNT" -gt 0 ] 2>/dev/null; then
        LDAP_NAME=$(echo "$LDAP_COMPONENTS" | jq -r '.[0].name' 2>/dev/null)
        LDAP_ID=$(echo "$LDAP_COMPONENTS" | jq -r '.[0].id' 2>/dev/null)
        pass "LDAP federation found: '${LDAP_NAME}' (${LDAP_ID})"

        # Check if LDAP connection URL is set
        LDAP_CONN=$(echo "$LDAP_COMPONENTS" | jq -r '.[0].config.connectionUrl[0] // empty' 2>/dev/null)
        if [ -n "$LDAP_CONN" ]; then
            pass "LDAP connection URL: ${LDAP_CONN}"
        else
            fail "LDAP connection URL is empty" "Set it in Keycloak admin → User Federation → LDAP"
        fi

        # Check users exist in realm
        USERS_JSON=$(curl -s --max-time 10 \
            -H "Authorization: Bearer ${KC_TOKEN}" \
            "${KEYCLOAK_API_URL}/admin/realms/${KEYCLOAK_REALM}/users?max=5" 2>/dev/null)
        USER_COUNT=$(echo "$USERS_JSON" | jq 'length' 2>/dev/null)
        if [ "$USER_COUNT" -gt 0 ] 2>/dev/null; then
            FIRST_USER=$(echo "$USERS_JSON" | jq -r '.[0].username' 2>/dev/null)
            pass "Users found in realm (${USER_COUNT} shown, first: ${FIRST_USER})"
        else
            warn "No users found in realm — LDAP sync may not have run" \
                 "Trigger sync: POST ${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/user-storage/${LDAP_ID}/sync?action=triggerFullSync"
        fi
    else
        warn "No LDAP user federation found in realm '${KEYCLOAK_REALM}'" \
             "Configure LDAP federation in Keycloak admin → User Federation"
    fi
else
    warn "Skipping LDAP checks (no Keycloak token or realm)"
fi

###############################################################################
# 7. SAML CLIENT EXISTS
###############################################################################
section "7/18" "Keycloak SAML client"

KC_CLIENT_UUID=""
KC_CLIENT_JSON=""

if [ -n "$KC_TOKEN" ] && [ -n "$REALM_EXISTS" ]; then
    ALL_CLIENTS=$(curl -s --max-time 10 \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KEYCLOAK_API_URL}/admin/realms/${KEYCLOAK_REALM}/clients" 2>/dev/null)

    # Look for a SAML client matching expected entity ID
    KC_CLIENT_UUID=$(echo "$ALL_CLIENTS" | jq -r --arg eid "$EXPECTED_SP_ENTITY_ID" \
        '.[] | select(.clientId == $eid and .protocol == "saml") | .id' 2>/dev/null)

    if [ -n "$KC_CLIENT_UUID" ]; then
        pass "SAML client found with entity ID: ${EXPECTED_SP_ENTITY_ID}"
        KC_CLIENT_JSON=$(echo "$ALL_CLIENTS" | jq --arg eid "$EXPECTED_SP_ENTITY_ID" \
            '.[] | select(.clientId == $eid)' 2>/dev/null)
    else
        # Check if there's ANY saml client
        ANY_SAML=$(echo "$ALL_CLIENTS" | jq -r '.[] | select(.protocol == "saml") | .clientId' 2>/dev/null)
        if [ -n "$ANY_SAML" ]; then
            fail "No SAML client with entity ID '${EXPECTED_SP_ENTITY_ID}' — but found SAML client(s):" \
                 "The client ID in Keycloak must exactly match the SP entity ID"
            echo "$ANY_SAML" | while read -r cid; do
                echo -e "        Found: ${YELLOW}${cid}${NC}"
            done
        else
            fail "No SAML clients found in realm '${KEYCLOAK_REALM}'" \
                 "Create a SAML client in Keycloak with client ID = ${EXPECTED_SP_ENTITY_ID}"
        fi
    fi
else
    warn "Skipping SAML client checks (no Keycloak token)"
fi

###############################################################################
# 8. SAML CLIENT ATTRIBUTES
###############################################################################
section "8/18" "SAML client attributes"

if [ -n "$KC_CLIENT_JSON" ]; then
    # Check enabled
    CLIENT_ENABLED=$(echo "$KC_CLIENT_JSON" | jq -r '.enabled' 2>/dev/null)
    if [ "$CLIENT_ENABLED" = "true" ]; then
        pass "Client is enabled"
    else
        fail "Client is DISABLED" "Enable it in Keycloak admin console"
    fi

    # Check critical SAML attributes
    check_client_attr() {
        local ATTR_NAME="$1"
        local EXPECTED="$2"
        local LABEL="$3"
        local ACTUAL=$(echo "$KC_CLIENT_JSON" | jq -r ".attributes.\"${ATTR_NAME}\" // empty" 2>/dev/null)

        if [ "$ACTUAL" = "$EXPECTED" ]; then
            pass "${LABEL}: ${ACTUAL}"
        elif [ -z "$ACTUAL" ]; then
            fail "${LABEL}: NOT SET (expected: ${EXPECTED})" \
                 "Set attribute '${ATTR_NAME}' to '${EXPECTED}' on the SAML client"
        else
            fail "${LABEL}: '${ACTUAL}' (expected: '${EXPECTED}')" \
                 "Set attribute '${ATTR_NAME}' to '${EXPECTED}' on the SAML client"
        fi
    }

    # ACS URL
    ACS_ACTUAL=$(echo "$KC_CLIENT_JSON" | jq -r '.attributes.saml_assertion_consumer_url_post // empty' 2>/dev/null)
    ACS_EXPECTED="${NEXTCLOUD_URL}/apps/user_saml/saml/acs"
    if [ "$ACS_ACTUAL" = "$ACS_EXPECTED" ]; then
        pass "ACS URL: ${ACS_ACTUAL}"
    elif [ -z "$ACS_ACTUAL" ]; then
        warn "ACS URL (saml_assertion_consumer_url_post) not explicitly set — may use redirect URIs instead"
    else
        fail "ACS URL mismatch: '${ACS_ACTUAL}' (expected: '${ACS_EXPECTED}')" \
             "Update saml_assertion_consumer_url_post on the client"
    fi

    # SLS URL
    SLS_ACTUAL=$(echo "$KC_CLIENT_JSON" | jq -r '.attributes.saml_single_logout_service_url_post // empty' 2>/dev/null)
    SLS_EXPECTED="${NEXTCLOUD_URL}/apps/user_saml/saml/sls"
    if [ "$SLS_ACTUAL" = "$SLS_EXPECTED" ]; then
        pass "SLS URL: ${SLS_ACTUAL}"
    elif [ -z "$SLS_ACTUAL" ]; then
        warn "SLS URL not explicitly set"
    else
        fail "SLS URL mismatch: '${SLS_ACTUAL}' (expected: '${SLS_EXPECTED}')" \
             "Update saml_single_logout_service_url_post on the client"
    fi

    check_client_attr "saml_name_id_format" "username" "NameID format"
    check_client_attr "saml.authnstatement" "true" "Include AuthnStatement"
    check_client_attr "saml.server.signature" "true" "Server signature"
    check_client_attr "saml.assertion.signature" "true" "Assertion signature"
    check_client_attr "saml.client.signature" "false" "Client signature (should be false)"
    check_client_attr "saml.force.post.binding" "true" "Force POST binding"

    # Check redirect URIs include Nextcloud
    REDIRECT_URIS=$(echo "$KC_CLIENT_JSON" | jq -r '.redirectUris[]' 2>/dev/null)
    REDIRECT_MATCH=""
    while IFS= read -r uri; do
        NC_HOST=$(echo "$NEXTCLOUD_URL" | sed -E 's|https?://||')
        if [[ "$uri" == *"$NC_HOST"* ]]; then
            REDIRECT_MATCH="$uri"
            break
        fi
    done <<< "$REDIRECT_URIS"
    if [ -n "$REDIRECT_MATCH" ]; then
        pass "Redirect URI includes Nextcloud: ${REDIRECT_MATCH}"
    else
        fail "No redirect URI matches Nextcloud URL" \
             "Add '${NEXTCLOUD_URL}/*' to the client's Valid Redirect URIs"
    fi
else
    warn "Skipping client attribute checks (no SAML client found)"
fi

###############################################################################
# 9. PROTOCOL MAPPERS
###############################################################################
section "9/18" "SAML protocol mappers"

if [ -n "$KC_CLIENT_UUID" ] && [ -n "$KC_TOKEN" ]; then
    MAPPERS_JSON=$(curl -s --max-time 10 \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KEYCLOAK_API_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}/protocol-mappers/models" 2>/dev/null)

    check_mapper() {
        local MAPPER_NAME="$1"
        local EXPECTED_ATTR="$2"
        local EXPECTED_USER_ATTR="$3"

        local FOUND=$(echo "$MAPPERS_JSON" | jq -r --arg n "$MAPPER_NAME" \
            '.[] | select(.name == $n)' 2>/dev/null)

        if [ -n "$FOUND" ]; then
            local ACTUAL_ATTR=$(echo "$FOUND" | jq -r '.config["attribute.name"] // empty' 2>/dev/null)
            local ACTUAL_USER=$(echo "$FOUND" | jq -r '.config["user.attribute"] // empty' 2>/dev/null)

            if [ "$ACTUAL_ATTR" = "$EXPECTED_ATTR" ]; then
                pass "Mapper '${MAPPER_NAME}': attribute.name='${ACTUAL_ATTR}'"
            else
                fail "Mapper '${MAPPER_NAME}' attribute.name='${ACTUAL_ATTR}' (expected '${EXPECTED_ATTR}')" \
                     "Update the mapper's attribute.name to '${EXPECTED_ATTR}'"
            fi
        else
            fail "Mapper '${MAPPER_NAME}' not found on SAML client" \
                 "Add a saml-user-property-mapper named '${MAPPER_NAME}' with attribute.name='${EXPECTED_ATTR}', user.attribute='${EXPECTED_USER_ATTR}'"
        fi
    }

    check_mapper "username" "uid" "username"
    check_mapper "email" "email" "email"
    check_mapper "firstName" "firstName" "firstName"
    check_mapper "lastName" "lastName" "lastName"

    # Check groups mapper (different type)
    GROUPS_MAPPER=$(echo "$MAPPERS_JSON" | jq '.[] | select(.name == "groups")' 2>/dev/null)
    if [ -n "$GROUPS_MAPPER" ]; then
        GROUPS_ATTR=$(echo "$GROUPS_MAPPER" | jq -r '.config["attribute.name"] // empty' 2>/dev/null)
        if [ "$GROUPS_ATTR" = "groups" ]; then
            pass "Mapper 'groups': attribute.name='groups'"
        else
            fail "Mapper 'groups' attribute.name='${GROUPS_ATTR}' (expected 'groups')" \
                 "Update the groups mapper attribute.name to 'groups'"
        fi
    else
        fail "Groups mapper not found on SAML client" \
             "Add a saml-group-membership-mapper named 'groups' with attribute.name='groups'"
    fi
else
    warn "Skipping mapper checks (no SAML client)"
fi

###############################################################################
# 10. ROLE_LIST SCOPE — single=true
###############################################################################
section "10/18" "role_list client scope (single attribute)"

if [ -n "$KC_TOKEN" ] && [ -n "$REALM_EXISTS" ]; then
    SCOPES_JSON=$(curl -s --max-time 10 \
        -H "Authorization: Bearer ${KC_TOKEN}" \
        "${KEYCLOAK_API_URL}/admin/realms/${KEYCLOAK_REALM}/client-scopes" 2>/dev/null)

    RL_SCOPE_ID=$(echo "$SCOPES_JSON" | jq -r '.[] | select(.name == "role_list") | .id' 2>/dev/null)

    if [ -n "$RL_SCOPE_ID" ]; then
        RL_MAPPERS=$(curl -s --max-time 10 \
            -H "Authorization: Bearer ${KC_TOKEN}" \
            "${KEYCLOAK_API_URL}/admin/realms/${KEYCLOAK_REALM}/client-scopes/${RL_SCOPE_ID}/protocol-mappers/models" 2>/dev/null)

        RL_SINGLE=$(echo "$RL_MAPPERS" | jq -r '.[] | select(.name == "role list") | .config.single // empty' 2>/dev/null)

        if [ "$RL_SINGLE" = "true" ]; then
            pass "role_list mapper has single=true (no duplicate Role attributes)"
        elif [ "$RL_SINGLE" = "false" ]; then
            fail "role_list mapper has single=false — causes 'duplicated Name' error in php-saml" \
                 "Update the 'role list' mapper in the 'role_list' client scope: set single=true"
        else
            warn "Could not determine role_list mapper 'single' value (got: '${RL_SINGLE}')"
        fi
    else
        warn "role_list client scope not found (may not exist in this Keycloak version)"
    fi
else
    warn "Skipping role_list checks (no Keycloak token)"
fi

###############################################################################
# 11. IDP CERTIFICATE
###############################################################################
section "11/18" "IdP signing certificate"

IDP_CERT=""
if [ -n "$KEYCLOAK_URL" ] && [ -n "$KEYCLOAK_REALM" ]; then
    SAML_DESC=$(curl -s --max-time 10 \
        "${KEYCLOAK_API_URL}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor" 2>/dev/null)

    if echo "$SAML_DESC" | grep -q "IDPSSODescriptor" 2>/dev/null; then
        pass "SAML descriptor retrieved from Keycloak"

        IDP_CERT=$(echo "$SAML_DESC" | python3 -c "
import sys, xml.etree.ElementTree as ET
ns = {'md': 'urn:oasis:names:tc:SAML:2.0:metadata', 'ds': 'http://www.w3.org/2000/09/xmldsig#'}
try:
    tree = ET.parse(sys.stdin)
    root = tree.getroot()
    for kd in root.findall('.//md:IDPSSODescriptor/md:KeyDescriptor[@use=\"signing\"]/ds:KeyInfo/ds:X509Data/ds:X509Certificate', ns):
        print(kd.text.strip()); break
    else:
        for kd in root.findall('.//ds:X509Certificate', ns):
            print(kd.text.strip()); break
except: pass
" 2>/dev/null)

        if [ -n "$IDP_CERT" ]; then
            pass "IdP signing certificate extracted (${#IDP_CERT} chars)"

            # Check expiry with openssl
            CERT_PEM="-----BEGIN CERTIFICATE-----
${IDP_CERT}
-----END CERTIFICATE-----"
            EXPIRY=$(echo "$CERT_PEM" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
            if [ -n "$EXPIRY" ]; then
                EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
                NOW_EPOCH=$(date +%s)
                if [ -n "$EXPIRY_EPOCH" ] && [ "$EXPIRY_EPOCH" -gt "$NOW_EPOCH" ]; then
                    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
                    if [ "$DAYS_LEFT" -lt 30 ]; then
                        warn "IdP certificate expires in ${DAYS_LEFT} days (${EXPIRY})"
                    else
                        pass "IdP certificate valid until ${EXPIRY} (${DAYS_LEFT} days)"
                    fi
                else
                    fail "IdP certificate has EXPIRED (${EXPIRY})" \
                         "Rotate the signing key in Keycloak → Realm Settings → Keys"
                fi
            else
                warn "Could not parse certificate expiry date"
            fi
        else
            fail "Could not extract certificate from SAML descriptor" \
                 "Get it manually from: ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor"
        fi
    else
        fail "SAML descriptor not available at ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor" \
             "Check realm exists and Keycloak is running"
    fi
fi

###############################################################################
# 12. NEXTCLOUD user_saml APP
###############################################################################
section "12/18" "Nextcloud user_saml app"

if [ -f "${NEXTCLOUD_PATH}/occ" ]; then
    APP_LIST=$(occ app:list --output=json 2>/dev/null)

    if echo "$APP_LIST" | jq -e '.enabled.user_saml' &>/dev/null; then
        SAML_VERSION=$(echo "$APP_LIST" | jq -r '.enabled.user_saml' 2>/dev/null)
        pass "user_saml app is ENABLED (version ${SAML_VERSION})"
    elif echo "$APP_LIST" | jq -e '.disabled.user_saml' &>/dev/null; then
        fail "user_saml app is DISABLED" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ app:enable user_saml"
    else
        fail "user_saml app is NOT INSTALLED" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ app:install user_saml"
    fi

    # Check global user_saml settings
    SAML_TYPE=$(occ config:app:get user_saml type 2>/dev/null)
    if [ "$SAML_TYPE" = "saml" ]; then
        pass "user_saml type = 'saml' (built-in php-saml)"
    elif [ -z "$SAML_TYPE" ]; then
        fail "user_saml type not set" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:app:set user_saml type --value='saml'"
    else
        warn "user_saml type = '${SAML_TYPE}' (expected 'saml')"
    fi

    MULTI_BACK=$(occ config:app:get user_saml general-allow_multiple_user_back_ends 2>/dev/null)
    if [ "$MULTI_BACK" = "1" ]; then
        pass "Multiple user backends allowed (local admin login works)"
    else
        warn "Multiple user backends NOT enabled — local admin login may not work" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:app:set user_saml general-allow_multiple_user_back_ends --value='1'"
    fi

    REQ_PROV=$(occ config:app:get user_saml general-require_provisioned_account 2>/dev/null)
    if [ "$REQ_PROV" = "0" ]; then
        pass "Auto-provisioning enabled (new SAML users created automatically)"
    elif [ "$REQ_PROV" = "1" ]; then
        warn "Auto-provisioning DISABLED — SAML users must be pre-created in Nextcloud" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:app:set user_saml general-require_provisioned_account --value='0'"
    fi
fi

###############################################################################
# 13. NEXTCLOUD SAML PROVIDER CONFIG
###############################################################################
section "13/18" "Nextcloud SAML provider configuration"

FIRST_PROVIDER=""
NC_SP_ENTITY=""

if [ -f "${NEXTCLOUD_PATH}/occ" ]; then
    # Try to get provider configs — user_saml v7.x uses saml:config:get
    # Output format is YAML-like:
    #   - 1:
    #       - key: value
    #       - key: value
    PROVIDER_CONFIG=$(occ saml:config:get 2>/dev/null)

    if [ -n "$PROVIDER_CONFIG" ]; then
        # Check if any providers exist (look for "- N:" lines, may have leading spaces)
        PROVIDER_IDS=$(echo "$PROVIDER_CONFIG" | grep -oP '(?<=- )\d+(?=:)' | sort -u)
        if [ -n "$PROVIDER_IDS" ]; then
            FIRST_PROVIDER=$(echo "$PROVIDER_IDS" | head -1)
            pass "SAML provider(s) found: $(echo $PROVIDER_IDS | tr '\n' ' ')"

            # Parse the YAML-like provider config
            # Lines look like: "    - key: value"
            get_provider_val() {
                echo "$PROVIDER_CONFIG" | grep -P "^\s+- $1:" | head -1 | sed -E "s/^\s+- $1:\s*//"
            }

            # Check idp-entityId
            IDP_ENTITY=$(get_provider_val "idp-entityId")
            EXPECTED_IDP_ENTITY="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}"
            if [ "$IDP_ENTITY" = "$EXPECTED_IDP_ENTITY" ]; then
                pass "idp-entityId: ${IDP_ENTITY}"
            elif [ -n "$IDP_ENTITY" ]; then
                fail "idp-entityId: '${IDP_ENTITY}' (expected '${EXPECTED_IDP_ENTITY}')" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --idp-entityId='${EXPECTED_IDP_ENTITY}'"
            else
                fail "idp-entityId is NOT SET" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --idp-entityId='${EXPECTED_IDP_ENTITY}'"
            fi

            # Check SSO URL
            SSO_URL=$(get_provider_val "idp-singleSignOnService.url")
            EXPECTED_SSO="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/saml"
            if [ "$SSO_URL" = "$EXPECTED_SSO" ]; then
                pass "SSO URL: ${SSO_URL}"
            elif [ -n "$SSO_URL" ]; then
                fail "SSO URL: '${SSO_URL}' (expected '${EXPECTED_SSO}')" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --idp-singleSignOnService.url='${EXPECTED_SSO}'"
            else
                fail "SSO URL is NOT SET" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --idp-singleSignOnService.url='${EXPECTED_SSO}'"
            fi

            # Check SLO URL
            SLO_URL=$(get_provider_val "idp-singleLogoutService.url")
            if [ -n "$SLO_URL" ]; then
                pass "SLO URL: ${SLO_URL}"
            else
                warn "SLO URL not set (logout may not redirect back properly)" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --idp-singleLogoutService.url='${EXPECTED_SSO}'"
            fi

            # Check certificate
            IDP_CERT_NC=$(get_provider_val "idp-x509cert")
            if [ -n "$IDP_CERT_NC" ]; then
                if echo "$IDP_CERT_NC" | grep -q "BEGIN CERTIFICATE" 2>/dev/null; then
                    pass "IdP certificate is set (PEM format)"
                else
                    warn "IdP certificate is set but may not be in PEM format (missing BEGIN CERTIFICATE header)"
                fi
            else
                fail "IdP certificate is NOT SET — SAML assertions cannot be validated" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --idp-x509cert='-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----'"
            fi

            # Check SP entity ID
            SP_ENTITY=$(get_provider_val "sp-entityId")
            NC_SP_ENTITY="$SP_ENTITY"
            if [ "$SP_ENTITY" = "$EXPECTED_SP_ENTITY_ID" ]; then
                pass "sp-entityId: ${SP_ENTITY}"
            elif [ -n "$SP_ENTITY" ]; then
                fail "sp-entityId: '${SP_ENTITY}' (expected '${EXPECTED_SP_ENTITY_ID}')" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --sp-entityId='${EXPECTED_SP_ENTITY_ID}'"
            else
                fail "sp-entityId is NOT SET" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --sp-entityId='${EXPECTED_SP_ENTITY_ID}'"
            fi

            # Check uid mapping
            UID_MAP=$(get_provider_val "general-uid_mapping")
            if [ -n "$UID_MAP" ]; then
                pass "UID mapping: '${UID_MAP}'"
            else
                fail "UID mapping not set — Nextcloud won't know which SAML attribute is the username" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --general-uid_mapping='uid'"
            fi

            # Check display name mapping
            DN_MAP=$(get_provider_val "saml-attribute-mapping-displayName_mapping")
            if [ -n "$DN_MAP" ]; then
                pass "Display name mapping: '${DN_MAP}'"
            else
                warn "Display name mapping not set" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --saml-attribute-mapping-displayName_mapping='firstName'"
            fi

            # Check email mapping
            EMAIL_MAP=$(get_provider_val "saml-attribute-mapping-email_mapping")
            if [ -n "$EMAIL_MAP" ]; then
                pass "Email mapping: '${EMAIL_MAP}'"
            else
                warn "Email mapping not set" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --saml-attribute-mapping-email_mapping='email'"
            fi

            # Check group mapping
            GRP_MAP=$(get_provider_val "saml-attribute-mapping-group_mapping")
            if [ -n "$GRP_MAP" ]; then
                pass "Group mapping: '${GRP_MAP}'"
            else
                warn "Group mapping not set (SAML groups won't sync)" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --saml-attribute-mapping-group_mapping='groups'"
            fi

            # Check display name for login button
            DISPLAY_NAME=$(get_provider_val "general-idp0_display_name")
            if [ -n "$DISPLAY_NAME" ]; then
                pass "Login button label: '${DISPLAY_NAME}'"
            else
                warn "No display name set for SSO button (will show generic text)" \
                     "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:set ${FIRST_PROVIDER} --general-idp0_display_name='Keycloak SSO'"
            fi
        else
            fail "No SAML providers configured in Nextcloud" \
                 "Create one: sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:create"
        fi
    else
        # Fallback: check if saml:config:get command even exists
        OCC_HELP=$(occ list 2>/dev/null | grep saml)
        if [ -n "$OCC_HELP" ]; then
            fail "No SAML providers configured (saml:config:get returned empty)" \
                 "Create one: sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ saml:config:create"
        else
            warn "saml:config commands not available — user_saml app may be old version or not enabled"
        fi
    fi
fi

###############################################################################
# 14. NEXTCLOUD OVERWRITE SETTINGS
###############################################################################
section "14/18" "Nextcloud overwrite settings"

if [ -f "${NEXTCLOUD_PATH}/occ" ]; then
    NC_HOST=$(echo "$NEXTCLOUD_URL" | sed -E 's|https?://||' | sed 's|/.*||')
    NC_PROTOCOL=$(echo "$NEXTCLOUD_URL" | sed -E 's|(https?)://.*|\1|')

    OW_HOST=$(occ config:system:get overwritehost 2>/dev/null)
    if [ "$OW_HOST" = "$NC_HOST" ]; then
        pass "overwritehost: ${OW_HOST}"
    elif [ -n "$OW_HOST" ]; then
        fail "overwritehost: '${OW_HOST}' (expected '${NC_HOST}')" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:system:set overwritehost --value='${NC_HOST}'"
    else
        fail "overwritehost is NOT SET — SP metadata will use wrong hostname" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:system:set overwritehost --value='${NC_HOST}'"
    fi

    OW_PROTO=$(occ config:system:get overwriteprotocol 2>/dev/null)
    if [ "$OW_PROTO" = "$NC_PROTOCOL" ]; then
        pass "overwriteprotocol: ${OW_PROTO}"
    elif [ -n "$OW_PROTO" ]; then
        warn "overwriteprotocol: '${OW_PROTO}' (expected '${NC_PROTOCOL}')"
    else
        fail "overwriteprotocol is NOT SET" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:system:set overwriteprotocol --value='${NC_PROTOCOL}'"
    fi

    OW_COND=$(occ config:system:get overwritecondaddr 2>/dev/null)
    if [ -n "$OW_COND" ]; then
        pass "overwritecondaddr: ${OW_COND}"
    else
        fail "overwritecondaddr is NOT SET — overwrite settings may not take effect" \
             "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:system:set overwritecondaddr --value='.*'"
    fi
fi

###############################################################################
# 15. TRUSTED DOMAINS
###############################################################################
section "15/18" "Nextcloud trusted domains"

if [ -f "${NEXTCLOUD_PATH}/occ" ]; then
    NC_HOST=$(echo "$NEXTCLOUD_URL" | sed -E 's|https?://||' | sed 's|/.*||')
    TRUSTED=$(occ config:system:get trusted_domains 2>/dev/null)

    if echo "$TRUSTED" | grep -qF "$NC_HOST" 2>/dev/null; then
        pass "'${NC_HOST}' is in trusted_domains"
    else
        # Check all indexed domains
        FOUND=0
        for i in 0 1 2 3 4 5; do
            TD=$(occ config:system:get trusted_domains "$i" 2>/dev/null)
            if [ "$TD" = "$NC_HOST" ]; then
                FOUND=1
                break
            fi
        done
        if [ "$FOUND" = "1" ]; then
            pass "'${NC_HOST}' is in trusted_domains"
        else
            fail "'${NC_HOST}' is NOT in trusted_domains — Nextcloud will reject requests" \
                 "sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:system:set trusted_domains 1 --value='${NC_HOST}'"
        fi
    fi
fi

###############################################################################
# 16. SP METADATA ENDPOINT
###############################################################################
section "16/18" "Nextcloud SP metadata endpoint"

SP_META_URL="${NEXTCLOUD_URL}/apps/user_saml/saml/metadata"
SP_META=$(curl -s --max-time 10 "${SP_META_URL}" 2>/dev/null)

if echo "$SP_META" | grep -q "EntityDescriptor" 2>/dev/null; then
    pass "SP metadata returned from ${SP_META_URL}"

    # Check entity ID in metadata
    META_ENTITY=$(echo "$SP_META" | grep -oP 'entityID="[^"]*"' | head -1 | sed 's/entityID="//;s/"//')
    if [ "$META_ENTITY" = "$EXPECTED_SP_ENTITY_ID" ]; then
        pass "SP metadata entityID: ${META_ENTITY}"
    elif [ -n "$META_ENTITY" ]; then
        fail "SP metadata entityID: '${META_ENTITY}' (expected '${EXPECTED_SP_ENTITY_ID}')" \
             "This usually means overwritehost is wrong or not set"
    fi

    # Check ACS URL in metadata
    META_ACS=$(echo "$SP_META" | grep -oP 'Location="[^"]*acs[^"]*"' | head -1 | sed 's/Location="//;s/"//')
    if [ -n "$META_ACS" ]; then
        if echo "$META_ACS" | grep -q "localhost" 2>/dev/null; then
            fail "SP metadata ACS URL contains 'localhost': ${META_ACS}" \
                 "Set overwritehost: sudo -u ${NEXTCLOUD_USER} php ${NEXTCLOUD_PATH}/occ config:system:set overwritehost --value='$(echo "$NEXTCLOUD_URL" | sed -E 's|https?://||' | sed 's|/.*||')'"
        elif echo "$META_ACS" | grep -qF "$(echo "$NEXTCLOUD_URL" | sed -E 's|https?://||' | sed 's|/.*||')" 2>/dev/null; then
            pass "SP metadata ACS URL: ${META_ACS}"
        else
            warn "SP metadata ACS URL: ${META_ACS} (may not match Keycloak config)"
        fi
    fi
elif echo "$SP_META" | grep -qi "error\|not found\|exception" 2>/dev/null; then
    fail "SP metadata endpoint returned an error" \
         "Check user_saml is enabled and SAML provider is configured"
else
    fail "SP metadata not available at ${SP_META_URL} (got: $(echo "$SP_META" | head -c 100))" \
         "Ensure user_saml app is enabled and a SAML provider is configured"
fi

###############################################################################
# 17. ENTITY ID CROSS-CHECK
###############################################################################
section "17/18" "Cross-system entity ID consistency"

if [ -n "$KC_CLIENT_JSON" ] && [ -f "${NEXTCLOUD_PATH}/occ" ]; then
    KC_ENTITY=$(echo "$KC_CLIENT_JSON" | jq -r '.clientId' 2>/dev/null)

    if [ -n "$NC_SP_ENTITY" ] && [ -n "$KC_ENTITY" ]; then
        if [ "$KC_ENTITY" = "$NC_SP_ENTITY" ]; then
            pass "Entity IDs match: Keycloak clientId == Nextcloud sp-entityId"
            echo -e "        ${CYAN}Value:${NC} ${KC_ENTITY}"
        else
            fail "Entity ID MISMATCH between Keycloak and Nextcloud" \
                 "They must be identical"
            echo -e "        Keycloak clientId:   ${RED}${KC_ENTITY}${NC}"
            echo -e "        Nextcloud sp-entityId: ${RED}${NC_SP_ENTITY}${NC}"
        fi
    else
        warn "Could not cross-check entity IDs (one or both not available)"
    fi
else
    warn "Skipping entity ID cross-check (missing Keycloak client or Nextcloud config)"
fi

###############################################################################
# 18. SAMESITE COOKIE PATCH
###############################################################################
section "18/18" "SameSite cookie patch (HTTP compatibility)"

SAML_CONTROLLER="${NEXTCLOUD_PATH}/apps/user_saml/lib/Controller/SAMLController.php"
if [ -f "$SAML_CONTROLLER" ]; then
    if [[ "$NEXTCLOUD_URL" == https://* ]]; then
        pass "Nextcloud uses HTTPS — SameSite=None is fine, no patch needed"
    else
        if grep -q "'None'" "$SAML_CONTROLLER" 2>/dev/null; then
            fail "SAMLController.php still has SameSite=None — cookies will be dropped on HTTP" \
                 "sed -i \"s/'None'/'Lax'/g\" ${SAML_CONTROLLER}"
        elif grep -q "'Lax'" "$SAML_CONTROLLER" 2>/dev/null; then
            pass "SAMLController.php patched to SameSite=Lax"
        else
            warn "Could not find SameSite setting in SAMLController.php (check manually)"
        fi
    fi
else
    if echo "$APP_LIST" | jq -e '.enabled.user_saml' &>/dev/null 2>/dev/null; then
        warn "SAMLController.php not found at expected path: ${SAML_CONTROLLER}"
    fi
fi

###############################################################################
# SUMMARY
###############################################################################
echo ""
echo "============================================================"
echo -e "  ${BOLD}DIAGNOSTIC SUMMARY${NC}"
echo "============================================================"
echo ""
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${NC}    ${RED}FAIL: ${FAIL_COUNT}${NC}    ${YELLOW}WARN: ${WARN_COUNT}${NC}"
echo ""

if [ ${FAIL_COUNT} -eq 0 ] && [ ${WARN_COUNT} -eq 0 ]; then
    echo -e "  ${GREEN}All checks passed! SAML SSO should be working.${NC}"
    echo ""
    echo "  Test it:"
    echo "    1. Open ${NEXTCLOUD_URL}/login"
    echo "    2. Click the SSO login button"
    echo "    3. Authenticate in Keycloak"
    echo "    4. You should land back in Nextcloud, logged in"
    echo ""
    echo "  Direct admin login: ${NEXTCLOUD_URL}/login?direct=1"
elif [ ${FAIL_COUNT} -eq 0 ]; then
    echo -e "  ${YELLOW}No failures, but ${WARN_COUNT} warning(s) — SSO may still work.${NC}"
    echo "  Review the warnings above."
else
    echo -e "  ${RED}Found ${FAIL_COUNT} issue(s) that will likely prevent SSO from working:${NC}"
    echo ""
    for i in "${!FAILURES[@]}"; do
        echo -e "    $((i+1)). ${FAILURES[$i]}"
    done
    echo ""
    echo "  Fix the FAIL items above (each has a Fix: command), then re-run this script."
fi

if [ ${WARN_COUNT} -gt 0 ] && [ ${FAIL_COUNT} -gt 0 ]; then
    echo ""
    echo -e "  ${YELLOW}Additionally, ${WARN_COUNT} warning(s):${NC}"
    for i in "${!WARNINGS[@]}"; do
        echo -e "    - ${WARNINGS[$i]}"
    done
fi

echo ""
echo "============================================================"
echo ""
