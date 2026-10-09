ARG KEYCLOAK_BASE_IMAGE=quay.io/keycloak/keycloak:26.8.0
FROM ${KEYCLOAK_BASE_IMAGE}
ENV KC_DB=mysql KC_HEALTH_ENABLED=true KC_HTTP_RELATIVE_PATH=/identity
COPY --chown=1000:0 keycloak/themes/ai-manager/ /opt/keycloak/themes/ai-manager/
COPY --chown=1000:0 --chmod=755 keycloak/entrypoint.sh /opt/keycloak/bin/manager-entrypoint.sh
COPY --chown=1000:0 --chmod=755 keycloak/healthcheck.sh /opt/keycloak/bin/manager-health.sh
RUN /opt/keycloak/bin/kc.sh build
ENTRYPOINT ["/opt/keycloak/bin/manager-entrypoint.sh"]
