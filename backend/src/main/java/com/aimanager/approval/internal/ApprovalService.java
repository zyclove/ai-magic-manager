package com.aimanager.approval.internal;

import com.aimanager.approval.AccessRequest;
import com.aimanager.approval.ApprovalMaintenance;
import com.aimanager.audit.AuditService;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.fleet.DeviceRegistrationRevoked;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.policy.PolicyConfigurationRecorded;
import com.aimanager.policy.PolicyExceptionAccess;
import com.aimanager.shared.*;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.MembershipRevoked;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.subject.SubjectArchived;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.event.EventListener;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import static com.aimanager.approval.AccessRequest.State.*;
import static com.aimanager.tenant.TenantAccess.Role.*;

/** Short domain transactions. No network/OS call, and no unlock claim, occurs in the approval transaction. */
@Service
class ApprovalService implements ApprovalMaintenance {
    private final JdbcTemplate jdbc;
    private final TenantAccess access;
    private final DeviceAccess devices;
    private final SubjectAccess subjects;
    private final PolicyExceptionAccess policies;
    private final RecentAuthentication recent;
    private final IdempotencyService idempotency;
    private final AuditService audit;
    private final ObjectMapper mapper;
    private final Clock clock;
    private final long requestTtl;
    private final long cooldown;
    ApprovalService(JdbcTemplate jdbc, TenantAccess access, DeviceAccess devices, SubjectAccess subjects, PolicyExceptionAccess policies,
                    RecentAuthentication recent, IdempotencyService idempotency, AuditService audit, ObjectMapper mapper, Clock clock,
                    @Value("${manager.approval.request-ttl-seconds:1800}") long ttl,
                    @Value("${manager.approval.cooldown-seconds:60}") long cooldown) {
        if (ttl < 60 || ttl > 86400 || cooldown < 1 || cooldown > 3600) throw new IllegalArgumentException("Invalid approval timing");
        this.jdbc = jdbc; this.access = access; this.devices = devices; this.policies = policies; this.recent = recent;
        this.subjects = subjects;
        this.idempotency = idempotency; this.audit = audit; this.mapper = mapper; this.clock = clock;
        this.requestTtl = ttl * 1000; this.cooldown = cooldown * 1000;
    }

    @Transactional(timeout = 10)
    public AccessRequest create(String tenant, String actor, ApprovalController.Create input, String key) {
        access.requireWriteRole(tenant, actor, CHILD);
        devices.requireVisible(tenant, actor, input.deviceId());
        requiredKey(key);
        return idempotency.execute(tenant, actor, "access.request", key, Map.of("input", input), AccessRequest.class, () -> {
            var base = policies.accessWindow(tenant, actor, input.deviceId(), input.policyId(), input.baseVersionId(), input.applicationId(), input.ruleIds());
            var slot = slot(tenant, base);
            if (slot.lastId() != null) {
                var previous = row(tenant, slot.lastId(), true);
                var state = effective(previous).state();
                if (state == PENDING) throw new DomainException(HttpStatus.CONFLICT, "ACCESS_REQUEST_PENDING");
                if (state == APPROVED_PENDING_DELIVERY) throw new DomainException(HttpStatus.CONFLICT, "ACCESS_EXCEPTION_EXISTS");
            }
            if (slot.nextAllowedAt() > clock.millis()) throw new DomainException(HttpStatus.TOO_MANY_REQUESTS, "ACCESS_REQUEST_COOLDOWN");
            String id = UUID.randomUUID().toString(); long now = clock.millis();
            jdbc.update("INSERT INTO access_requests(tenant_id,id,subject_id,device_id,registration_id,policy_id,base_version_id,base_sequence,application_id," 
                + "rule_ids_json,requester_actor_id,requester_actor_key,requested_window_seconds,child_reason,state,request_expires_at,created_at,updated_at) "
                + "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,'PENDING',?,?,?)", tenant, id, base.subjectId(), base.deviceId(), base.registrationId(), base.policyId(),
                base.versionId(), base.sequence(), base.applicationId(), json(base.ruleIds()), actor, ActorKeys.key(actor), input.requestedWindowSeconds(),
                input.reason() == null ? null : input.reason().strip(), now + requestTtl, now, now);
            jdbc.update("UPDATE access_request_slots SET last_request_id=?,next_allowed_at=? WHERE tenant_id=? AND subject_id=? AND registration_id=? AND application_id=?",
                id, now + cooldown, tenant, base.subjectId(), base.registrationId(), base.applicationId());
            audit.record(tenant, actor, "ACCESS_REQUEST_CREATED", id);
            return effective(row(tenant, id, false));
        });
    }
    private Slot slot(String tenant, PolicyExceptionAccess.Baseline base) {
        try {
            jdbc.update("INSERT INTO access_request_slots(tenant_id,subject_id,registration_id,application_id) VALUES(?,?,?,?)",
                tenant, base.subjectId(), base.registrationId(), base.applicationId());
        } catch (DuplicateKeyException existing) { /* The following current lock serializes requests from multiple child identities. */ }
        return jdbc.queryForObject("SELECT last_request_id,next_allowed_at FROM access_request_slots WHERE tenant_id=? AND subject_id=? AND registration_id=? AND application_id=? FOR UPDATE",
            (row, index) -> new Slot(row.getString(1), row.getLong(2)), tenant, base.subjectId(), base.registrationId(), base.applicationId());
    }

    @Transactional(timeout = 10)
    public AccessRequest get(String tenant, String actor, String id) {
        var grant = access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR, CHILD);
        var stored = row(tenant, id, true); visible(grant, stored);
        return reconcile(stored);
    }
    @Transactional(timeout = 10)
    public ItemPage<AccessRequest> list(String tenant, String actor, int limit, String cursor) {
        var grant = access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR, CHILD);
        ItemPage.validate(limit, cursor);
        boolean child = grant.role() == CHILD;
        if (child && grant.subjectId() == null) throw DomainException.denied();
        String sql = "SELECT * FROM access_requests WHERE tenant_id=? AND id>?" + (child ? " AND subject_id=?" : "") + " ORDER BY id LIMIT ?";
        Object[] args = child ? new Object[]{tenant, cursor == null ? "" : cursor, grant.subjectId(), limit + 1}
            : new Object[]{tenant, cursor == null ? "" : cursor, limit + 1};
        var ids = jdbc.query(sql, (row, index) -> row.getString("id"), args);
        var page = ItemPage.from(ids, limit, id -> id);
        return new ItemPage<>(page.items().stream().map(id -> reconcile(row(tenant, id, true))).toList(), page.nextCursor());
    }

    @Transactional(timeout = 10)
    public AccessRequest decide(String tenant, Jwt actor, String id, ApprovalController.Decision input, String etag, String key) {
        access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN); recent.require(actor);
        long expected = ResourceVersions.require(etag); requiredKey(key);
        validateDecision(input);
        return idempotency.execute(tenant, actor.getSubject(), "access.decide", key, Map.of("id", id, "version", expected, "input", input), AccessRequest.class, () -> {
            // Read immutable references before locks; approve then locks policy/device in the publish order.
            var initial = row(tenant, id, false);
            if (input.decision() == ApprovalController.Choice.APPROVE) {
                var r = initial.view();
                var baseline = policies.accessWindow(tenant, actor.getSubject(), r.deviceId(), r.policyId(), r.baseVersionId(), r.applicationId(), r.ruleIds());
                if (!baseline.subjectId().equals(r.subjectId()) || !baseline.registrationId().equals(r.registrationId()))
                    throw new DomainException(HttpStatus.CONFLICT, "ACCESS_TARGET_CHANGED");
            }
            var stored = row(tenant, id, true); ResourceVersions.check(expected, stored.view().version());
            if (effective(stored).state() != PENDING) throw new DomainException(HttpStatus.CONFLICT, "ACCESS_REQUEST_NOT_PENDING");
            var r = stored.view(); long now = clock.millis();
            boolean approve = input.decision() == ApprovalController.Choice.APPROVE;
            if (approve && input.grantedWindowSeconds() > r.requestedWindowSeconds()) throw DomainException.invalid("GRANT_EXCEEDS_REQUEST");
            Long notAfter = approve ? now + input.grantedWindowSeconds() * 1000 : null;
            String reason = input.reasonCode() == null ? null : input.reasonCode().name();
            jdbc.update("INSERT INTO access_request_decisions(tenant_id,request_id,decision,actor_id,granted_window_seconds,absolute_not_after,reason_code,decided_at) VALUES(?,?,?,?,?,?,?,?)",
                tenant, id, input.decision().name(), actor.getSubject(), input.grantedWindowSeconds(), notAfter, reason, now);
            jdbc.update("UPDATE access_requests SET state=?,granted_window_seconds=?,issued_at=?,absolute_not_after=?,approver_actor_id=?,approver_actor_key=?,reason_code=?,version=version+1,updated_at=? WHERE tenant_id=? AND id=?",
                approve ? APPROVED_PENDING_DELIVERY.name() : DENIED.name(), input.grantedWindowSeconds(), approve ? now : null, notAfter,
                approve ? actor.getSubject() : null, approve ? ActorKeys.key(actor.getSubject()) : null, reason, now, tenant, id);
            audit.record(tenant, actor.getSubject(), approve ? "ACCESS_REQUEST_APPROVED" : "ACCESS_REQUEST_DENIED", id);
            return effective(row(tenant, id, false));
        });
    }
    private void validateDecision(ApprovalController.Decision input) {
        if (input.decision() == ApprovalController.Choice.APPROVE && (input.grantedWindowSeconds() == null || input.reasonCode() != null))
            throw DomainException.invalid("INVALID_APPROVAL_FIELDS");
        if (input.decision() == ApprovalController.Choice.DENY && input.grantedWindowSeconds() != null)
            throw DomainException.invalid("INVALID_DENIAL_FIELDS");
    }
    @Transactional(timeout = 10)
    public AccessRequest cancel(String tenant, String actor, String id, String etag, String key) {
        var grant = access.requireWriteRole(tenant, actor, CHILD);
        long expected = ResourceVersions.require(etag); requiredKey(key);
        var initial = row(tenant, id, false); visible(grant, initial);
        if (!ActorKeys.key(actor).equals(initial.requesterKey())) throw DomainException.denied();
        return idempotency.execute(tenant, actor, "access.cancel", key, Map.of("id", id, "version", expected), AccessRequest.class, () -> {
            var current = row(tenant, id, true); ResourceVersions.check(expected, current.view().version());
            if (effective(current).state() != PENDING) throw new DomainException(HttpStatus.CONFLICT, "ACCESS_REQUEST_NOT_PENDING");
            transition(tenant, actor, id, CANCELLED, "CHILD_CANCELLED", "ACCESS_REQUEST_CANCELLED");
            return effective(row(tenant, id, false));
        });
    }
    @Transactional(timeout = 10)
    public AccessRequest revoke(String tenant, Jwt actor, String id, String etag, String key) {
        access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN); recent.require(actor);
        long expected = ResourceVersions.require(etag); requiredKey(key);
        return idempotency.execute(tenant, actor.getSubject(), "access.revoke", key, Map.of("id", id, "version", expected), AccessRequest.class, () -> {
            var current = row(tenant, id, true); ResourceVersions.check(expected, current.view().version());
            // A currently authorized adult may revoke even if the original approving adult has since lost access.
            if (current.view().state() != APPROVED_PENDING_DELIVERY || expired(current.view()))
                throw new DomainException(HttpStatus.CONFLICT, "ACCESS_EXCEPTION_NOT_REVOCABLE");
            transition(tenant, actor.getSubject(), id, REVOKED, "ADMIN_REVOKED", "ACCESS_EXCEPTION_REVOKED");
            return effective(row(tenant, id, false));
        });
    }
    private void transition(String tenant, String actor, String id, AccessRequest.State state, String reason, String action) {
        jdbc.update("UPDATE access_requests SET state=?,reason_code=?,version=version+1,updated_at=? WHERE tenant_id=? AND id=?", state.name(), reason, clock.millis(), tenant, id);
        audit.record(tenant, actor, action, id);
    }

    /** Same transaction as the new policy version; delayed duplicate source events cannot invalidate newer requests. */
    @EventListener @Transactional(propagation = Propagation.MANDATORY)
    public void baselineChanged(PolicyConfigurationRecorded event) {
        var rows = jdbc.query("SELECT * FROM access_requests WHERE tenant_id=? AND policy_id=? AND base_sequence<? AND state IN ('PENDING','APPROVED_PENDING_DELIVERY') ORDER BY id FOR UPDATE",
            (row, index) -> map(row), event.tenantId(), event.version().policyId(), event.version().sequence());
        for (var stored : rows) transition(event.tenantId(), "system:policy", stored.view().id(),
            stored.view().state() == PENDING ? INVALIDATED : REVOKED, "BASELINE_CHANGED", "ACCESS_BASELINE_INVALIDATED");
    }
    @EventListener @Transactional(propagation = Propagation.MANDATORY)
    public void deviceRevoked(DeviceRegistrationRevoked event) {
        invalidate(event.tenantId(), "device_id=? AND registration_id=?", new Object[]{event.deviceId(), event.registrationId()}, "DEVICE_REGISTRATION_INACTIVE");
    }
    @EventListener @Transactional(propagation = Propagation.MANDATORY)
    public void subjectArchived(SubjectArchived event) {
        invalidate(event.tenantId(), "subject_id=?", new Object[]{event.subjectId()}, "SUBJECT_ARCHIVED");
    }
    @EventListener @Transactional(propagation = Propagation.MANDATORY)
    public void memberRevoked(MembershipRevoked event) {
        var rows = jdbc.query("SELECT * FROM access_requests WHERE tenant_id=? AND (requester_actor_key=? OR approver_actor_key=?) "
            + "AND state IN ('PENDING','APPROVED_PENDING_DELIVERY') ORDER BY id FOR UPDATE", (row, index) -> map(row), event.tenantId(), event.actorKey(), event.actorKey());
        for (var stored : rows) {
            boolean approvedByMember = stored.approver() != null && ActorKeys.key(stored.approver()).equals(event.actorKey());
            transition(event.tenantId(), "system:membership", stored.view().id(), stored.view().state() == PENDING ? INVALIDATED : REVOKED,
                approvedByMember ? "APPROVER_SCOPE_LOST" : "REQUESTER_SCOPE_LOST", "ACCESS_MEMBERSHIP_INVALIDATED");
        }
    }
    @Override @Transactional(timeout = 10)
    public int expireDue(int limit) {
        if (limit < 1 || limit > 1000) throw DomainException.invalid("INVALID_EXPIRY_BATCH");
        long now = clock.millis();
        var rows = jdbc.query("SELECT * FROM access_requests WHERE (state='PENDING' AND request_expires_at<=?) "
            + "OR (state='APPROVED_PENDING_DELIVERY' AND absolute_not_after<=?) ORDER BY tenant_id,id LIMIT ? FOR UPDATE",
            (row, index) -> map(row), now, now, limit);
        for (var stored : rows) transition(stored.tenant(), "system:approval", stored.view().id(), EXPIRED, "TIME_EXPIRED", "ACCESS_REQUEST_EXPIRED");
        return rows.size();
    }
    private void invalidate(String tenant, String predicate, Object[] parameters, String reason) {
        var args = new ArrayList<Object>(); args.add(tenant); args.addAll(Arrays.asList(parameters));
        var rows = jdbc.query("SELECT * FROM access_requests WHERE tenant_id=? AND " + predicate
            + " AND state IN ('PENDING','APPROVED_PENDING_DELIVERY') ORDER BY id FOR UPDATE", (row, index) -> map(row), args.toArray());
        for (var stored : rows) transition(tenant, "system:lifecycle", stored.view().id(),
            stored.view().state() == PENDING ? INVALIDATED : REVOKED, reason, "ACCESS_LIFECYCLE_INVALIDATED");
    }

    /** Lazy system reconciliation changes the stored revision; a time-changing view must not reuse its strong ETag. */
    private AccessRequest reconcile(Stored stored) {
        var current = effective(stored);
        if (current.state() != stored.view().state()) {
            transition(stored.tenant(), "system:approval", current.id(), current.state(), current.reasonCode(),
                current.state() == EXPIRED ? "ACCESS_REQUEST_EXPIRED" : "ACCESS_AUTHORITY_INVALIDATED");
            return row(stored.tenant(), current.id(), false).view();
        }
        return current;
    }

    private void requiredKey(String key) { if (key == null) throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED"); }
    private void visible(TenantAccess.Grant grant, Stored row) {
        if (grant.role() == CHILD && !row.view().subjectId().equals(grant.subjectId())) throw DomainException.denied();
    }
    private Stored row(String tenant, String id, boolean lock) {
        var rows = jdbc.query("SELECT * FROM access_requests WHERE tenant_id=? AND id=?" + (lock ? " FOR UPDATE" : ""), (row, index) -> map(row), tenant, id);
        if (rows.isEmpty()) throw DomainException.denied();
        return rows.get(0);
    }
    private Stored map(ResultSet row) throws SQLException {
        List<String> rules;
        try { rules = mapper.readValue(row.getString("rule_ids_json"), new TypeReference<List<String>>() {}); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Approval rule references cannot be read"); }
        var view = new AccessRequest(row.getString("id"), row.getString("subject_id"), row.getString("device_id"), row.getString("registration_id"),
            row.getString("policy_id"), row.getString("base_version_id"), row.getString("application_id"), rules, row.getLong("requested_window_seconds"),
            row.getString("child_reason"), AccessRequest.State.valueOf(row.getString("state")), row.getLong("request_expires_at"), nullable(row, "granted_window_seconds"),
            nullable(row, "issued_at"), nullable(row, "absolute_not_after"), row.getString("reason_code"), "NOT_ENFORCED", row.getLong("version"), row.getLong("created_at"));
        return new Stored(row.getString("tenant_id"), row.getString("requester_actor_id"), row.getString("requester_actor_key"), row.getString("approver_actor_id"), view);
    }
    private Long nullable(ResultSet row, String column) throws SQLException { Number n = (Number) row.getObject(column); return n == null ? null : n.longValue(); }
    private boolean expired(AccessRequest r) {
        return (r.state() == PENDING && r.requestExpiresAt() <= clock.millis())
            || (r.state() == APPROVED_PENDING_DELIVERY && r.absoluteNotAfter() != null && r.absoluteNotAfter() <= clock.millis());
    }
    private AccessRequest effective(Stored stored) {
        var r = stored.view();
        if (expired(r)) return withState(r, EXPIRED, "TIME_EXPIRED");
        if (r.state() == PENDING || r.state() == APPROVED_PENDING_DELIVERY) {
            if (!subjects.active(stored.tenant(), r.subjectId())) return withState(r, r.state() == PENDING ? INVALIDATED : REVOKED, "SUBJECT_ARCHIVED");
            if (!devices.registrationActive(stored.tenant(), r.deviceId(), r.registrationId(), r.subjectId()))
                return withState(r, r.state() == PENDING ? INVALIDATED : REVOKED, "DEVICE_REGISTRATION_INACTIVE");
            try {
                var requester = access.requireRole(stored.tenant(), stored.requester(), CHILD);
                if (!r.subjectId().equals(requester.subjectId())) return withState(r, r.state() == PENDING ? INVALIDATED : REVOKED, "REQUESTER_SCOPE_LOST");
            } catch (DomainException lost) { return withState(r, r.state() == PENDING ? INVALIDATED : REVOKED, "REQUESTER_SCOPE_LOST"); }
        }
        if (r.state() == APPROVED_PENDING_DELIVERY) {
            try { access.requireRole(stored.tenant(), stored.approver(), OWNER, GUARDIAN, ORG_ADMIN); }
            catch (DomainException revoked) { return withState(r, REVOKED, "APPROVER_SCOPE_LOST"); }
        }
        return r;
    }
    private AccessRequest withState(AccessRequest r, AccessRequest.State state, String reason) {
        return new AccessRequest(r.id(), r.subjectId(), r.deviceId(), r.registrationId(), r.policyId(), r.baseVersionId(), r.applicationId(), r.ruleIds(),
            r.requestedWindowSeconds(), r.reason(), state, r.requestExpiresAt(), r.grantedWindowSeconds(), r.issuedAt(), r.absoluteNotAfter(), reason,
            r.executionState(), r.version(), r.createdAt());
    }
    private String json(Object value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Approval references cannot be encoded"); }
    }
    private record Slot(String lastId, long nextAllowedAt) {}
    private record Stored(String tenant, String requester, String requesterKey, String approver, AccessRequest view) {}
}
