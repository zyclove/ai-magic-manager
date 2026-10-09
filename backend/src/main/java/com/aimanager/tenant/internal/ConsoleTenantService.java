package com.aimanager.tenant.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.Tenant;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.time.DateTimeException;
import java.time.ZoneId;
import java.util.List;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import static com.aimanager.tenant.TenantAccess.Role.*;

@Service
class ConsoleTenantService {
    private final JdbcTemplate jdbc;
    private final TenantAccess access;
    private final AuditService audit;
    private final Clock clock;
    ConsoleTenantService(JdbcTemplate jdbc, TenantAccess access, AuditService audit, Clock clock) {
        this.jdbc=jdbc; this.access=access; this.audit=audit; this.clock=clock;
    }
    public Members members(String tenant, String actor, int limit, String cursor) {
        access.requireRole(tenant, actor, OWNER, ORG_ADMIN);
        if (limit < 1 || limit > 100 || (cursor != null && !cursor.matches("[0-9a-f]{64}"))) throw DomainException.invalid("INVALID_PAGINATION");
        var rows = jdbc.query("SELECT actor_id,actor_key,role,subject_id FROM tenant_members WHERE tenant_id=? AND revoked_at IS NULL AND actor_key>? ORDER BY actor_key LIMIT ?",
            (r,n) -> new Member(r.getString("actor_id"), r.getString("actor_key"), r.getString("role"), r.getString("subject_id")), tenant, cursor == null ? "" : cursor, limit+1);
        boolean more = rows.size() > limit;
        return new Members(List.copyOf(more ? rows.subList(0,limit) : rows), more ? rows.get(limit-1).cursor() : null);
    }
    public ItemPage<InvitationSummary> invitations(String tenant, String actor, int limit, String cursor) {
        access.requireRole(tenant, actor, OWNER, ORG_ADMIN);
        ItemPage.validate(limit,cursor);
        var rows = jdbc.query("SELECT id,role,subject_id,expires_at,consumed_at,revoked_at FROM member_invitations WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?",
            (r,n) -> new InvitationSummary(r.getString("id"),r.getString("role"),r.getString("subject_id"),r.getLong("expires_at"),
                r.getObject("revoked_at") != null ? "CANCELLED" : r.getObject("consumed_at") != null ? "ACCEPTED" : r.getLong("expires_at") <= clock.millis() ? "EXPIRED" : "PENDING"),
            tenant, cursor == null ? "" : cursor, limit+1);
        return ItemPage.from(rows,limit,InvitationSummary::id);
    }
    @Transactional(timeout=10)
    public Tenant update(String tenant, String actor, String name, String zone, String etag) {
        access.requireWriteRole(tenant,actor,OWNER,ORG_ADMIN);
        long expected = ResourceVersions.require(etag);
        try { ZoneId.of(zone); } catch (DateTimeException e) { throw DomainException.invalid("INVALID_TIME_ZONE"); }
        var current = jdbc.queryForObject("SELECT * FROM tenants WHERE id=? FOR UPDATE", (r,n) -> new Tenant(r.getString("id"), r.getString("name"),Tenant.Kind.valueOf(r.getString("kind")),r.getString("time_zone"),r.getLong("version")), tenant);
        ResourceVersions.check(expected,current.version());
        jdbc.update("UPDATE tenants SET name=?,time_zone=?,version=version+1 WHERE id=?",name.strip(),zone,tenant);
        audit.record(tenant,actor,"TENANT_UPDATED",tenant);
        return new Tenant(tenant,name.strip(),current.kind(),zone,current.version()+1);
    }
    record Member(String actorId, String cursor, String role, String subjectId) {}
    record Members(List<Member> items, String nextCursor) {}
    record InvitationSummary(String id, String role, String subjectId, long expiresAt, String state) {}
}
