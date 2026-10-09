package com.aimanager.tenant.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.OwnershipTransferred;
import com.aimanager.tenant.TenantAccess;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.ArrayList;
import java.util.Map;
import java.util.UUID;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class OwnershipService {
  private final JdbcTemplate jdbc;
  private final MembershipMutex mutex;
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final AuditService audit;
  private final ApplicationEventPublisher events;
  private final Clock clock;

  OwnershipService(
      JdbcTemplate jdbc,
      MembershipMutex mutex,
      TenantAccess access,
      RecentAuthentication recent,
      IdempotencyService idempotency,
      AuditService audit,
      ApplicationEventPublisher events,
      Clock clock) {
    this.jdbc = jdbc;
    this.mutex = mutex;
    this.access = access;
    this.recent = recent;
    this.idempotency = idempotency;
    this.audit = audit;
    this.events = events;
    this.clock = clock;
  }

  @Transactional(timeout = 10)
  public Transfer start(String tenant, Jwt actor, String target, String etag, String key) {
    String head = mutex.lock(tenant);
    Transfer pending = head == null ? null : row(tenant, head);
    lockActors(tenant, actor.getSubject(), target, pending);
    access.requireWriteRole(tenant, actor.getSubject(), OWNER);
    recent.require(actor);
    var workspace = workspace(tenant);
    long expected = ResourceVersions.require(etag);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "ownership.start",
        key,
        Map.of("target", target, "version", expected),
        Transfer.class,
        () -> {
          ResourceVersions.check(expected, workspace.version());
          if (pending != null && "PENDING".equals(reconcile(pending, workspace).state()))
            throw conflict("OWNERSHIP_TRANSFER_PENDING");
          Member source = member(tenant, actor.getSubject()), recipient = member(tenant, target);
          String eligible = "FAMILY".equals(workspace.kind()) ? "GUARDIAN" : "ORG_ADMIN";
          if (recipient == null
              || recipient.revoked()
              || recipient.subject() != null
              || !(eligible.equals(recipient.role()) || "AUDITOR".equals(recipient.role()))
              || target.equals(actor.getSubject()))
            throw DomainException.invalid("OWNERSHIP_TARGET_INELIGIBLE");
          String id = UUID.randomUUID().toString();
          long now = clock.millis(), expires = now + 86400000L;
          jdbc.update(
              "INSERT INTO"
                  + " ownership_transfers(tenant_id,id,source_actor_id,source_actor_key,target_actor_id,target_actor_key,source_member_version,target_member_version,target_role,former_owner_role,tenant_version,state,created_at,expires_at,updated_at)"
                  + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
              tenant,
              id,
              actor.getSubject(),
              ActorKeys.key(actor.getSubject()),
              target,
              ActorKeys.key(target),
              source.version(),
              recipient.version(),
              recipient.role(),
              eligible,
              workspace.version(),
              "PENDING",
              now,
              expires,
              now);
          jdbc.update(
              "UPDATE ownership_heads SET pending_transfer_id=? WHERE tenant_id=?", id, tenant);
          audit.record(tenant, actor.getSubject(), "OWNERSHIP_TRANSFER_PROPOSED", id);
          return row(tenant, id);
        });
  }

  @Transactional(timeout = 10)
  public Transfer act(
      String tenant, String id, Jwt actor, boolean adult, String action, String etag, String key) {
    mutex.lock(tenant);
    var current = row(tenant, id);
    lockActors(tenant, actor.getSubject(), null, current);
    var grant = authorize(tenant, actor.getSubject());
    if ("cancel".equals(action)) {
      if (grant.role() != OWNER || !actor.getSubject().equals(current.sourceActorId()))
        throw DomainException.denied();
    } else if (!actor.getSubject().equals(current.targetActorId())) throw DomainException.denied();
    if ("accept".equals(action) && !adult) throw DomainException.denied();
    recent.require(actor);
    var workspace = workspace(tenant);
    long expected = ResourceVersions.require(etag);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "ownership." + action,
        key,
        Map.of("id", id, "version", expected),
        Transfer.class,
        () -> {
          ResourceVersions.check(expected, current.version());
          var resolved = reconcile(current, workspace);
          if (resolved.version() != current.version()) return resolved;
          String next =
              switch (action) {
                case "accept" -> "ACCEPTED";
                case "decline" -> "DECLINED";
                case "cancel" -> "CANCELLED";
                default -> throw DomainException.invalid("INVALID_ACTION");
              };
          if (next.equals(resolved.state())) return resolved;
          if (!"PENDING".equals(resolved.state())) throw conflict("OWNERSHIP_TRANSFER_UNAVAILABLE");
          if ("accept".equals(action)) {
            Integer owners =
                jdbc.queryForObject(
                    "SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND role='OWNER' AND"
                        + " revoked_at IS NULL",
                    Integer.class,
                    tenant);
            if (owners == null || owners != 1) throw conflict("OWNERSHIP_INVARIANT_FAILED");
            jdbc.update(
                "UPDATE tenant_members SET role=?,version=version+1 WHERE tenant_id=? AND"
                    + " actor_key=?",
                current.formerOwnerRole(),
                tenant,
                ActorKeys.key(current.sourceActorId()));
            jdbc.update(
                "UPDATE tenant_members SET role='OWNER',version=version+1 WHERE tenant_id=? AND"
                    + " actor_key=?",
                tenant,
                ActorKeys.key(current.targetActorId()));
            events.publishEvent(
                new OwnershipTransferred(
                    tenant,
                    current.sourceActorId(),
                    ActorKeys.key(current.sourceActorId()),
                    current.targetActorId(),
                    clock.millis()));
          }
          return transition(current, next, null, actor.getSubject());
        });
  }

  @Transactional(timeout = 10)
  public Transfer get(String tenant, String id, String actor) {
    mutex.lock(tenant);
    var current = row(tenant, id);
    lockActors(tenant, actor, null, current);
    var grant = authorize(tenant, actor);
    visible(grant, actor, current);
    return reconcile(current, workspace(tenant));
  }

  @Transactional(timeout = 10)
  public ItemPage<Transfer> list(String tenant, String actor, int limit, String cursor) {
    ItemPage.validate(limit, cursor);
    String head = mutex.lock(tenant);
    var pending = head == null ? null : row(tenant, head);
    lockActors(tenant, actor, null, pending);
    var grant = authorize(tenant, actor);
    if (pending != null) reconcile(pending, workspace(tenant));
    String filter = grant.role() == OWNER ? "" : " AND (source_actor_key=? OR target_actor_key=?)";
    var args = new ArrayList<Object>();
    args.add(tenant);
    args.add(cursor == null ? "" : cursor);
    if (grant.role() != OWNER) {
      args.add(ActorKeys.key(actor));
      args.add(ActorKeys.key(actor));
    }
    args.add(limit + 1);
    var rows =
        jdbc.query(
            "SELECT * FROM ownership_transfers WHERE tenant_id=? AND id>?"
                + filter
                + " ORDER BY id LIMIT ? FOR UPDATE",
            (r, n) -> map(r),
            args.toArray());
    return ItemPage.from(rows, limit, Transfer::id);
  }

  private TenantAccess.Grant authorize(String tenant, String actor) {
    var grant = access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
    if (grant.subjectId() != null) throw DomainException.denied();
    return grant;
  }

  private void visible(TenantAccess.Grant grant, String actor, Transfer t) {
    if (grant.role() != OWNER
        && !actor.equals(t.sourceActorId())
        && !actor.equals(t.targetActorId())) throw DomainException.denied();
  }

  private void lockActors(String tenant, String actor, String target, Transfer t) {
    var actors = new ArrayList<String>();
    actors.add(actor);
    if (target != null) actors.add(target);
    if (t != null) {
      actors.add(t.sourceActorId());
      actors.add(t.targetActorId());
    }
    mutex.actors(tenant, actors);
  }

  private Transfer reconcile(Transfer t, Workspace w) {
    if (!"PENDING".equals(t.state())) return t;
    if (t.expiresAt() <= clock.millis())
      return transition(t, "EXPIRED", "TIME_EXPIRED", "system:ownership");
    if (t.tenantVersion() != w.version())
      return transition(t, "INVALIDATED", "TENANT_CHANGED", "system:ownership");
    var source = member(t.tenantId(), t.sourceActorId());
    var target = member(t.tenantId(), t.targetActorId());
    if (source == null
        || target == null
        || source.revoked()
        || target.revoked()
        || !"OWNER".equals(source.role())
        || source.version() != t.sourceMemberVersion()
        || target.version() != t.targetMemberVersion()
        || !target.role().equals(t.targetRole())
        || target.subject() != null)
      return transition(t, "INVALIDATED", "MEMBERSHIP_CHANGED", "system:ownership");
    return t;
  }

  private Transfer transition(Transfer t, String state, String reason, String actor) {
    jdbc.update(
        "UPDATE ownership_transfers SET state=?,reason=?,updated_at=?,version=version+1 WHERE"
            + " tenant_id=? AND id=?",
        state,
        reason,
        clock.millis(),
        t.tenantId(),
        t.id());
    jdbc.update(
        "UPDATE ownership_heads SET pending_transfer_id=NULL WHERE tenant_id=? AND"
            + " pending_transfer_id=?",
        t.tenantId(),
        t.id());
    audit.record(t.tenantId(), actor, "OWNERSHIP_TRANSFER_" + state, t.id());
    return row(t.tenantId(), t.id());
  }

  private Workspace workspace(String tenant) {
    // Metadata writers hold the same control row. Avoid an exclusive lock on
    // the FK parent while waiting for independent policy/device transactions.
    // The tenant version tracks metadata; member and transfer versions track ownership.
    return jdbc.queryForObject(
        "SELECT kind,version FROM tenants WHERE id=?",
        (r, n) -> new Workspace(r.getString(1), r.getLong(2)),
        tenant);
  }

  private Member member(String tenant, String actor) {
    var rows =
        jdbc.query(
            "SELECT role,subject_id,version,revoked_at FROM tenant_members WHERE tenant_id=? AND"
                + " actor_key=? FOR UPDATE",
            (r, n) ->
                new Member(r.getString(1), r.getString(2), r.getLong(3), r.getObject(4) != null),
            tenant,
            ActorKeys.key(actor));
    return rows.isEmpty() ? null : rows.get(0);
  }

  private Transfer row(String tenant, String id) {
    var rows =
        jdbc.query(
            "SELECT * FROM ownership_transfers WHERE tenant_id=? AND id=? FOR UPDATE",
            (r, n) -> map(r),
            tenant,
            id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private Transfer map(ResultSet r) throws SQLException {
    return new Transfer(
        r.getString("tenant_id"),
        r.getString("id"),
        r.getString("source_actor_id"),
        r.getString("target_actor_id"),
        r.getLong("source_member_version"),
        r.getLong("target_member_version"),
        r.getString("target_role"),
        r.getString("former_owner_role"),
        r.getLong("tenant_version"),
        r.getString("state"),
        r.getString("reason"),
        r.getLong("created_at"),
        r.getLong("expires_at"),
        r.getLong("updated_at"),
        r.getLong("version"));
  }

  private DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  private record Member(String role, String subject, long version, boolean revoked) {}

  private record Workspace(String kind, long version) {}

  record Transfer(
      String tenantId,
      String id,
      String sourceActorId,
      String targetActorId,
      long sourceMemberVersion,
      long targetMemberVersion,
      String targetRole,
      String formerOwnerRole,
      long tenantVersion,
      String state,
      String reason,
      long createdAt,
      long expiresAt,
      long updatedAt,
      long version) {}
}
