package com.aimanager.tenant.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.TenantAccess.Role;
import java.time.Clock;
import java.util.List;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Preview grants no access. Successful acceptance records a non-secret reference and membership epoch. */
@Service
class InvitationAcceptanceService {
  private static final String OPERATION="invitation.accept";
  private final JdbcTemplate db;
  private final MembershipMutex mutex;
  private final MembershipService members;
  private final MemberClassScopes classes;
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final Clock clock;
  InvitationAcceptanceService(JdbcTemplate db,MembershipMutex mutex,MembershipService members,
      MemberClassScopes classes,TenantAccess access,RecentAuthentication recent,IdempotencyService idempotency,Clock clock) {
    this.db=db;this.mutex=mutex;this.members=members;this.classes=classes;this.access=access;
    this.recent=recent;this.idempotency=idempotency;this.clock=clock;
  }

  @Transactional(timeout=10)
  public Preview preview(Jwt actor,boolean adult,String token) {
    var invite=byToken(actor.getSubject(),token);
    recipient(invite,actor,adult,false);
    if(invite.consumed()||invite.revoked()||invite.expiresAt()<=clock.millis())
      throw new DomainException(HttpStatus.CONFLICT,"INVITATION_UNAVAILABLE");
    var issuer=access.requireWriteRole(invite.tenantId(),invite.inviter(),OWNER,ORG_ADMIN);
    var scope=classes.invitation(invite.tenantId(),invite.id());
    members.validateGrant(invite.tenantId(),issuer,invite.role(),invite.subjectId(),scope);
    if(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND actor_key=? AND revoked_at IS NULL",
        Integer.class,invite.tenantId(),ActorKeys.key(actor.getSubject()))!=0)
      throw new DomainException(HttpStatus.CONFLICT,"MEMBER_ALREADY_EXISTS");
    var workspace=db.queryForMap("SELECT name,kind FROM tenants WHERE id=?",invite.tenantId());
    String subjectName=invite.subjectId()==null?null:db.queryForObject(
        "SELECT nickname FROM subjects WHERE tenant_id=? AND id=?",String.class,invite.tenantId(),invite.subjectId());
    var classNames=db.query("SELECT c.id,c.name FROM organization_classes c JOIN invitation_class_scopes s ON s.tenant_id=c.tenant_id AND s.class_id=c.id WHERE s.tenant_id=? AND s.invitation_id=? ORDER BY c.id",
        (r,n)->new ScopeClass(r.getString("id"),r.getString("name")),invite.tenantId(),invite.id());
    if(classNames.size()!=scope.size()) throw new IllegalStateException("Invitation scope projection is inconsistent");
    return new Preview(invite.id(),invite.tenantId(),workspace.get("name").toString(),workspace.get("kind").toString(),
        invite.role(),invite.subjectId(),subjectName,classNames,invite.expiresAt(),invite.role()!=CHILD);
  }

  @Transactional(timeout=10)
  public Result accept(Jwt actor,boolean adult,String key,String invitationId,String token) {
    requireUuid(key);requireUuid(invitationId);
    var invite=byToken(actor.getSubject(),token);
    if(!invite.id().equals(invitationId)) throw DomainException.denied();
    recipient(invite,actor,adult,true);
    var accepted=idempotency.execute(invite.tenantId(),actor.getSubject(),OPERATION,key,
        Map.of("invitationId",invitationId),Accepted.class,()->{
          // The existing operation rechecks issuer authority, scope, expiry and consumption under the same mutex.
          var joined=members.accept(actor,adult,token);
          long version=db.queryForObject("SELECT version FROM tenant_members WHERE tenant_id=? AND actor_key=?",
              Long.class,joined.tenantId(),ActorKeys.key(actor.getSubject()));
          return new Accepted(invitationId,joined.tenantId(),joined.role(),version);
        },ignored->invite.subjectId()==null?ResponseOwnership.nonSubject():ResponseOwnership.subjects(invite.tenantId(),List.of(invite.subjectId())));
    return compose(actor.getSubject(),key,invite,accepted);
  }

  @Transactional(timeout=10)
  public Result result(String actor,String invitationId,String key) {
    requireUuid(invitationId);requireUuid(key);
    var lookup=db.queryForList("SELECT tenant_id FROM member_invitations WHERE id=?",String.class,invitationId);
    if(lookup.isEmpty()) throw unavailable();
    String tenant=lookup.get(0);
    mutex.lock(tenant);
    // A recipient may have been removed since accepting. Query only their own historical journal,
    // never require or recreate tenant authority merely to report what happened.
    mutex.actors(tenant,List.of(actor));
    var invite=readById(invitationId);
    var accepted=idempotency.findCommitted(tenant,actor,OPERATION,key,
        Map.of("invitationId",invitationId),Accepted.class).orElseThrow(InvitationAcceptanceService::unavailable);
    return compose(actor,key,invite,accepted);
  }

  private Result compose(String actor,String key,Invite invite,Accepted accepted) {
    if(!accepted.invitationId().equals(invite.id())||!accepted.tenantId().equals(invite.tenantId())||accepted.role()!=invite.role())
      throw new IllegalStateException("Invitation acceptance journal scope mismatch");
    var rows=db.query("SELECT role,version,revoked_at FROM tenant_members WHERE tenant_id=? AND actor_key=? FOR UPDATE",
        (r,n)->new Current(r.getObject("revoked_at")==null?"ACTIVE":"REVOKED",Role.valueOf(r.getString("role")),r.getLong("version")),
        invite.tenantId(),ActorKeys.key(actor));
    var current=rows.isEmpty()?new Current("MISSING",null,null):rows.get(0);
    return new Result(key,actor,accepted,current);
  }

  private Invite byToken(String actor,String token) {
    var lookup=db.queryForList("SELECT id,tenant_id,inviter_actor_id FROM member_invitations WHERE token_hash=?",InvitationSecrets.tokenHash(token));
    if(lookup.isEmpty()) throw DomainException.denied();
    String tenant=lookup.get(0).get("tenant_id").toString();
    mutex.lock(tenant);
    mutex.actors(tenant,List.of(actor,lookup.get(0).get("inviter_actor_id").toString()));
    return readById(lookup.get(0).get("id").toString());
  }
  private Invite readById(String id) {
    var rows=db.query("SELECT * FROM member_invitations WHERE id=? FOR UPDATE",(r,n)->new Invite(r.getString("id"),
        r.getString("tenant_id"),r.getString("inviter_actor_id"),r.getString("recipient_email_hash"),Role.valueOf(r.getString("role")),
        r.getString("subject_id"),r.getLong("expires_at"),r.getObject("consumed_at")!=null,r.getObject("revoked_at")!=null),id);
    if(rows.isEmpty()) throw unavailable();
    return rows.get(0);
  }
  private void recipient(Invite invite,Jwt actor,boolean adult,boolean write) {
    String email=actor.getClaimAsString("email");
    if(!Boolean.TRUE.equals(actor.getClaimAsBoolean("email_verified"))||email==null||!invite.recipientHash().equals(InvitationSecrets.emailHash(email)))
      throw DomainException.denied();
    if(invite.role()!=CHILD) {
      if(!adult) throw DomainException.denied();
      if(write) recent.require(actor);
    }
  }
  private void requireUuid(String value) {
    if(value==null||!value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
      throw DomainException.invalid("INVALID_INVITATION_REFERENCE");
  }
  private static DomainException unavailable() { return new DomainException(HttpStatus.NOT_FOUND,"INVITATION_ACCEPTANCE_RESULT_UNAVAILABLE"); }
  private record Invite(String id,String tenantId,String inviter,String recipientHash,Role role,String subjectId,long expiresAt,boolean consumed,boolean revoked) {}
  record ScopeClass(String id,String name) {}
  record Preview(String invitationId,String tenantId,String tenantName,String tenantKind,Role role,String subjectId,
      String subjectName,List<ScopeClass> classes,long expiresAt,boolean requiresRecentAuthentication) {}
  record Accepted(String invitationId,String tenantId,Role role,long memberVersion) {}
  record Current(String state,Role role,Long version) {}
  record Result(String requestId,String actorId,Accepted accepted,Current current) {}
}
