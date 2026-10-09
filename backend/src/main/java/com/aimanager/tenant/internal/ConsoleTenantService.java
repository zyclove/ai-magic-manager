package com.aimanager.tenant.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

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

@Service
class ConsoleTenantService {
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final AuditService audit;
  private final Clock clock;
  private final MembershipMutex mutex;
  private final com.aimanager.identity.IdentityProfiles profiles;
  private final MemberClassScopes classScopes;

  ConsoleTenantService(
      JdbcTemplate jdbc,
      TenantAccess access,
      AuditService audit,
      Clock clock,
      MembershipMutex mutex,
      com.aimanager.identity.IdentityProfiles profiles,
      MemberClassScopes classScopes) {
    this.jdbc = jdbc;
    this.access = access;
    this.audit = audit;
    this.clock = clock;
    this.mutex = mutex;
    this.profiles = profiles;
    this.classScopes = classScopes;
  }

  public Members members(String tenant, String actor, int limit, String cursor) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN);
    if (limit < 1 || limit > 100 || (cursor != null && !cursor.matches("[0-9a-f]{64}")))
      throw DomainException.invalid("INVALID_PAGINATION");
    var rows =
        jdbc.query(
            "SELECT m.actor_id,m.actor_key,m.role,m.subject_id,m.version,s.nickname,s.archived_at"
                + " FROM tenant_members m LEFT JOIN subjects s ON s.tenant_id=m.tenant_id AND"
                + " s.id=m.subject_id WHERE m.tenant_id=? AND m.revoked_at IS NULL AND"
                + " m.actor_key>? ORDER BY m.actor_key LIMIT ?",
            (r, n) ->
                new MemberRow(
                    r.getString("actor_id"),
                    r.getString("actor_key"),
                    r.getString("role"),
                    r.getString("subject_id"),
                    r.getLong("version"),
                    r.getString("nickname"),
                    r.getObject("archived_at") != null),
            tenant,
            cursor == null ? "" : cursor,
            limit + 1);
    boolean more = rows.size() > limit;
    var page = more ? rows.subList(0, limit) : rows;
    var evidence = profiles.find(page.stream().map(MemberRow::actorId).toList());
    var members =
        page.stream()
            .map(
                r -> {
                  var profile = evidence.get(r.actorId());
                  return new Member(
                      r.actorId(),
                      r.cursor(),
                      r.role(),
                      r.subjectId(),
                      r.version(),
                      r.subjectName(),
                      r.subjectArchived(),
                      profile == null ? null : profile.displayName(),
                      profile == null || "CHILD".equals(r.role()) ? null : profile.verifiedEmail(),
                      profile == null ? null : profile.updatedAt(),
                      classScopes.assigned(tenant, r.cursor(), r.version()));
                })
            .toList();
    return new Members(members, more ? rows.get(limit - 1).cursor() : null);
  }

  public ItemPage<InvitationSummary> invitations(
      String tenant, String actor, int limit, String cursor) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN);
    ItemPage.validate(limit, cursor);
    var rows =
        jdbc.query(
            "SELECT id,role,subject_id,expires_at,consumed_at,revoked_at FROM member_invitations"
                + " WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?",
            (r, n) ->
                new InvitationSummary(
                    r.getString("id"),
                    r.getString("role"),
                    r.getString("subject_id"),
                    r.getLong("expires_at"),
                    r.getObject("revoked_at") != null
                        ? "CANCELLED"
                        : r.getObject("consumed_at") != null
                            ? "ACCEPTED"
                            : r.getLong("expires_at") <= clock.millis() ? "EXPIRED" : "PENDING",
                    classScopes.invitation(tenant, r.getString("id"))),
            tenant,
            cursor == null ? "" : cursor,
            limit + 1);
    return ItemPage.from(rows, limit, InvitationSummary::id);
  }

  @Transactional(timeout = 10)
  public Tenant update(String tenant, String actor, String name, String zone, String etag) {
    mutex.lock(tenant);
    access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
    long expected = ResourceVersions.require(etag);
    try {
      ZoneId.of(zone);
    } catch (DateTimeException e) {
      throw DomainException.invalid("INVALID_TIME_ZONE");
    }
    var current =
        jdbc.queryForObject(
            "SELECT * FROM tenants WHERE id=? FOR UPDATE",
            (r, n) ->
                new Tenant(
                    r.getString("id"),
                    r.getString("name"),
                    Tenant.Kind.valueOf(r.getString("kind")),
                    r.getString("time_zone"),
                    r.getLong("version")),
            tenant);
    ResourceVersions.check(expected, current.version());
    jdbc.update(
        "UPDATE tenants SET name=?,time_zone=?,version=version+1 WHERE id=?",
        name.strip(),
        zone,
        tenant);
    audit.record(tenant, actor, "TENANT_UPDATED", tenant);
    return new Tenant(tenant, name.strip(), current.kind(), zone, current.version() + 1);
  }

  private record MemberRow(
      String actorId,
      String cursor,
      String role,
      String subjectId,
      long version,
      String subjectName,
      boolean subjectArchived) {}

  record Member(
      String actorId,
      String cursor,
      String role,
      String subjectId,
      long version,
      String subjectName,
      boolean subjectArchived,
      String displayName,
      String verifiedEmail,
      Long profileUpdatedAt,
      List<String> classIds) {}

  record Members(List<Member> items, String nextCursor) {}

  record InvitationSummary(
      String id,
      String role,
      String subjectId,
      long expiresAt,
      String state,
      List<String> classIds) {}
}
