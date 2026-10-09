package com.aimanager.tenant.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.MembershipRevoked;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.TenantAccess.Role;
import java.time.Clock;
import java.util.UUID;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class MembershipService {
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final AuditService audit;
  private final Clock clock;
  private final ApplicationEventPublisher events;
  private final MembershipMutex mutex;
  private final com.aimanager.identity.IdentityProfiles profiles;
  private final com.aimanager.idempotency.IdempotencyService idempotency;
  private final MemberClassScopes classScopes;

  MembershipService(
      JdbcTemplate jdbc,
      TenantAccess access,
      RecentAuthentication recent,
      AuditService audit,
      Clock clock,
      ApplicationEventPublisher events,
      MembershipMutex mutex,
      com.aimanager.identity.IdentityProfiles profiles,
      com.aimanager.idempotency.IdempotencyService idempotency,
      MemberClassScopes classScopes) {
    this.jdbc = jdbc;
    this.access = access;
    this.recent = recent;
    this.audit = audit;
    this.clock = clock;
    this.events = events;
    this.mutex = mutex;
    this.profiles = profiles;
    this.idempotency = idempotency;
    this.classScopes = classScopes;
  }

  @Transactional(timeout = 10)
  public Invitation invite(
      String tenantId,
      Jwt actor,
      String recipientEmail,
      Role role,
      String subjectId,
      java.util.List<String> inputClasses) {
    mutex.lock(tenantId);
    var grant = access.requireWriteRole(tenantId, actor.getSubject(), OWNER, ORG_ADMIN);
    recent.require(actor);
    var classes = classScopes.normalize(inputClasses);
    validateGrant(tenantId, grant, role, subjectId, classes);
    String id = UUID.randomUUID().toString();
    String token = InvitationSecrets.issue();
    long expires = clock.instant().plusSeconds(86400).toEpochMilli();
    jdbc.update(
        "INSERT INTO"
            + " member_invitations(id,tenant_id,inviter_actor_id,recipient_email_hash,role,subject_id,token_hash,expires_at)"
            + " VALUES(?,?,?,?,?,?,?,?)",
        id,
        tenantId,
        actor.getSubject(),
        InvitationSecrets.emailHash(recipientEmail),
        role.name(),
        subjectId,
        InvitationSecrets.tokenHash(token),
        expires);
    classScopes.invite(tenantId, id, classes);
    audit.record(tenantId, actor.getSubject(), "MEMBER_INVITED", id);
    return new Invitation(id, token, role, expires);
  }

  private void validateGrant(
      String tenantId,
      TenantAccess.Grant grant,
      Role requested,
      String subjectId,
      java.util.List<String> classes) {
    String kind =
        jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?", String.class, tenantId);
    if (requested == OWNER
        || ("FAMILY".equals(kind) && (requested == ORG_ADMIN || requested == TEACHER))
        || ("ORGANIZATION".equals(kind) && requested == GUARDIAN)) {
      throw DomainException.invalid("ROLE_NOT_APPLICABLE");
    }
    if (requested == ORG_ADMIN && grant.role() != OWNER) throw DomainException.denied();
    if (!classes.isEmpty()) {
      if (requested != TEACHER || subjectId != null)
        throw DomainException.invalid("ROLE_SCOPE_NOT_APPLICABLE");
      classScopes.validate(tenantId, classes);
      return;
    }
    if (requested == CHILD || requested == TEACHER) {
      if (subjectId == null
          || jdbc.queryForList(
                      "SELECT id FROM subjects WHERE tenant_id=? AND id=? AND archived_at IS NULL"
                          + " FOR UPDATE",
                      tenantId,
                      subjectId)
                  .size()
              != 1) throw DomainException.invalid("SUBJECT_SCOPE_REQUIRED");
    } else if (subjectId != null) {
      throw DomainException.invalid("ROLE_SCOPE_NOT_APPLICABLE");
    }
  }

  @Transactional(timeout = 10)
  public Accepted accept(Jwt actor, boolean adult, String token) {
    var lookup =
        jdbc.queryForList(
            "SELECT tenant_id,inviter_actor_id FROM member_invitations WHERE token_hash=?",
            InvitationSecrets.tokenHash(token));
    if (lookup.isEmpty()) throw DomainException.denied();
    String tenant = lookup.get(0).get("tenant_id").toString();
    mutex.lock(tenant);
    mutex.actors(
        tenant,
        java.util.List.of(actor.getSubject(), lookup.get(0).get("inviter_actor_id").toString()));
    var invitations =
        jdbc.query(
            "SELECT * FROM member_invitations WHERE token_hash=? FOR UPDATE",
            (row, index) ->
                new Pending(
                    row.getString("id"),
                    row.getString("tenant_id"),
                    row.getString("inviter_actor_id"),
                    row.getString("recipient_email_hash"),
                    Role.valueOf(row.getString("role")),
                    row.getString("subject_id"),
                    row.getLong("expires_at"),
                    row.getObject("consumed_at") != null,
                    row.getObject("revoked_at") != null),
            InvitationSecrets.tokenHash(token));
    if (invitations.isEmpty()) throw DomainException.denied();
    var invite = invitations.get(0);
    if (invite.consumed() || invite.revoked() || invite.expiresAt() <= clock.millis()) {
      throw new DomainException(HttpStatus.CONFLICT, "INVITATION_UNAVAILABLE");
    }
    String email = actor.getClaimAsString("email");
    if (!Boolean.TRUE.equals(actor.getClaimAsBoolean("email_verified"))
        || email == null
        || !invite.recipientHash().equals(InvitationSecrets.emailHash(email)))
      throw DomainException.denied();
    if (invite.role() != CHILD) {
      if (!adult) throw DomainException.denied();
      recent.require(actor);
    }
    // Permission must still exist at acceptance; a stale invite cannot resurrect a removed
    // administrator.
    var inviter = access.requireWriteRole(invite.tenantId(), invite.inviter(), OWNER, ORG_ADMIN);
    var classes = classScopes.invitation(tenant, invite.id());
    validateGrant(invite.tenantId(), inviter, invite.role(), invite.subjectId(), classes);
    var existing =
        jdbc.queryForList(
            "SELECT role,revoked_at FROM tenant_members WHERE tenant_id=? AND actor_key=? FOR"
                + " UPDATE",
            invite.tenantId(),
            ActorKeys.key(actor.getSubject()));
    if (!existing.isEmpty() && existing.get(0).get("revoked_at") == null) {
      throw new DomainException(HttpStatus.CONFLICT, "MEMBER_ALREADY_EXISTS");
    }
    if (existing.isEmpty()) {
      jdbc.update(
          "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
              + " VALUES(?,?,?,?,?)",
          invite.tenantId(),
          actor.getSubject(),
          ActorKeys.key(actor.getSubject()),
          invite.role().name(),
          invite.subjectId());
    } else {
      jdbc.update(
          "UPDATE tenant_members SET role=?,subject_id=?,revoked_at=NULL,version=version+1 WHERE"
              + " tenant_id=? AND actor_key=?",
          invite.role().name(),
          invite.subjectId(),
          invite.tenantId(),
          ActorKeys.key(actor.getSubject()));
    }
    long version =
        jdbc.queryForObject(
            "SELECT version FROM tenant_members WHERE tenant_id=? AND actor_key=?",
            Long.class,
            tenant,
            ActorKeys.key(actor.getSubject()));
    classScopes.assign(tenant, ActorKeys.key(actor.getSubject()), version, classes);
    jdbc.update(
        "UPDATE member_invitations SET consumed_at=? WHERE id=?", clock.millis(), invite.id());
    audit.record(invite.tenantId(), actor.getSubject(), "MEMBER_JOINED", invite.id());
    profiles.observe(actor);
    return new Accepted(invite.tenantId(), invite.role());
  }

  public MemberAccess memberAccess(String tenant, String actor, String memberKey) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN);
    return readAccess(tenant, memberKey, false);
  }

  @Transactional(timeout = 10)
  public MemberAccess changeAccess(
      String tenant,
      Jwt actor,
      String memberKey,
      Role role,
      String subject,
      java.util.List<String> inputClasses,
      String etag,
      String key) {
    mutex.lock(tenant);
    var target = readAccess(tenant, memberKey, false);
    mutex.actors(tenant, java.util.List.of(actor.getSubject(), target.actorId()));
    var grant = access.requireWriteRole(tenant, actor.getSubject(), OWNER, ORG_ADMIN);
    recent.require(actor);
    var current = readAccess(tenant, memberKey, true);
    if (current.role() == OWNER)
      throw new DomainException(HttpStatus.CONFLICT, "OWNER_TRANSFER_REQUIRED");
    if (current.role() == ORG_ADMIN && grant.role() != OWNER) throw DomainException.denied();
    long expected = com.aimanager.shared.ResourceVersions.require(etag);
    var classes = classScopes.normalize(inputClasses);
    var fingerprint = new java.util.TreeMap<String, Object>();
    fingerprint.put("memberKey", memberKey);
    fingerprint.put("role", role);
    fingerprint.put("subjectId", subject == null ? "" : subject);
    fingerprint.put("version", expected);
    // Preserve fingerprints of requests issued before class scopes were introduced.
    if (!classes.isEmpty()) fingerprint.put("classIds", classes);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "membership.access",
        key,
        fingerprint,
        MemberAccess.class,
        () -> {
          com.aimanager.shared.ResourceVersions.check(expected, current.version());
          validateGrant(tenant, grant, role, subject, classes);
          if ((current.role() == CHILD) != (role == CHILD))
            throw DomainException.invalid("MEMBER_CLASS_CHANGE_REQUIRES_INVITATION");
          if (current.role() == role
              && java.util.Objects.equals(current.subjectId(), subject)
              && current.classIds().equals(classes)) return current;
          jdbc.update(
              "UPDATE tenant_members SET role=?,subject_id=?,version=version+1 WHERE tenant_id=?"
                  + " AND actor_key=?",
              role.name(),
              subject,
              tenant,
              memberKey);
          classScopes.assign(tenant, memberKey, current.version() + 1, classes);
          recordChange(tenant, actor.getSubject(), current, role, subject, classes, "UPDATED");
          events.publishEvent(
              new com.aimanager.tenant.MembershipAccessChanged(
                  tenant, current.actorId(), memberKey, false, clock.millis()));
          return readAccess(tenant, memberKey, true);
        });
  }

  private MemberAccess readAccess(String tenant, String memberKey, boolean lock) {
    return readAccess(tenant, memberKey, lock, false);
  }

  private MemberAccess readAccess(
      String tenant, String memberKey, boolean lock, boolean includeRevoked) {
    if (memberKey == null || !memberKey.matches("[0-9a-f]{64}"))
      throw DomainException.invalid("INVALID_MEMBER_KEY");
    var rows =
        jdbc.query(
            "SELECT m.actor_id,m.role,m.subject_id,m.version,s.class_id FROM tenant_members m LEFT"
                + " JOIN tenant_member_class_scopes s ON s.tenant_id=m.tenant_id AND"
                + " s.actor_key=m.actor_key AND s.member_version=m.version WHERE m.tenant_id=? AND"
                + " m.actor_key=?"
                + (includeRevoked ? "" : " AND m.revoked_at IS NULL")
                + " ORDER BY s.class_id"
                + (lock ? " FOR UPDATE" : ""),
            (r, n) ->
                new MemberAccess(
                    r.getString("actor_id"),
                    memberKey,
                    Role.valueOf(r.getString("role")),
                    r.getString("subject_id"),
                    r.getLong("version"),
                    r.getString("class_id") == null
                        ? java.util.List.of()
                        : java.util.List.of(r.getString("class_id"))),
            tenant,
            memberKey);
    if (rows.isEmpty()) throw DomainException.denied();
    var first = rows.get(0);
    return new MemberAccess(
        first.actorId(),
        memberKey,
        first.role(),
        first.subjectId(),
        first.version(),
        rows.stream().flatMap(r -> r.classIds().stream()).toList());
  }

  @Transactional(timeout = 10)
  public void revokeAccess(String tenant, Jwt actor, String memberKey, String etag, String key) {
    mutex.lock(tenant);
    var target = readAccess(tenant, memberKey, false, true);
    mutex.actors(tenant, java.util.List.of(actor.getSubject(), target.actorId()));
    var grant = access.requireWriteRole(tenant, actor.getSubject(), OWNER, ORG_ADMIN);
    recent.require(actor);
    var current = readAccess(tenant, memberKey, true, true);
    if (current.role() == OWNER)
      throw new DomainException(HttpStatus.CONFLICT, "OWNER_TRANSFER_REQUIRED");
    if (current.role() == ORG_ADMIN && grant.role() != OWNER) throw DomainException.denied();
    long expected = com.aimanager.shared.ResourceVersions.require(etag);
    idempotency.execute(
        tenant,
        actor.getSubject(),
        "membership.revoke",
        key,
        java.util.Map.of("memberKey", memberKey, "version", expected),
        Boolean.class,
        () -> {
          com.aimanager.shared.ResourceVersions.check(expected, current.version());
          revoke(tenant, actor, current.actorId());
          return true;
        });
  }

  private void recordChange(
      String tenant,
      String actor,
      MemberAccess previous,
      Role role,
      String subject,
      java.util.List<String> classes,
      String type) {
    String id = UUID.randomUUID().toString();
    jdbc.update(
        "INSERT INTO"
            + " membership_access_changes(tenant_id,id,member_key,change_type,previous_role,previous_subject_id,role,subject_id,member_version,changed_by_actor_id,occurred_at,previous_class_ids_json,class_ids_json)"
            + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
        tenant,
        id,
        previous.memberKey(),
        type,
        previous.role().name(),
        previous.subjectId(),
        role == null ? null : role.name(),
        subject,
        previous.version() + 1,
        actor,
        clock.millis(),
        classScopes.json(previous.classIds()),
        classScopes.json(classes));
    audit.record(
        tenant,
        actor,
        "REVOKED".equals(type) ? "MEMBERSHIP_REVOKED" : "MEMBERSHIP_ACCESS_CHANGED",
        id);
  }

  public com.aimanager.shared.ItemPage<AccessChange> accessHistory(
      String tenant, String actor, String memberKey, int limit, String cursor) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN);
    com.aimanager.shared.ItemPage.validate(limit, cursor);
    if (memberKey == null || !memberKey.matches("[0-9a-f]{64}"))
      throw DomainException.invalid("INVALID_MEMBER_KEY");
    if (jdbc.queryForObject(
            "SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND actor_key=?",
            Integer.class,
            tenant,
            memberKey)
        != 1) throw DomainException.denied();
    long before = Long.MAX_VALUE;
    if (cursor != null) {
      var found =
          jdbc.queryForList(
              "SELECT member_version FROM membership_access_changes WHERE tenant_id=? AND"
                  + " member_key=? AND id=?",
              Long.class,
              tenant,
              memberKey,
              cursor);
      if (found.isEmpty()) throw DomainException.invalid("INVALID_CURSOR");
      before = found.get(0);
    }
    var rows =
        jdbc.query(
            "SELECT * FROM membership_access_changes WHERE tenant_id=? AND member_key=? AND"
                + " member_version<? ORDER BY member_version DESC LIMIT ?",
            (r, n) ->
                new AccessChange(
                    r.getString("id"),
                    r.getString("change_type"),
                    r.getString("previous_role"),
                    r.getString("previous_subject_id"),
                    r.getString("role"),
                    r.getString("subject_id"),
                    r.getLong("member_version"),
                    r.getString("changed_by_actor_id"),
                    r.getLong("occurred_at"),
                    classScopes.parse(r.getString("previous_class_ids_json")),
                    classScopes.parse(r.getString("class_ids_json"))),
            tenant,
            memberKey,
            before,
            limit + 1);
    return com.aimanager.shared.ItemPage.from(rows, limit, AccessChange::id);
  }

  @Transactional(timeout = 10)
  public void revoke(String tenantId, Jwt actor, String memberActor) {
    mutex.lock(tenantId);
    mutex.actors(tenantId, java.util.List.of(actor.getSubject(), memberActor));
    var grant = access.requireWriteRole(tenantId, actor.getSubject(), OWNER, ORG_ADMIN);
    recent.require(actor);
    var members =
        jdbc.query(
            "SELECT role FROM tenant_members WHERE tenant_id=? AND actor_key=? AND revoked_at IS"
                + " NULL FOR UPDATE",
            (row, index) -> Role.valueOf(row.getString("role")),
            tenantId,
            ActorKeys.key(memberActor));
    if (members.isEmpty()) throw DomainException.denied();
    if (members.get(0) == OWNER)
      throw new DomainException(HttpStatus.CONFLICT, "OWNER_TRANSFER_REQUIRED");
    if (members.get(0) == ORG_ADMIN && grant.role() != OWNER) throw DomainException.denied();
    var previous = readAccess(tenantId, ActorKeys.key(memberActor), true);
    jdbc.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP,version=version+1 WHERE tenant_id=?"
            + " AND actor_key=?",
        tenantId,
        ActorKeys.key(memberActor));
    recordChange(
        tenantId, actor.getSubject(), previous, null, null, java.util.List.of(), "REVOKED");
    events.publishEvent(
        new com.aimanager.tenant.MembershipAccessChanged(
            tenantId, memberActor, ActorKeys.key(memberActor), true, clock.millis()));
    events.publishEvent(new MembershipRevoked(tenantId, ActorKeys.key(memberActor)));
  }

  /** Cancellation is tenant-scoped and idempotent, without returning the invitation token. */
  @Transactional(timeout = 10)
  public void cancelInvitation(String tenantId, Jwt actor, String invitationId) {
    mutex.lock(tenantId);
    var grant = access.requireWriteRole(tenantId, actor.getSubject(), OWNER, ORG_ADMIN);
    recent.require(actor);
    var roles =
        jdbc.query(
            "SELECT role FROM member_invitations WHERE tenant_id=? AND id=? FOR UPDATE",
            (row, index) -> Role.valueOf(row.getString("role")),
            tenantId,
            invitationId);
    if (roles.isEmpty()) throw DomainException.denied();
    if (roles.get(0) == ORG_ADMIN && grant.role() != OWNER) throw DomainException.denied();
    int changed =
        jdbc.update(
            "UPDATE member_invitations SET revoked_at=? WHERE tenant_id=? AND id=? AND revoked_at"
                + " IS NULL",
            clock.millis(),
            tenantId,
            invitationId);
    if (changed > 0) audit.record(tenantId, actor.getSubject(), "INVITATION_REVOKED", invitationId);
  }

  record Invitation(String id, String token, Role role, long expiresAt) {}

  record MemberAccess(
      String actorId,
      String memberKey,
      Role role,
      String subjectId,
      long version,
      java.util.List<String> classIds) {
    MemberAccess {
      classIds = classIds == null ? java.util.List.of() : java.util.List.copyOf(classIds);
    }
  }

  record AccessChange(
      String id,
      String changeType,
      String previousRole,
      String previousSubjectId,
      String role,
      String subjectId,
      long memberVersion,
      String changedByActorId,
      long occurredAt,
      java.util.List<String> previousClassIds,
      java.util.List<String> classIds) {}

  record Accepted(String tenantId, Role role) {}

  private record Pending(
      String id,
      String tenantId,
      String inviter,
      String recipientHash,
      Role role,
      String subjectId,
      long expiresAt,
      boolean consumed,
      boolean revoked) {}
}
