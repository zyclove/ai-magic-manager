package com.aimanager.deviceidentity;

import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;

/** Immutable context obtained ONLY from the dedicated opaque credential authentication chain. */
public record DeviceContext(String tenantId, String deviceId, String registrationId, String credentialId) {
    public static DeviceContext from(OAuth2AuthenticatedPrincipal principal) {
        return new DeviceContext(principal.getAttribute("tenantId"), principal.getAttribute("deviceId"),
            principal.getAttribute("registrationId"), principal.getAttribute("credentialId"));
    }
}
