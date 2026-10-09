package com.aimanager.fleet;

import org.springframework.security.oauth2.jwt.Jwt;

/** Trusted lifecycle boundary. Revocation never means local erasure or removal of system management. */
public interface FleetAdministration {
    void revokeRegistration(String tenantId, Jwt actor, String deviceId, String registrationId, long expectedVersion);
}
