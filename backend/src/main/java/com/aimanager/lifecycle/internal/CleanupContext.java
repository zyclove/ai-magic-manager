package com.aimanager.lifecycle.internal;

import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;

/** Principal attributes are created only by registered-key verification, never copied from request bodies. */
record CleanupContext(String tenant, String device, String registration, String operation, String thumbprint, long proofExpiresAt, String action) {
    static CleanupContext from(OAuth2AuthenticatedPrincipal principal) {
        return new CleanupContext(principal.getAttribute("tenantId"), principal.getAttribute("deviceId"), principal.getAttribute("registrationId"),
            principal.getAttribute("operationId"), principal.getAttribute("keyThumbprint"), principal.getAttribute("proofExpiresAt"), principal.getAttribute("action"));
    }
}
