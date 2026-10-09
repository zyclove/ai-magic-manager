package com.aimanager.fleet.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.DeviceRegistrationRevoked;
import com.aimanager.fleet.FleetAdministration;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import static com.aimanager.tenant.TenantAccess.Role.*;

/** All enrollment transitions serialize in the database, including multi-replica claims and confirmations. */
@Service
class EnrollmentService implements FleetAdministration {
    private final JdbcTemplate jdbc;
    private final TenantAccess access;
    private final RecentAuthentication recent;
    private final EnrollmentProof proof;
    private final DeviceCredentials credentials;
    private final AuditService audit;
    private final FleetReads reads;
    private final Clock clock;
    private final ApplicationEventPublisher events;
    private final long lifetimeSeconds;
    private final int maxPairingFailures;
    private final int maxRecoveryAttempts;
    EnrollmentService(JdbcTemplate jdbc, TenantAccess access, RecentAuthentication recent, EnrollmentProof proof,
                      DeviceCredentials credentials, AuditService audit, FleetReads reads, Clock clock, ApplicationEventPublisher events,
                      @Value("${manager.devices.enrollment-lifetime-seconds:900}") long lifetimeSeconds,
                      @Value("${manager.devices.max-pairing-failures:5}") int maxPairingFailures,
                      @Value("${manager.devices.max-recovery-attempts:3}") int maxRecoveryAttempts) {
        if (lifetimeSeconds < 60 || lifetimeSeconds > 3600 || maxPairingFailures < 1 || maxPairingFailures > 10)
            throw new IllegalArgumentException("Invalid enrollment configuration");
        if (maxRecoveryAttempts < 1 || maxRecoveryAttempts > 5) throw new IllegalArgumentException("Invalid recovery limit");
        this.jdbc = jdbc; this.access = access; this.recent = recent; this.proof = proof;
        this.credentials = credentials; this.audit = audit; this.reads = reads; this.clock = clock;
        this.events = events;
        this.lifetimeSeconds = lifetimeSeconds; this.maxPairingFailures = maxPairingFailures;
        this.maxRecoveryAttempts = maxRecoveryAttempts;
    }

    @Transactional(timeout = 10)
    public Ticket create(String tenant, Jwt actor, String subject, Device.Mode mode, Device.Platform platform) {
        access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
        recent.require(actor); requireSubject(tenant, subject);
        // No EMM adapter is configured yet: ordinary pairing cannot produce system privileges.
        if (mode != Device.Mode.BYOD) throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "CAPABILITY_UNSUPPORTED");
        String id = UUID.randomUUID().toString(), token = SecretMaterial.token();
        long expires = clock.instant().plusSeconds(lifetimeSeconds).toEpochMilli();
        jdbc.update("INSERT INTO device_enrollments(tenant_id,id,subject_id,creator_actor_id,platform,requested_mode,token_hash,state,created_at,expires_at) "
            + "VALUES(?,?,?,?,?,?,?,?,?,?)", tenant, id, subject, actor.getSubject(), platform.name(), mode.name(),
            SecretMaterial.hash(token), "PENDING_CLAIM", clock.millis(), expires);
        audit.record(tenant, actor.getSubject(), "ENROLLMENT_CREATED", id);
        return new Ticket(id, token, expires, "PENDING_CLAIM");
    }

    private void requireSubject(String tenant, String subject) {
        var rows = jdbc.queryForList("SELECT id FROM subjects WHERE tenant_id=? AND id=? AND archived_at IS NULL FOR UPDATE", tenant, subject);
        if (rows.size() != 1) throw DomainException.denied();
    }

    private Pending read(String id, boolean lock) {
        var rows = jdbc.query("SELECT * FROM device_enrollments WHERE id=?" + (lock ? " FOR UPDATE" : ""),
            (row, index) -> new Pending(row.getString("tenant_id"), row.getString("id"), row.getString("subject_id"),
                row.getString("creator_actor_id"), row.getString("platform"), row.getString("state"), row.getString("token_hash"),
                row.getLong("expires_at"), row.getString("device_id"), row.getString("pairing_hash"), row.getInt("pairing_failures")), id);
        if (rows.isEmpty()) throw DomainException.denied();
        return rows.get(0);
    }

    private void requireState(Pending pending, String state) {
        if (!state.equals(pending.state()) || pending.expiresAt() <= clock.millis())
            throw new DomainException(HttpStatus.CONFLICT, "ENROLLMENT_UNAVAILABLE");
    }

    @Transactional(timeout = 10)
    public Claimed claim(FleetController.Claim input) {
        var pending = read(input.enrollmentId(), false);
        if (!pending.tokenHash().equals(SecretMaterial.hash(input.token()))) throw DomainException.denied();
        var verified = proof.verify(input.enrollmentId(), input.token(), input.publicKeyJwk(), input.proof());
        access.requireWriteRole(pending.tenant(), pending.creator(), OWNER, GUARDIAN, ORG_ADMIN);
        requireSubject(pending.tenant(), pending.subject());
        pending = read(pending.id(), true); requireState(pending, "PENDING_CLAIM");
        consumeProof(pending, "ai-manager:enrollment-claim", verified.proofId());
        String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString(), pairing = SecretMaterial.pairingCode();
        jdbc.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,?,?,?,?,?,?)", pending.tenant(), device, pending.subject(), registration, input.displayName().strip(), pending.platform(),
            input.osVersion(), "AWAITING_CONFIRMATION", verified.publicKeyJwk(), verified.thumbprint(), clock.millis());
        var issued = credentials.issuePending(pending.tenant(), device, registration);
        jdbc.update("UPDATE device_enrollments SET state=?,device_id=?,pairing_hash=? WHERE tenant_id=? AND id=?",
            "AWAITING_CONFIRMATION", device, SecretMaterial.hash(pairing), pending.tenant(), pending.id());
        audit.record(pending.tenant(), "enrollment:" + pending.id(), "DEVICE_CLAIMED", device);
        return new Claimed(device, registration, issued.credential(), issued.expiresAt(), pairing, pending.expiresAt(), "AWAITING_CONFIRMATION");
    }

    private void consumeProof(Pending pending, String purpose, String proofId) {
        try {
            jdbc.update("INSERT INTO enrollment_proofs(tenant_id,enrollment_id,purpose,jti_hash,consumed_at) VALUES(?,?,?,?,?)",
                pending.tenant(), pending.id(), purpose, SecretMaterial.hash(proofId), clock.millis());
        } catch (DuplicateKeyException duplicate) {
            throw new DomainException(HttpStatus.CONFLICT, "ENROLLMENT_PROOF_ALREADY_USED");
        }
    }

    /** Recover a lost response without reopening enrollment or weakening key, time and pairing limits. */
    @Transactional(timeout = 10)
    public Claimed recover(FleetController.Recover input) {
        var pending = read(input.enrollmentId(), false);
        if (!pending.tokenHash().equals(SecretMaterial.hash(input.token()))) throw DomainException.denied();
        var verified = proof.verify(input.enrollmentId(), input.token(), input.publicKeyJwk(), input.proof(), "ai-manager:enrollment-recover");
        access.requireWriteRole(pending.tenant(), pending.creator(), OWNER, GUARDIAN, ORG_ADMIN);
        requireSubject(pending.tenant(), pending.subject()); pending = read(pending.id(), true);
        requireState(pending, "AWAITING_CONFIRMATION");
        var devices = jdbc.queryForList("SELECT registration_id,key_thumbprint,state FROM devices WHERE tenant_id=? AND id=? FOR UPDATE",
            pending.tenant(), pending.deviceId());
        if (devices.size() != 1 || !verified.thumbprint().equals(devices.get(0).get("key_thumbprint"))) throw DomainException.denied();
        if (!"AWAITING_CONFIRMATION".equals(devices.get(0).get("state"))) throw new DomainException(HttpStatus.CONFLICT, "ENROLLMENT_UNAVAILABLE");
        int attempts = jdbc.queryForObject("SELECT recovery_attempts FROM device_enrollments WHERE tenant_id=? AND id=?", Integer.class,
            pending.tenant(), pending.id());
        if (attempts >= maxRecoveryAttempts) throw new DomainException(HttpStatus.CONFLICT, "ENROLLMENT_RECOVERY_LIMIT_REACHED");
        consumeProof(pending, "ai-manager:enrollment-recover", verified.proofId());
        String registration = devices.get(0).get("registration_id").toString(), pairing = SecretMaterial.pairingCode();
        var issued = credentials.replacePending(pending.tenant(), pending.deviceId(), registration);
        jdbc.update("UPDATE device_enrollments SET pairing_hash=?,recovery_attempts=recovery_attempts+1 WHERE tenant_id=? AND id=?",
            SecretMaterial.hash(pairing), pending.tenant(), pending.id());
        audit.record(pending.tenant(), "device:" + registration, "ENROLLMENT_RESPONSE_RECOVERED", pending.deviceId());
        return new Claimed(pending.deviceId(), registration, issued.credential(), issued.expiresAt(), pairing, pending.expiresAt(), "AWAITING_CONFIRMATION");
    }

    /** Return failure as a value so the transaction commits the attempt counter before HTTP rejection. */
    @Transactional(timeout = 10)
    public Confirmation confirm(String tenant, Jwt actor, String id, String pairingCode) {
        access.requireRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN); recent.require(actor);
        var pending = read(id, false);
        if (!tenant.equals(pending.tenant())) throw DomainException.denied();
        access.requireWriteRoles(tenant, java.util.List.of(actor.getSubject(), pending.creator()), OWNER, GUARDIAN, ORG_ADMIN);
        requireSubject(tenant, pending.subject()); pending = read(id, true); requireState(pending, "AWAITING_CONFIRMATION");
        if (!pending.pairingHash().equals(SecretMaterial.hash(pairingCode.strip().toUpperCase(java.util.Locale.ROOT)))) {
            int failures = pending.failures() + 1;
            jdbc.update("UPDATE device_enrollments SET pairing_failures=?,state=? WHERE tenant_id=? AND id=?", failures,
                failures >= maxPairingFailures ? "LOCKED" : "AWAITING_CONFIRMATION", tenant, id);
            if (failures >= maxPairingFailures) {
                revokeDevice(tenant, pending.deviceId(), actor.getSubject());
                audit.record(tenant, actor.getSubject(), "PAIRING_LOCKED", id);
            }
            return new Confirmation(null, false);
        }
        var device = reads.rawDevice(tenant, pending.deviceId());
        credentials.activate(tenant, device.registrationId());
        jdbc.update("UPDATE devices SET state='ACTIVE',version=version+1 WHERE tenant_id=? AND id=?", tenant, device.id());
        jdbc.update("UPDATE device_enrollments SET state='CONFIRMED',pairing_hash=NULL WHERE tenant_id=? AND id=?", tenant, id);
        audit.record(tenant, actor.getSubject(), "DEVICE_CONFIRMED", device.id());
        return new Confirmation(reads.rawDevice(tenant, device.id()), true);
    }

    @Transactional(timeout = 10)
    public void cancel(String tenant, Jwt actor, String id) {
        access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN); recent.require(actor);
        var pending = read(id, true);
        if (!tenant.equals(pending.tenant())) throw DomainException.denied();
        if ("CANCELLED".equals(pending.state())) return;
        if (!"PENDING_CLAIM".equals(pending.state()) && !"AWAITING_CONFIRMATION".equals(pending.state()))
            throw new DomainException(HttpStatus.CONFLICT, "ENROLLMENT_UNAVAILABLE");
        if (pending.deviceId() != null) revokeDevice(tenant, pending.deviceId(), actor.getSubject());
        jdbc.update("UPDATE device_enrollments SET state='CANCELLED',pairing_hash=NULL WHERE tenant_id=? AND id=?", tenant, id);
        audit.record(tenant, actor.getSubject(), "ENROLLMENT_CANCELLED", id);
    }

    @Transactional(timeout = 10)
    public void revoke(String tenant, Jwt actor, String id) {
        access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN); recent.require(actor);
        revokeDevice(tenant, id, actor.getSubject());
    }

    @Override @Transactional(timeout = 10)
    public void revokeRegistration(String tenant, Jwt actor, String id, String registration, long expectedVersion) {
        access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN); recent.require(actor);
        var current = reads.snapshot(tenant, actor.getSubject(), id, true).device();
        ResourceVersions.check(expectedVersion, current.version());
        if (!registration.equals(current.registrationId())) throw new DomainException(HttpStatus.CONFLICT, "REGISTRATION_CHANGED");
        if (current.state() == Device.State.AWAITING_CONFIRMATION || !"BYOD".equals(current.managementMode()))
            throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "DEPROVISION_ACTION_UNSUPPORTED");
        revokeDevice(tenant, id, actor.getSubject());
    }

    private void revokeDevice(String tenant, String id, String actor) {
        var rows = jdbc.queryForList("SELECT registration_id,state FROM devices WHERE tenant_id=? AND id=? FOR UPDATE", tenant, id);
        if (rows.size() != 1) throw DomainException.denied();
        if ("REVOKED".equals(rows.get(0).get("state"))) return;
        String registration = rows.get(0).get("registration_id").toString();
        credentials.revoke(tenant, registration);
        jdbc.update("UPDATE devices SET state='REVOKED',version=version+1 WHERE tenant_id=? AND id=?", tenant, id);
        audit.record(tenant, actor, "DEVICE_CREDENTIALS_REVOKED", id);
        events.publishEvent(new DeviceRegistrationRevoked(tenant, id, registration));
    }

    record Ticket(String id, String token, long expiresAt, String state) {
        @Override public String toString() { return "Ticket[id=" + id + ", state=" + state + "]"; }
    }
    record Claimed(String deviceId, String registrationId, String credential, long expiresAt, String pairingCode, long confirmBefore, String state) {
        @Override public String toString() { return "Claimed[deviceId=" + deviceId + ", state=" + state + "]"; }
    }
    record Confirmation(Device device, boolean accepted) {}
    private record Pending(String tenant, String id, String subject, String creator, String platform, String state,
                           String tokenHash, long expiresAt, String deviceId, String pairingHash, int failures) {}
}
