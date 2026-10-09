package com.aimanager.lifecycle.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.fleet.*;
import com.aimanager.identity.*;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.lifecycle.*;
import com.aimanager.shared.*;
import com.aimanager.signing.ConfigurationSigner;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.*;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import static com.aimanager.tenant.TenantAccess.Role.*;

/** Revocation, bounded signed command and audit are atomic. No native erasure or EMM result is synthesized. */
@Service
class LifecycleService implements CleanupMaintenance {
    @org.springframework.context.event.EventListener
    @org.springframework.core.annotation.Order(0)
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void ownershipTransferred(com.aimanager.tenant.OwnershipTransferred event) {
        int changed = jdbc.update("UPDATE deprovision_previews SET expires_at=? WHERE tenant_id=? AND actor_key=? AND operation_id IS NULL AND expires_at>?",
            event.occurredAt(), event.tenantId(), event.formerOwnerActorKey(), event.occurredAt());
        if (changed > 0) audit.record(event.tenantId(), "system:ownership", "EXIT_PREVIEWS_OWNERSHIP_INVALIDATED", event.tenantId());
    }
    @org.springframework.context.event.EventListener
    @org.springframework.core.annotation.Order(0)
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public void memberAccessChanged(com.aimanager.tenant.MembershipAccessChanged event) {
        int changed=jdbc.update("UPDATE deprovision_previews SET expires_at=? WHERE tenant_id=? AND actor_key=? AND operation_id IS NULL AND expires_at>?",
            event.occurredAt(),event.tenantId(),event.actorKey(),event.occurredAt());
        if(changed>0)audit.record(event.tenantId(),"system:membership","EXIT_PREVIEWS_ACCESS_INVALIDATED",event.actorKey());
    }
    private static final List<String> CONSEQUENCES = List.of("REVOKE_REMOTE_BUSINESS_CREDENTIALS", "INVALIDATE_ACCESS_REQUESTS",
        "REQUEST_OWN_AGENT_CACHE_AND_CREDENTIAL_CLEANUP", "REMOVE_REGISTRATION_KEY_AFTER_ACK");
    private static final List<String> LIMITATIONS = List.of("LOCAL_ERASURE_UNVERIFIED", "NO_SYSTEM_UNMANAGE", "NO_DEVICE_WIPE",
        "NO_OTHER_APP_DATA_REMOVAL", "NO_CLOUD_HISTORY_DELETION", "CACHED_COMMAND_CANNOT_BE_RECALLED_OFFLINE");
    private final JdbcTemplate jdbc;
    private final TenantAccess access;
    private final RecentAuthentication recent;
    private final FleetPolicyAccess fleet;
    private final FleetAdministration administration;
    private final RegistrationKeys keys;
    private final ConfigurationSigner signer;
    private final IdempotencyService idempotency;
    private final AuditService audit;
    private final ObjectMapper mapper;
    private final Clock clock;
    private final long previewSeconds;
    private final long cleanupSeconds;
    LifecycleService(JdbcTemplate jdbc, TenantAccess access, RecentAuthentication recent, FleetPolicyAccess fleet,
        FleetAdministration administration, RegistrationKeys keys, ConfigurationSigner signer, IdempotencyService idempotency,
        AuditService audit, ObjectMapper mapper, Clock clock,
        @Value("${manager.lifecycle.preview-lifetime-seconds:300}") long previewSeconds,
        @Value("${manager.lifecycle.cleanup-lifetime-seconds:86400}") long cleanupSeconds) {
        if (previewSeconds < 30 || previewSeconds > 900 || cleanupSeconds < 300 || cleanupSeconds > 604800)
            throw new IllegalArgumentException("Invalid device cleanup lifetimes");
        this.jdbc = jdbc; this.access = access; this.recent = recent; this.fleet = fleet; this.administration = administration;
        this.keys = keys; this.signer = signer; this.idempotency = idempotency; this.audit = audit; this.mapper = mapper;
        this.clock = clock; this.previewSeconds = previewSeconds; this.cleanupSeconds = cleanupSeconds;
    }
    private void adult(String tenant, Jwt actor) {
        access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN); recent.require(actor);
    }
    private void requireKey(String tenant, Device device) {
        if (device.state() == Device.State.AWAITING_CONFIRMATION || !"BYOD".equals(device.managementMode()))
            throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "DEPROVISION_ACTION_UNSUPPORTED");
        try {
            CleanupKey.read(keys.key(tenant, device.id(), device.registrationId()), device.keyThumbprint());
        } catch (Exception failure) { throw new DomainException(HttpStatus.CONFLICT, "REGISTRATION_KEY_UNAVAILABLE"); }
    }
    @Transactional(timeout = 10)
    public DeprovisionPreview preview(String tenant, Jwt actor, String deviceId, LifecycleController.Action action, String etag) {
        adult(tenant, actor);
        if (action != LifecycleController.Action.AGENT_UNENROLL)
            throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "DEPROVISION_ACTION_UNSUPPORTED");
        var device = fleet.snapshot(tenant, actor.getSubject(), deviceId, true).device();
        ResourceVersions.check(ResourceVersions.require(etag), device.version()); requireKey(tenant, device);
        String id = UUID.randomUUID().toString(); long expires = clock.instant().plusSeconds(previewSeconds).toEpochMilli();
        String hash = SecretMaterial.hash(encode(Map.of("tenantId", tenant, "previewId", id, "deviceId", deviceId,
            "registrationId", device.registrationId(), "deviceVersion", device.version(), "actorKey", ActorKeys.key(actor.getSubject()),
            "expiresAt", expires, "action", action.name(), "consequences", CONSEQUENCES, "limitations", LIMITATIONS)));
        jdbc.update("INSERT INTO deprovision_previews(tenant_id,id,device_id,registration_id,device_version,actor_key,preview_hash,expires_at) VALUES(?,?,?,?,?,?,?,?)",
            tenant, id, deviceId, device.registrationId(), device.version(), ActorKeys.key(actor.getSubject()), hash, expires);
        audit.record(tenant, actor.getSubject(), "DEVICE_EXIT_PREVIEWED", deviceId);
        return new DeprovisionPreview(id, deviceId, device.registrationId(), device.version(), action.name(), CONSEQUENCES, LIMITATIONS, hash, expires);
    }
    @Transactional(timeout = 10)
    public DeprovisionOperation start(String tenant, Jwt actor, String deviceId, LifecycleController.Confirm input, String etag, String key) {
        adult(tenant, actor); long expected = ResourceVersions.require(etag); requireIdempotency(key);
        // Journal replay still requires current authorization and step-up, but returns the original response snapshot.
        return idempotency.execute(tenant, actor.getSubject(), "device-exit:" + deviceId, key,
            Map.of("previewId", input.previewId(), "previewHash", input.previewHash(), "deviceVersion", expected), DeprovisionOperation.class, () -> {
                signer.requireConfigured();
                var device = fleet.snapshot(tenant, actor.getSubject(), deviceId, true).device();
                ResourceVersions.check(expected, device.version()); requireKey(tenant, device);
                var previews = jdbc.queryForList("SELECT * FROM deprovision_previews WHERE tenant_id=? AND id=? FOR UPDATE", tenant, input.previewId());
                if (previews.isEmpty()) throw DomainException.denied(); var preview = previews.get(0);
                if (!deviceId.equals(preview.get("device_id")) || !device.registrationId().equals(preview.get("registration_id"))
                    || !ActorKeys.key(actor.getSubject()).equals(preview.get("actor_key")) || !input.previewHash().equals(preview.get("preview_hash")))
                    throw DomainException.denied();
                if (((Number) preview.get("expires_at")).longValue() <= clock.millis() || preview.get("operation_id") != null)
                    throw new DomainException(HttpStatus.CONFLICT, "DEPROVISION_PREVIEW_UNAVAILABLE");
                ResourceVersions.check(((Number) preview.get("device_version")).longValue(), device.version());
                seedHead(tenant, device); String previous = head(tenant, device.id(), device.registrationId(), true);
                if (previous != null) {
                    var old = reconcile(row(tenant, previous, true));
                    if (!Set.of("CLEANUP_EXPIRED", "CLEANUP_CANCELLED").contains(old.state()))
                        throw new DomainException(HttpStatus.CONFLICT, "CLEANUP_OPERATION_EXISTS");
                }
                String id = UUID.randomUUID().toString(), command = UUID.randomUUID().toString();
                long issued = clock.millis(), deadline = clock.instant().plusSeconds(cleanupSeconds).toEpochMilli();
                var payload = new TreeMap<String, Object>();
                payload.put("schemaVersion", 1); payload.put("purpose", "AGENT_CLEANUP"); payload.put("tenantId", tenant);
                payload.put("deviceId", deviceId); payload.put("registrationId", device.registrationId()); payload.put("keyThumbprint", device.keyThumbprint());
                payload.put("operationId", id); payload.put("commandId", command); payload.put("issuedAt", issued); payload.put("notAfter", deadline);
                payload.put("scope", "OWN_AGENT_DATA_ONLY"); payload.put("actions", List.of("CLEAR_POLICY_CACHE", "CLEAR_USAGE_CACHE", "CLEAR_BUSINESS_CREDENTIALS"));
                payload.put("keyRemoval", "AFTER_SERVER_ACK");
                String compact = signer.signCleanup(encode(payload));
                administration.revokeRegistration(tenant, actor, deviceId, device.registrationId(), expected);
                jdbc.update("INSERT INTO deprovision_operations(tenant_id,id,device_id,registration_id,command_id,key_thumbprint,compact_jws,command_hash,state,local_evidence,issued_at,absolute_not_after,updated_at) "
                    + "VALUES(?,?,?,?,?,?,?,?,'WAITING_FOR_AGENT','NONE',?,?,?)", tenant, id, deviceId, device.registrationId(), command, device.keyThumbprint(),
                    compact, SecretMaterial.hash(compact), issued, deadline, issued);
                jdbc.update("UPDATE deprovision_heads SET operation_id=? WHERE tenant_id=? AND device_id=? AND registration_id=?", id, tenant, deviceId, device.registrationId());
                jdbc.update("UPDATE deprovision_previews SET operation_id=? WHERE tenant_id=? AND id=?", id, tenant, input.previewId());
                audit.record(tenant, actor.getSubject(), "DEVICE_EXIT_CONFIRMED", id);
                return row(tenant, id, false).view();
            });
    }
    @Transactional(timeout = 10)
    public DeprovisionOperation get(String tenant, String actor, String device, String operation) {
        access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
        var result = row(tenant, operation, true); requireDevice(result, device); return reconcile(result).view();
    }
    @Transactional(timeout = 10)
    public ItemPage<DeprovisionOperation> list(String tenant, String actor, String device, int limit, String cursor) {
        access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR); ItemPage.validate(limit, cursor);
        fleet.snapshot(tenant, actor, device, false);
        var ids = jdbc.queryForList("SELECT id FROM deprovision_operations WHERE tenant_id=? AND device_id=? AND id>? ORDER BY id LIMIT ?",
            String.class, tenant, device, cursor == null ? "" : cursor, limit + 1);
        var results = ids.stream().map(id -> reconcile(row(tenant, id, true)).view()).toList();
        return ItemPage.from(results, limit, DeprovisionOperation::id);
    }
    @Transactional(timeout = 10)
    public DeprovisionOperation cancel(String tenant, Jwt actor, String device, String operation, String etag, String key) {
        adult(tenant, actor); long expected = ResourceVersions.require(etag); requireIdempotency(key);
        return idempotency.execute(tenant, actor.getSubject(), "cleanup-cancel:" + operation, key, Map.of("version", expected, "deviceId", device),
            DeprovisionOperation.class, () -> {
                var initial = row(tenant, operation, false); requireDevice(initial, device);
                String current = head(tenant, device, initial.registration(), true);
                var result = reconcile(row(tenant, operation, true)); ResourceVersions.check(expected, result.version());
                if (!operation.equals(current) || Set.of("CLEANUP_REPORTED", "CLEANUP_EXPIRED").contains(result.state()))
                    throw new DomainException(HttpStatus.CONFLICT, "CLEANUP_NOT_CANCELLABLE");
                if (!"CLEANUP_CANCELLED".equals(result.state())) {
                    update(result, "CLEANUP_CANCELLED", result.evidence(), "ADMIN_CANCELLED");
                    audit.record(tenant, actor.getSubject(), "DEVICE_CLEANUP_CANCELLED", operation);
                }
                return row(tenant, operation, false).view();
            });
    }
    private void seedHead(String tenant, Device device) {
        try { jdbc.update("INSERT INTO deprovision_heads(tenant_id,device_id,registration_id) VALUES(?,?,?)", tenant, device.id(), device.registrationId()); }
        catch (DuplicateKeyException alreadyPresent) { /* Current locking read serializes this registration. */ }
    }
    private String head(String tenant, String device, String registration, boolean lock) {
        var heads = jdbc.query("SELECT operation_id FROM deprovision_heads WHERE tenant_id=? AND device_id=? AND registration_id=?" + (lock ? " FOR UPDATE" : ""),
            (row, index) -> row.getString("operation_id"), tenant, device, registration);
        if (heads.isEmpty()) throw DomainException.denied(); return heads.get(0);
    }
    /** Read proof may omit operation ID so a revoked device can discover its narrowly scoped cleanup task. */
    Row authenticationTarget(String tenant, String device, String registration, String operation) {
        String current = head(tenant, device, registration, false);
        if (current == null || (operation != null && !operation.equals(current))) throw DomainException.denied();
        var target = row(tenant, current, false);
        if (!device.equals(target.device()) || !registration.equals(target.registration())) throw DomainException.denied();
        requireAvailable(target); return target;
    }
    private Row lockCleanup(CleanupContext context, String action) {
        if (!action.equals(context.action()) || context.proofExpiresAt() <= clock.millis()) throw DomainException.denied();
        String current = head(context.tenant(), context.device(), context.registration(), true);
        if (!context.operation().equals(current)) throw DomainException.denied();
        var target = row(context.tenant(), current, true);
        if (!context.device().equals(target.device()) || !context.registration().equals(target.registration())
            || !context.thumbprint().equals(target.thumbprint())) throw DomainException.denied();
        requireAvailable(target); return target;
    }
    private void requireAvailable(Row target) {
        if (target.deadline() <= clock.millis() || Set.of("CLEANUP_CANCELLED", "CLEANUP_EXPIRED").contains(target.state())) throw DomainException.denied();
    }
    @Transactional(timeout = 10)
    public CleanupController.Command command(CleanupContext context) {
        var target = lockCleanup(context, "READ");
        if (target.servedAt() == null) {
            jdbc.update("UPDATE deprovision_operations SET served_at=?,state='COMMAND_SERVED',version=version+1,updated_at=? WHERE tenant_id=? AND id=?",
                clock.millis(), clock.millis(), target.tenant(), target.id());
            audit.record(target.tenant(), "device:" + target.registration(), "CLEANUP_COMMAND_SERVED", target.id());
        }
        return new CleanupController.Command(target.id(), target.command(), target.deadline(), target.compact());
    }
    @Transactional(timeout = 10)
    public Map<String, Object> verificationKeys(CleanupContext context) {
        lockCleanup(context, "READ"); return signer.publicKeys();
    }
    @Transactional(timeout = 10)
    public DeprovisionOperation receipt(CleanupContext context, CleanupController.Receipt input) {
        var target = lockCleanup(context, "RECEIPT");
        if (!input.commandId().equals(target.command()) || !input.commandHash().equals(target.hash())) throw DomainException.denied();
        String hash = SecretMaterial.hash(encode(input));
        var previous = jdbc.queryForList("SELECT payload_hash,response_json FROM cleanup_receipts WHERE tenant_id=? AND operation_id=? AND receipt_id=?",
            target.tenant(), target.id(), input.receiptId());
        if (!previous.isEmpty()) {
            if (!hash.equals(previous.get(0).get("payload_hash"))) throw new DomainException(HttpStatus.CONFLICT, "CLEANUP_RECEIPT_CONFLICT");
            return decode(previous.get(0).get("response_json").toString());
        }
        if (target.servedAt() == null) throw new DomainException(HttpStatus.CONFLICT, "CLEANUP_COMMAND_NOT_SERVED");
        if ((input.stage() == CleanupController.Stage.FAILED) != (input.reasonCode() != null)) throw DomainException.invalid("INVALID_CLEANUP_REASON");
        String state = target.state(), evidence = target.evidence(), reason = target.reason();
        switch (input.stage()) {
            case AGENT_DATA_CLEARED -> { state = "CLEANUP_REPORTED"; evidence = "DEVICE_REPORT_UNVERIFIED"; reason = null; }
            case FAILED -> {
                if ("CLEANUP_REPORTED".equals(state)) throw new DomainException(HttpStatus.CONFLICT, "CLEANUP_ALREADY_REPORTED");
                state = "CLEANUP_FAILED"; evidence = "DEVICE_REPORT_UNVERIFIED"; reason = input.reasonCode().name();
            }
            case RECEIVED -> { if ("COMMAND_SERVED".equals(state)) state = "COMMAND_RECEIVED"; }
        }
        if (!state.equals(target.state()) || !evidence.equals(target.evidence()) || !Objects.equals(reason, target.reason())) update(target, state, evidence, reason);
        var response = row(target.tenant(), target.id(), false).view();
        jdbc.update("INSERT INTO cleanup_receipts(tenant_id,operation_id,receipt_id,payload_hash,stage,received_at,response_json) VALUES(?,?,?,?,?,?,?)",
            target.tenant(), target.id(), input.receiptId(), hash, input.stage().name(), clock.millis(), encode(response));
        audit.record(target.tenant(), "device:" + target.registration(), "CLEANUP_RECEIPT_" + input.stage().name(), target.id());
        return response;
    }
    private void requireDevice(Row row, String device) { if (!row.device().equals(device)) throw DomainException.denied(); }
    private void requireIdempotency(String key) { if (key == null) throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED"); }
    private Row reconcile(Row target) {
        if (target.deadline() <= clock.millis() && !Set.of("CLEANUP_REPORTED", "CLEANUP_CANCELLED", "CLEANUP_EXPIRED").contains(target.state())) {
            update(target, "CLEANUP_EXPIRED", target.evidence(), "CLEANUP_WINDOW_EXPIRED");
            audit.record(target.tenant(), "system:cleanup", "CLEANUP_WINDOW_EXPIRED", target.id());
            return row(target.tenant(), target.id(), false);
        }
        return target;
    }
    @Override @Transactional(timeout = 10)
    public int expireDue(int limit) {
        if (limit < 1 || limit > 1000) throw DomainException.invalid("INVALID_EXPIRY_BATCH");
        var rows = jdbc.query("SELECT * FROM deprovision_operations WHERE state IN ('WAITING_FOR_AGENT','COMMAND_SERVED','COMMAND_RECEIVED','CLEANUP_FAILED') "
            + "AND absolute_not_after<=? ORDER BY tenant_id,id LIMIT ? FOR UPDATE", (row, index) -> map(row), clock.millis(), limit);
        rows.forEach(this::reconcile); return rows.size();
    }
    private void update(Row target, String state, String evidence, String reason) {
        jdbc.update("UPDATE deprovision_operations SET state=?,local_evidence=?,reason_code=?,updated_at=?,version=version+1 WHERE tenant_id=? AND id=?",
            state, evidence, reason, clock.millis(), target.tenant(), target.id());
    }
    private Row row(String tenant, String id, boolean lock) {
        var rows = jdbc.query("SELECT * FROM deprovision_operations WHERE tenant_id=? AND id=?" + (lock ? " FOR UPDATE" : ""),
            (result, index) -> map(result), tenant, id);
        if (rows.isEmpty()) throw DomainException.denied(); return rows.get(0);
    }
    private Row map(ResultSet row) throws SQLException {
        Number served = (Number) row.getObject("served_at");
        return new Row(row.getString("tenant_id"), row.getString("id"), row.getString("device_id"), row.getString("registration_id"),
            row.getString("command_id"), row.getString("key_thumbprint"), row.getString("compact_jws"), row.getString("command_hash"),
            row.getString("state"), row.getString("local_evidence"), row.getString("reason_code"), row.getLong("issued_at"), row.getLong("absolute_not_after"),
            served == null ? null : served.longValue(), row.getLong("version"));
    }
    private String encode(Object value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Lifecycle serialization failed"); }
    }
    private DeprovisionOperation decode(String json) {
        try { return mapper.readValue(json, DeprovisionOperation.class); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Lifecycle receipt serialization failed"); }
    }
    record Row(String tenant, String id, String device, String registration, String command, String thumbprint, String compact,
        String hash, String state, String evidence, String reason, long issued, long deadline, Long servedAt, long version) {
        DeprovisionOperation view() { return new DeprovisionOperation(id, device, registration, command, "AGENT_UNENROLL", state, "REVOKED", evidence, reason, issued, deadline, version); }
        @Override public String toString() { return "CleanupRow[id=" + id + ", state=" + state + "]"; }
    }
}
