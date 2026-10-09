package com.aimanager.lifecycle.internal;

import com.aimanager.fleet.*;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.ECDSAVerifier;
import com.nimbusds.jwt.SignedJWT;
import java.time.*;
import java.util.*;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.core.*;
import org.springframework.security.oauth2.server.resource.introspection.*;
import org.springframework.stereotype.Service;

/** Nimbus verifies the original registered public key. This short-lived proof is reusable authentication, not a one-use nonce. */
@Service
class CleanupAuthentication implements OpaqueTokenIntrospector {
    private final RegistrationKeys keys;
    private final LifecycleService lifecycle;
    private final Clock clock;
    CleanupAuthentication(RegistrationKeys keys, LifecycleService lifecycle, Clock clock) { this.keys = keys; this.lifecycle = lifecycle; this.clock = clock; }
    @Override public OAuth2AuthenticatedPrincipal introspect(String serialized) {
        try {
            if (serialized == null || serialized.length() > 8192) throw new IllegalArgumentException();
            var token = SignedJWT.parse(serialized); var header = token.getHeader();
            if (!JWSAlgorithm.ES256.equals(header.getAlgorithm()) || !new JOSEObjectType("aimanager-cleanup-auth+jwt").equals(header.getType())
                || header.getJWK() != null || header.getJWKURL() != null || header.getX509CertURL() != null || header.getX509CertChain() != null
                || (header.getCriticalParams() != null && !header.getCriticalParams().isEmpty())) throw new IllegalArgumentException();
            var claims = token.getJWTClaimsSet(); String tenant = uuid(claims.getStringClaim("tenantId")), device = uuid(claims.getSubject()),
                registration = uuid(claims.getStringClaim("registrationId"));
            if (!registration.equals(header.getKeyID()) || !("device:" + registration).equals(claims.getIssuer())
                || !List.of("ai-manager:cleanup").equals(claims.getAudience()) || !"AGENT_CLEANUP".equals(claims.getStringClaim("purpose")))
                throw new IllegalArgumentException();
            String action = claims.getStringClaim("action");
            if (!Set.of("READ", "RECEIPT").contains(action)) throw new IllegalArgumentException();
            String operation = claims.getStringClaim("operationId");
            if (operation != null) operation = uuid(operation);
            if ("RECEIPT".equals(action) && operation == null) throw new IllegalArgumentException(); uuid(claims.getJWTID());
            if (claims.getIssueTime() == null || claims.getExpirationTime() == null) throw new IllegalArgumentException();
            Instant now = clock.instant(), issued = claims.getIssueTime().toInstant(), expiry = claims.getExpirationTime().toInstant();
            if (issued.isAfter(now.plusSeconds(30)) || !expiry.isAfter(now) || !expiry.isAfter(issued) || expiry.isAfter(issued.plusSeconds(300))
                || (claims.getNotBeforeTime() != null && claims.getNotBeforeTime().toInstant().isAfter(now.plusSeconds(30)))) throw new IllegalArgumentException();
            var target = lifecycle.authenticationTarget(tenant, device, registration, operation);
            var registered = keys.key(tenant, device, registration); var key = CleanupKey.read(registered, target.thumbprint());
            if (registered.state() != Device.State.REVOKED || !token.verify(new ECDSAVerifier(key))) throw new IllegalArgumentException();
            var attributes = new HashMap<String, Object>(); attributes.put("tenantId", tenant); attributes.put("deviceId", device);
            attributes.put("registrationId", registration); attributes.put("operationId", target.id()); attributes.put("keyThumbprint", registered.thumbprint());
            attributes.put("proofExpiresAt", expiry.toEpochMilli()); attributes.put("action", action);
            return new DefaultOAuth2AuthenticatedPrincipal(device, attributes,
                List.of(new SimpleGrantedAuthority("READ".equals(action) ? "SCOPE_device:cleanup-read" : "SCOPE_device:cleanup-receipt")));
        } catch (Exception failure) { throw new BadOpaqueTokenException("Cleanup proof rejected"); }
    }
    private String uuid(String value) {
        if (value == null || !value.matches(LifecycleController.UUID)) throw new IllegalArgumentException(); return value;
    }
}
