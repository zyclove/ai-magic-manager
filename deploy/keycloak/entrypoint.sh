#!/bin/bash
set -euo pipefail
# Read credentials only inside the container; Compose inspection sees file references.
export KC_DB_PASSWORD="$(cat /run/secrets/identity_app)"
export KC_BOOTSTRAP_ADMIN_PASSWORD="$(cat /run/secrets/bootstrap_admin)"
exec /opt/keycloak/bin/kc.sh start --optimized --import-realm
