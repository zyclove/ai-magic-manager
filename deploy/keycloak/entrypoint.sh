#!/bin/bash
set -euo pipefail
# Read credentials only inside the container; Compose inspection sees file references.
export KC_DB_PASSWORD="$(cat /run/secrets/identity_app)"
export KC_BOOTSTRAP_ADMIN_PASSWORD="$(cat /run/secrets/bootstrap_admin)"
# The SPI consumes environment variables; only this container reads their file-backed secrets.
for variable in CONSUMER_OTP_HMAC_KEY ALIYUN_SMS_ACCESS_KEY_ID ALIYUN_SMS_ACCESS_KEY_SECRET ALIYUN_SMS_SECURITY_TOKEN WECHAT_NATIVE_APP_SECRET; do
  file_variable="${variable}_FILE"
  secret_file="${!file_variable:-}"
  if [[ -n "$secret_file" ]]; then
    if [[ ! -f "$secret_file" || ! -r "$secret_file" ]] || [[ "$(wc -c < "$secret_file")" -gt 8192 ]]; then
      echo 'Consumer identity secret file is missing, unreadable or too large.' >&2
      exit 1
    fi
    value="$(cat -- "$secret_file")"
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
      echo 'Consumer identity secret file must contain one line.' >&2
      exit 1
    fi
    printf -v "$variable" '%s' "$value"
    export "$variable"
  fi
done
exec /opt/keycloak/bin/kc.sh start --optimized --import-realm
