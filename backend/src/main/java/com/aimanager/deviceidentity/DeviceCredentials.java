package com.aimanager.deviceidentity;

import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.audit.AuditService;
import java.time.Clock;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.oauth2.core.DefaultOAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.server.resource.introspection.BadOpaqueTokenException;
import org.springframework.security.oauth2.server.resource.introspection.OpaqueTokenIntrospector;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** Spring Security performs bearer authentication; this module owns revocable credential facts. */
@Service
public class DeviceCredentials implements OpaqueTokenIntrospector {
    private final JdbcTemplate jdbc;
    private final Clock clock;
    private final long lifetimeSeconds;
    private final long rotationLifetimeSeconds;
    private final AuditService audit;
    public DeviceCredentials(JdbcTemplate jdbc, Clock clock, AuditService audit,
                             @Value("${manager.devices.credential-lifetime-seconds:604800}") long lifetimeSeconds,
                             @Value("${manager.devices.rotation-lifetime-seconds:300}") long rotationLifetimeSeconds) {
        if (lifetimeSeconds < 3600 || lifetimeSeconds > 2592000) throw new IllegalArgumentException("Invalid device credential lifetime");
        if (rotationLifetimeSeconds < 30 || rotationLifetimeSeconds > 600) throw new IllegalArgumentException("Invalid rotation lifetime");
        this.jdbc = jdbc; this.clock = clock; this.lifetimeSeconds = lifetimeSeconds;
        this.rotationLifetimeSeconds = rotationLifetimeSeconds; this.audit = audit;
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public Issued issuePending(String tenant, String device, String registration) {
        jdbc.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,FALSE)", tenant, registration, device);
        return issue(tenant, device, registration, false);
    }

    /** Only before administrator activation, under registration mutex. Does not resurrect revoked scopes. */
    @Transactional(propagation = Propagation.MANDATORY)
    public Issued replacePending(String tenant, String device, String registration) {
        var rows = jdbc.query("SELECT active,revoked_at FROM device_credential_scopes WHERE tenant_id=? AND device_id=? AND registration_id=? FOR UPDATE",
            (row, index) -> !row.getBoolean("active") && row.getObject("revoked_at") == null, tenant, device, registration);
        if (rows.size() != 1 || !rows.get(0)) throw new DomainException(HttpStatus.CONFLICT, "ENROLLMENT_UNAVAILABLE");
        jdbc.update("UPDATE device_credentials SET revoked_at=? WHERE tenant_id=? AND registration_id=? AND revoked_at IS NULL",
            clock.millis(), tenant, registration);
        return issue(tenant, device, registration, false);
    }

    private Issued issue(String tenant, String device, String registration, boolean active) {
        String token = SecretMaterial.token(); String id = UUID.randomUUID().toString();
        long expires = clock.instant().plusSeconds(lifetimeSeconds).toEpochMilli();
        jdbc.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,?,?,?)",
            id, tenant, device, registration, SecretMaterial.hash(token), active, clock.millis(), expires);
        return new Issued(id, token, expires, null);
    }

    @Override public OAuth2AuthenticatedPrincipal introspect(String token) {
        if (token == null || !token.matches("[A-Za-z0-9_-]{43}")) throw new BadOpaqueTokenException("Invalid device credential");
        var identities = jdbc.query("SELECT c.id,c.tenant_id,c.device_id,c.registration_id,c.active FROM device_credentials c "
                + "JOIN device_credential_scopes s ON s.tenant_id=c.tenant_id AND s.registration_id=c.registration_id AND s.device_id=c.device_id "
                + "LEFT JOIN device_credential_rotations r ON r.new_id=c.id "
                + "WHERE c.token_hash=? AND c.revoked_at IS NULL AND c.expires_at>? AND s.active=TRUE AND s.revoked_at IS NULL "
                + "AND (c.active=TRUE OR (r.confirmed_at IS NULL AND r.cancelled_at IS NULL AND r.expires_at>?))",
            (row, index) -> new Authenticated(new DeviceContext(row.getString("tenant_id"), row.getString("device_id"),
                row.getString("registration_id"), row.getString("id")), row.getBoolean("active")),
            SecretMaterial.hash(token), clock.millis(), clock.millis());
        if (identities.size() != 1) throw new BadOpaqueTokenException("Invalid device credential");
        var identity = identities.get(0).context();
        List<GrantedAuthority> authorities = identities.get(0).active()
            ? List.of(new SimpleGrantedAuthority("SCOPE_device:operate"), new SimpleGrantedAuthority("SCOPE_device:credential-activate"))
            : List.of(new SimpleGrantedAuthority("SCOPE_device:credential-activate"));
        return new DefaultOAuth2AuthenticatedPrincipal("device:" + identity.registrationId(),
            Map.of("tenantId", identity.tenantId(), "deviceId", identity.deviceId(), "registrationId", identity.registrationId(),
                "credentialId", identity.credentialId(), "sub", "device:" + identity.registrationId()),
            authorities);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void activate(String tenant, String registration) {
        var scopes = jdbc.queryForList("SELECT active,revoked_at FROM device_credential_scopes WHERE tenant_id=? AND registration_id=? FOR UPDATE",
            tenant, registration);
        if (scopes.size() != 1 || scopes.get(0).get("revoked_at") != null) throw DomainException.denied();
        int changed = jdbc.update("UPDATE device_credentials SET active=TRUE WHERE tenant_id=? AND registration_id=? AND revoked_at IS NULL AND expires_at>?",
            tenant, registration, clock.millis());
        if (changed != 1) throw new DomainException(HttpStatus.CONFLICT, "DEVICE_CREDENTIAL_UNAVAILABLE");
        jdbc.update("UPDATE device_credential_scopes SET active=TRUE WHERE tenant_id=? AND registration_id=?", tenant, registration);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void revoke(String tenant, String registration) {
        jdbc.queryForList("SELECT registration_id FROM device_credential_scopes WHERE tenant_id=? AND registration_id=? FOR UPDATE", tenant, registration);
        jdbc.update("UPDATE device_credential_scopes SET active=FALSE,revoked_at=? WHERE tenant_id=? AND registration_id=? AND revoked_at IS NULL",
            clock.millis(), tenant, registration);
        jdbc.update("UPDATE device_credentials SET active=FALSE,revoked_at=? WHERE tenant_id=? AND registration_id=? AND revoked_at IS NULL",
            clock.millis(), tenant, registration);
    }

    /** Recheck after authenticating: revocation or rotation can happen before the business transaction. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireActive(DeviceContext identity) {
        requireScope(identity);
        var rows = jdbc.queryForList("SELECT id FROM device_credentials WHERE id=? AND tenant_id=? AND device_id=? AND registration_id=? "
            + "AND active=TRUE AND revoked_at IS NULL AND expires_at>? FOR UPDATE", identity.credentialId(), identity.tenantId(),
            identity.deviceId(), identity.registrationId(), clock.millis());
        if (rows.size() != 1) throw new DomainException(HttpStatus.UNAUTHORIZED, "DEVICE_CREDENTIAL_REVOKED");
    }

    private void requireScope(DeviceContext identity) {
        var rows = jdbc.queryForList("SELECT registration_id FROM device_credential_scopes WHERE tenant_id=? AND device_id=? AND registration_id=? "
            + "AND active=TRUE AND revoked_at IS NULL FOR UPDATE", identity.tenantId(), identity.deviceId(), identity.registrationId());
        if (rows.size() != 1) throw new DomainException(HttpStatus.UNAUTHORIZED, "DEVICE_CREDENTIAL_REVOKED");
    }

    /** Stage a secret without disabling the current one. Only explicit activation commits the change. */
    @Transactional(timeout = 10)
    public Issued rotate(DeviceContext identity) {
        requireActive(identity);
        var previous = jdbc.queryForList("SELECT new_id,expires_at,cancelled_at FROM device_credential_rotations WHERE parent_id=? FOR UPDATE", identity.credentialId());
        if (!previous.isEmpty()) {
            var existing = previous.get(0);
            if (existing.get("cancelled_at") == null && ((Number) existing.get("expires_at")).longValue() > clock.millis())
                throw new DomainException(HttpStatus.CONFLICT, "ROTATION_IN_PROGRESS");
            jdbc.update("UPDATE device_credentials SET active=FALSE,revoked_at=? WHERE id=? AND revoked_at IS NULL", clock.millis(), existing.get("new_id"));
        }
        var next = issue(identity.tenantId(), identity.deviceId(), identity.registrationId(), false);
        long parentExpiry = jdbc.queryForObject("SELECT expires_at FROM device_credentials WHERE id=?", Long.class, identity.credentialId());
        long deadline = Math.min(parentExpiry, clock.instant().plusSeconds(rotationLifetimeSeconds).toEpochMilli());
        if (previous.isEmpty()) {
            jdbc.update("INSERT INTO device_credential_rotations(parent_id,new_id,expires_at) VALUES(?,?,?)", identity.credentialId(), next.credentialId(), deadline);
        } else {
            jdbc.update("UPDATE device_credential_rotations SET new_id=?,expires_at=?,confirmed_at=NULL,cancelled_at=NULL WHERE parent_id=?",
                next.credentialId(), deadline, identity.credentialId());
        }
        audit.record(identity.tenantId(), "device:" + identity.registrationId(), "DEVICE_CREDENTIAL_ROTATION_STAGED", next.credentialId());
        return new Issued(next.credentialId(), next.credential(), next.expiresAt(), deadline);
    }

    @Transactional(timeout = 10)
    public void activateRotation(DeviceContext identity) {
        requireScope(identity);
        var token = jdbc.query("SELECT active,revoked_at,expires_at FROM device_credentials WHERE id=? AND tenant_id=? AND registration_id=? FOR UPDATE",
            (row, index) -> new CredentialState(row.getBoolean("active"), row.getObject("revoked_at") != null, row.getLong("expires_at")),
            identity.credentialId(), identity.tenantId(), identity.registrationId());
        if (token.size() != 1 || token.get(0).revoked() || token.get(0).expiresAt() <= clock.millis())
            throw new DomainException(HttpStatus.UNAUTHORIZED, "DEVICE_CREDENTIAL_REVOKED");
        if (token.get(0).active()) return;
        var rotations = jdbc.queryForList("SELECT parent_id,expires_at,confirmed_at,cancelled_at FROM device_credential_rotations WHERE new_id=? FOR UPDATE", identity.credentialId());
        if (rotations.size() != 1 || rotations.get(0).get("confirmed_at") != null || rotations.get(0).get("cancelled_at") != null
                || ((Number) rotations.get(0).get("expires_at")).longValue() <= clock.millis())
            throw new DomainException(HttpStatus.CONFLICT, "ROTATION_UNAVAILABLE");
        String parentId = rotations.get(0).get("parent_id").toString();
        requireActive(new DeviceContext(identity.tenantId(), identity.deviceId(), identity.registrationId(), parentId));
        jdbc.update("UPDATE device_credentials SET active=FALSE,revoked_at=? WHERE id=?", clock.millis(), parentId);
        jdbc.update("UPDATE device_credentials SET active=TRUE WHERE id=?", identity.credentialId());
        jdbc.update("UPDATE device_credential_rotations SET confirmed_at=? WHERE new_id=?", clock.millis(), identity.credentialId());
        audit.record(identity.tenantId(), "device:" + identity.registrationId(), "DEVICE_CREDENTIAL_ROTATION_CONFIRMED", identity.credentialId());
    }

    @Transactional(timeout = 10)
    public void cancelRotation(DeviceContext identity) {
        requireActive(identity);
        var rows = jdbc.queryForList("SELECT new_id FROM device_credential_rotations WHERE parent_id=? AND confirmed_at IS NULL AND cancelled_at IS NULL FOR UPDATE",
            identity.credentialId());
        if (rows.isEmpty()) return;
        String newId = rows.get(0).get("new_id").toString();
        jdbc.update("UPDATE device_credentials SET active=FALSE,revoked_at=? WHERE id=?", clock.millis(), newId);
        jdbc.update("UPDATE device_credential_rotations SET cancelled_at=? WHERE parent_id=?", clock.millis(), identity.credentialId());
        audit.record(identity.tenantId(), "device:" + identity.registrationId(), "DEVICE_CREDENTIAL_ROTATION_CANCELLED", newId);
    }

    public record Issued(String credentialId, String credential, long expiresAt, Long activateBefore) {
        @Override public String toString() { return "Issued[credentialId=" + credentialId + ", expiresAt=" + expiresAt + "]"; }
    }
    private record Authenticated(DeviceContext context, boolean active) {}
    private record CredentialState(boolean active, boolean revoked, long expiresAt) {}
}
