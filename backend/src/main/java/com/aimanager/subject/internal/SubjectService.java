package com.aimanager.subject.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.subject.Subject;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.subject.SubjectArchived;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.UUID;
import java.util.Map;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import static com.aimanager.tenant.TenantAccess.Role.*;

@Service
class SubjectService implements SubjectAccess {
    private final JdbcTemplate jdbc;
    private final TenantAccess access;
    private final AuditService audit;
    private final Clock clock;
    private final IdempotencyService idempotency;
    private final RecentAuthentication recent;
    private final ApplicationEventPublisher events;
    SubjectService(JdbcTemplate jdbc, TenantAccess access, AuditService audit, Clock clock, IdempotencyService idempotency,
                   RecentAuthentication recent, ApplicationEventPublisher events) {
        this.jdbc = jdbc; this.access = access; this.audit = audit; this.clock = clock; this.idempotency = idempotency;
        this.recent = recent;
        this.events = events;
    }

    @Transactional(timeout = 10)
    public Subject create(String tenantId, String actor, String nickname, Subject.AgeBand ageBand, String key) {
        access.requireWriteRole(tenantId, actor, OWNER, GUARDIAN, ORG_ADMIN);
        return idempotency.execute(tenantId, actor, "subject.create", key,
            Map.of("nickname", nickname, "ageBand", ageBand), Subject.class,
            () -> insert(tenantId, actor, nickname, ageBand));
    }

    private Subject insert(String tenantId, String actor, String nickname, Subject.AgeBand ageBand) {
        var subject = new Subject(UUID.randomUUID().toString(), nickname.strip(), ageBand, 0);
        jdbc.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at,version) VALUES(?,?,?,?,?,?)",
            tenantId, subject.id(), subject.nickname(), ageBand.name(), clock.millis(), 0);
        audit.record(tenantId, actor, "SUBJECT_CREATED", subject.id());
        return subject;
    }

    public ItemPage<Subject> list(String tenantId, String actor, int limit, String cursor) {
        var grant = access.requireRole(tenantId, actor, OWNER, GUARDIAN, ORG_ADMIN, CHILD);
        ItemPage.validate(limit, cursor);
        boolean child = grant.role() == CHILD;
        if (child && grant.subjectId() == null) throw DomainException.denied();
        String sql = "SELECT * FROM subjects WHERE tenant_id=? AND archived_at IS NULL AND id>?"
            + (child ? " AND id=?" : "") + " ORDER BY id LIMIT ?";
        Object[] args = child ? new Object[]{tenantId, cursor == null ? "" : cursor, grant.subjectId(), limit + 1}
            : new Object[]{tenantId, cursor == null ? "" : cursor, limit + 1};
        var rows = jdbc.query(sql, (row, index) -> new Subject(row.getString("id"), row.getString("nickname"),
            Subject.AgeBand.valueOf(row.getString("age_band")), row.getLong("version")), args);
        return ItemPage.from(rows, limit, Subject::id);
    }

    public Subject get(String tenantId, String actor, String subjectId) {
        var grant = access.requireRole(tenantId, actor, OWNER, GUARDIAN, ORG_ADMIN, CHILD);
        if (grant.role() == CHILD && !subjectId.equals(grant.subjectId())) throw DomainException.denied();
        return read(tenantId, subjectId, false);
    }

    private Subject read(String tenantId, String subjectId, boolean lock) {
        var rows = jdbc.query("SELECT id,nickname,age_band,version FROM subjects WHERE tenant_id=? AND id=? AND archived_at IS NULL"
                + (lock ? " FOR UPDATE" : ""),
            (row, index) -> new Subject(row.getString("id"), row.getString("nickname"),
                Subject.AgeBand.valueOf(row.getString("age_band")), row.getLong("version")), tenantId, subjectId);
        // Missing and foreign-tenant object IDs have the same result.
        if (rows.isEmpty()) throw DomainException.denied();
        return rows.get(0);
    }

    @Transactional(timeout = 10)
    public Subject update(String tenantId, String actor, String subjectId, String nickname, Subject.AgeBand ageBand, String ifMatch) {
        access.requireWriteRole(tenantId, actor, OWNER, GUARDIAN, ORG_ADMIN);
        long expected = ResourceVersions.require(ifMatch);
        var existing = read(tenantId, subjectId, true);
        ResourceVersions.check(expected, existing.version());
        jdbc.update("UPDATE subjects SET nickname=?,age_band=?,version=version+1 WHERE tenant_id=? AND id=? AND version=?",
            nickname.strip(), ageBand.name(), tenantId, subjectId, expected);
        audit.record(tenantId, actor, "SUBJECT_UPDATED", subjectId);
        return new Subject(subjectId, nickname.strip(), ageBand, expected + 1);
    }

    /** Archive only hides a profile. Erasure and device deprovisioning are separate audited workflows. */
    @Transactional(timeout = 10)
    public void archive(String tenantId, Jwt actor, String subjectId, String ifMatch) {
        access.requireWriteRole(tenantId, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
        recent.require(actor);
        long expected = ResourceVersions.require(ifMatch);
        var existing = read(tenantId, subjectId, true);
        ResourceVersions.check(expected, existing.version());
        jdbc.update("UPDATE subjects SET archived_at=?,version=version+1 WHERE tenant_id=? AND id=? AND version=?",
            clock.millis(), tenantId, subjectId, expected);
        audit.record(tenantId, actor.getSubject(), "SUBJECT_ARCHIVED", subjectId);
        events.publishEvent(new SubjectArchived(tenantId, subjectId));
    }

    @Override @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public Subject lockActiveForScope(String tenant, String actor, String subject) {
        var grant = access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, CHILD);
        if (grant.role() == CHILD && !subject.equals(grant.subjectId())) throw DomainException.denied();
        return read(tenant, subject, true);
    }
    @Override public boolean active(String tenant, String subject) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT COUNT(*)>0 FROM subjects WHERE tenant_id=? AND id=? AND archived_at IS NULL", Boolean.class, tenant, subject));
    }
}
