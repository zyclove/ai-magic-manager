package com.aimanager.tenant.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;
import com.aimanager.audit.AuditService;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.IdentityProfiles;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.FamilyCollaborationAdmission;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Verified-phone collaboration without a second identity system or recoverable stored secrets. */
@Service
class FamilyPhoneInvitationService {
  private final JdbcTemplate db;
  private final Clock clock;
  private final TenantAccess access;
  private final MembershipMutex mutex;
  private final MembershipService memberships;
  private final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final IdentityProfiles profiles;
  private final AuditService audit;
  private final FamilyCollaborationAdmission admission;

  FamilyPhoneInvitationService(JdbcTemplate db,Clock clock,TenantAccess access,MembershipMutex mutex,
      MembershipService memberships,RecentAuthentication recent,IdempotencyService idempotency,
      IdentityProfiles profiles,AuditService audit,FamilyCollaborationAdmission admission) {
    this.db=db;this.clock=clock;this.access=access;this.mutex=mutex;this.memberships=memberships;
    this.recent=recent;this.idempotency=idempotency;this.profiles=profiles;this.audit=audit;
    this.admission=admission;
  }

  @Transactional(readOnly=true)
  public Members members(String tenant,Jwt actor) {
    var grant=access.requireRole(tenant,actor.getSubject(),OWNER,GUARDIAN);family(tenant);verifiedPhone(actor);
    var rows=db.query("SELECT actor_id,actor_key,role,version FROM tenant_members WHERE tenant_id=? AND revoked_at IS NULL AND role IN ('OWNER','GUARDIAN') ORDER BY CASE WHEN role='OWNER' THEN 0 ELSE 1 END,actor_key LIMIT 101",
        (r,n)->new MemberRow(r.getString(1),r.getString(2),r.getString(3),r.getLong(4)),tenant);
    if(rows.size()>100)throw new DomainException(HttpStatus.CONFLICT,"FAMILY_MEMBER_LIMIT_REACHED");
    var names=profiles.find(rows.stream().map(MemberRow::actor).toList());
    return new Members(tenant,grant.role().name(),!declarationCurrent(actor),rows.stream().map(row->{
      boolean self=row.actor().equals(actor.getSubject());
      String name=names.containsKey(row.actor())?names.get(row.actor()).displayName():null;
      if(name==null || name.isBlank())name="OWNER".equals(row.role())?"家庭创建者":"共同监护人";
      return new Member(row.key(),self?"我":name,row.role(),row.version(),self,grant.role()==OWNER && "GUARDIAN".equals(row.role()));
    }).toList());
  }

  @Transactional(readOnly=true)
  public Invitations invitations(String tenant,Jwt actor) {
    access.requireRole(tenant,actor.getSubject(),OWNER,GUARDIAN);family(tenant);verifiedPhone(actor);
    return new Invitations(tenant,db.query("SELECT * FROM family_phone_invitations WHERE tenant_id=? ORDER BY created_at DESC,id DESC LIMIT 100",
        (r,n)->summary(row(r)),tenant));
  }

  @Transactional(timeout=10)
  public Summary issue(String tenant,Jwt actor,String key,FamilyPhoneInvitationController.Issue input) {
    authorizeOwner(tenant,actor);uuid(key);uuid(input.invitationId());token(input.token());
    if(!declarationCurrent(actor))throw DomainException.invalid("GUARDIAN_DECLARATION_REQUIRED");
    String phone=phone(input.targetPhone());
    if(phone.equals(verifiedPhone(actor)))throw DomainException.invalid("FAMILY_INVITATION_SELF");
    var fingerprint=Map.of("invitationId",input.invitationId(),"recipientHash",phoneHash(phone),"tokenHash",InvitationSecrets.tokenHash(input.token()));
    // Admission belongs inside the mutation. A replay recovers the existing invitation even after expiry.
    Reference reference=idempotency.execute(tenant,actor.getSubject(),"family.invitation.issue",key,fingerprint,Reference.class,()->{
      if(adultCount(tenant)>=10)
        throw new DomainException(HttpStatus.CONFLICT,"FAMILY_MEMBER_LIMIT_REACHED");
      admission.requireNewGuardian(tenant);
      long now=clock.millis();
      int daily=db.queryForObject("SELECT COUNT(*) FROM family_phone_invitations WHERE tenant_id=? AND created_at>?",Integer.class,tenant,now-86_400_000);
      int pending=db.queryForObject("SELECT COUNT(*) FROM family_phone_invitations WHERE tenant_id=? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>?",Integer.class,tenant,now);
      if(daily>=10 || pending>=10)throw new DomainException(HttpStatus.TOO_MANY_REQUESTS,"FAMILY_INVITATION_RATE_LIMITED");
      if(db.queryForObject("SELECT COUNT(*) FROM family_phone_invitations WHERE tenant_id=? AND recipient_phone_hash=? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>?",Integer.class,tenant,phoneHash(phone),now)>0)
        throw new DomainException(HttpStatus.CONFLICT,"FAMILY_INVITATION_ALREADY_PENDING");
      try {
        db.update("INSERT INTO family_phone_invitations(id,tenant_id,inviter_actor_id,recipient_phone_hash,recipient_phone_masked,token_hash,expires_at,created_at) VALUES(?,?,?,?,?,?,?,?)",
            input.invitationId(),tenant,actor.getSubject(),phoneHash(phone),mask(phone),InvitationSecrets.tokenHash(input.token()),now+86_400_000,now);
      }catch(DuplicateKeyException duplicate){throw new DomainException(HttpStatus.CONFLICT,"FAMILY_INVITATION_REFERENCE_CONFLICT");}
      audit.record(tenant,actor.getSubject(),"FAMILY_GUARDIAN_INVITED",input.invitationId());
      return new Reference(input.invitationId());
    },ignored->ResponseOwnership.nonSubject());
    return summary(byId(reference.id(),tenant));
  }

  @Transactional(timeout=10)
  public void revoke(String tenant,Jwt actor,String id) {
    authorizeOwner(tenant,actor);uuid(id);
    Invite invite=byId(id,tenant);
    if(invite.consumedAt()!=null)throw new DomainException(HttpStatus.CONFLICT,"INVITATION_ALREADY_ACCEPTED");
    if(invite.revokedAt()==null) {
      db.update("UPDATE family_phone_invitations SET revoked_at=? WHERE id=? AND tenant_id=?",clock.millis(),id,tenant);
      audit.record(tenant,actor.getSubject(),"FAMILY_INVITATION_REVOKED",id);
    }
  }

  @Transactional(timeout=10)
  public void remove(String tenant,Jwt actor,String memberKey,String etag,String key) {
    authorizeOwner(tenant,actor);uuid(key);
    memberships.revokeFamilyAccess(tenant,actor,memberKey,etag,key);
  }

  @Transactional(timeout=10)
  public DeclarationReceipt declareGuardian(String tenant,Jwt actor,FamilyPhoneInvitationController.Declaration input) {
    mutex.lock(tenant);access.requireWriteRole(tenant,actor.getSubject(),OWNER,GUARDIAN);family(tenant);
    verifiedPhone(actor);recent.requireForTenant(actor,tenant,db);
    if(!input.adultGuardian() || !"family-guardian-v1".equals(input.declarationVersion()))
      throw DomainException.invalid("GUARDIAN_DECLARATION_REQUIRED");
    long declared=clock.millis();recordDeclaration(tenant,actor,input.declarationVersion(),declared);
    audit.record(tenant,actor.getSubject(),"FAMILY_GUARDIAN_DECLARED",tenant);
    return new DeclarationReceipt(input.declarationVersion(),declared);
  }

  @Transactional(timeout=10)
  public Preview preview(Jwt actor,FamilyPhoneInvitationController.Secret input) {
    Invite invite=bySecret(actor,input.invitationId(),input.token());
    available(invite);
    access.requireWriteRole(invite.tenantId(),invite.inviter(),OWNER);
    return new Preview(invite.id(),invite.tenantId(),db.queryForObject("SELECT name FROM tenants WHERE id=?",String.class,invite.tenantId()),
        "GUARDIAN",invite.expiresAt(),"PENDING");
  }

  @Transactional(timeout=10)
  public Acceptance accept(Jwt actor,String key,FamilyPhoneInvitationController.Accept input) {
    uuid(key);
    Invite invite=bySecret(actor,input.invitationId(),input.token());
    if(!input.adultGuardian() || !"family-guardian-v1".equals(input.declarationVersion()))
      throw DomainException.invalid("GUARDIAN_DECLARATION_REQUIRED");
    recent.requireForTenant(actor,invite.tenantId(),db);
    var fingerprint=Map.of("invitationId",invite.id(),"declarationVersion",input.declarationVersion());
    Accepted committed=idempotency.execute(invite.tenantId(),actor.getSubject(),"family.invitation.accept",key,fingerprint,Accepted.class,()->{
      if(invite.consumedAt()!=null) {
        if(!ActorKeys.key(actor.getSubject()).equals(invite.consumedBy()))throw DomainException.denied();
        return new Accepted(invite.id(),invite.tenantId(),invite.acceptedVersion());
      }
      available(invite);
      access.requireWriteRole(invite.tenantId(),invite.inviter(),OWNER);
      if(adultCount(invite.tenantId())>=10)
        throw new DomainException(HttpStatus.CONFLICT,"FAMILY_MEMBER_LIMIT_REACHED");
      admission.requireNewGuardian(invite.tenantId());
      var existing=db.queryForList("SELECT role,version,revoked_at FROM tenant_members WHERE tenant_id=? AND actor_key=? FOR UPDATE",invite.tenantId(),ActorKeys.key(actor.getSubject()));
      if(!existing.isEmpty() && existing.get(0).get("revoked_at")==null)
        throw new DomainException(HttpStatus.CONFLICT,"MEMBER_ALREADY_EXISTS");
      long version=existing.isEmpty()?0:((Number)existing.get(0).get("version")).longValue()+1;
      if(existing.isEmpty())db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",invite.tenantId(),actor.getSubject(),ActorKeys.key(actor.getSubject()));
      else db.update("UPDATE tenant_members SET role='GUARDIAN',subject_id=NULL,revoked_at=NULL,version=? WHERE tenant_id=? AND actor_key=?",version,invite.tenantId(),ActorKeys.key(actor.getSubject()));
      db.update("UPDATE family_phone_invitations SET consumed_at=?,consumed_by_actor_key=?,accepted_member_version=? WHERE id=?",clock.millis(),ActorKeys.key(actor.getSubject()),version,invite.id());
      recordDeclaration(invite.tenantId(),actor,input.declarationVersion(),clock.millis());
      profiles.observe(actor);
      audit.record(invite.tenantId(),actor.getSubject(),"FAMILY_GUARDIAN_JOINED",invite.id());
      return new Accepted(invite.id(),invite.tenantId(),version);
    },ignored->ResponseOwnership.nonSubject());
    var states=db.queryForList("SELECT revoked_at FROM tenant_members WHERE tenant_id=? AND actor_key=? FOR UPDATE",invite.tenantId(),ActorKeys.key(actor.getSubject()));
    String state=states.isEmpty() || states.get(0).get("revoked_at")!=null?"REVOKED":"ACTIVE";
    return new Acceptance(committed.invitationId(),committed.tenantId(),"GUARDIAN",committed.memberVersion(),state);
  }

  private void authorizeOwner(String tenant,Jwt actor) {
    mutex.lock(tenant);access.requireWriteRole(tenant,actor.getSubject(),OWNER);family(tenant);
    verifiedPhone(actor);recent.requireForTenant(actor,tenant,db);
  }
  /** A pre-mutex token lookup can establish an older MySQL RR snapshot; capacity is a current read. */
  private int adultCount(String tenant) {
    return db.queryForList("SELECT actor_key FROM tenant_members WHERE tenant_id=? AND revoked_at IS NULL AND role IN ('OWNER','GUARDIAN') ORDER BY actor_key FOR UPDATE",String.class,tenant).size();
  }
  private boolean declarationCurrent(Jwt actor) {
    return db.queryForObject("SELECT COUNT(*) FROM family_guardian_declarations WHERE actor_key=? AND phone_hash=? AND declaration_version='family-guardian-v1'",
        Integer.class,ActorKeys.key(actor.getSubject()),SecretMaterial.hash(verifiedPhone(actor)))==1;
  }
  private void recordDeclaration(String tenant,Jwt actor,String version,long declaredAt) {
    db.update("INSERT INTO family_guardian_declarations(actor_key,phone_hash,declaration_version,declared_at,tenant_id) VALUES(?,?,?,?,?) ON DUPLICATE KEY UPDATE phone_hash=VALUES(phone_hash),declaration_version=VALUES(declaration_version),declared_at=VALUES(declared_at)",
        ActorKeys.key(actor.getSubject()),SecretMaterial.hash(verifiedPhone(actor)),version,declaredAt,tenant);
  }
  private Invite bySecret(Jwt actor,String id,String secret) {
    uuid(id);token(secret);String recipientHash=phoneHash(verifiedPhone(actor));
    var lookup=db.queryForList("SELECT tenant_id,inviter_actor_id FROM family_phone_invitations WHERE id=? AND token_hash=?",id,InvitationSecrets.tokenHash(secret));
    if(lookup.isEmpty())throw DomainException.denied();
    String tenant=lookup.get(0).get("tenant_id").toString();
    mutex.lock(tenant);mutex.actors(tenant,List.of(actor.getSubject(),lookup.get(0).get("inviter_actor_id").toString()));family(tenant);
    Invite invite=byId(id,tenant);
    if(!invite.phoneHash().equals(recipientHash) || !invite.tokenHash().equals(InvitationSecrets.tokenHash(secret)))throw DomainException.denied();
    return invite;
  }
  private Invite byId(String id,String tenant) {
    var rows=db.query("SELECT * FROM family_phone_invitations WHERE id=? AND tenant_id=? FOR UPDATE",(r,n)->row(r),id,tenant);
    if(rows.isEmpty())throw DomainException.denied();return rows.get(0);
  }
  private Invite row(java.sql.ResultSet r)throws java.sql.SQLException {
    return new Invite(r.getString("id"),r.getString("tenant_id"),r.getString("inviter_actor_id"),r.getString("recipient_phone_hash"),
        r.getString("recipient_phone_masked"),r.getString("token_hash"),r.getLong("expires_at"),(Long)r.getObject("consumed_at"),r.getString("consumed_by_actor_key"),
        (Long)r.getObject("revoked_at"),(Long)r.getObject("accepted_member_version"));
  }
  private Summary summary(Invite invite) {
    String state=invite.consumedAt()!=null?"ACCEPTED":invite.revokedAt()!=null?"REVOKED":invite.expiresAt()<=clock.millis()?"EXPIRED":"PENDING";
    return new Summary(invite.id(),"GUARDIAN",invite.maskedPhone(),invite.expiresAt(),state);
  }
  private void available(Invite invite) {
    if(invite.consumedAt()!=null || invite.revokedAt()!=null || invite.expiresAt()<=clock.millis())
      throw new DomainException(HttpStatus.CONFLICT,"INVITATION_UNAVAILABLE");
  }
  private void family(String tenant) {
    if(!"FAMILY".equals(db.queryForObject("SELECT kind FROM tenants WHERE id=?",String.class,tenant)))throw DomainException.denied();
  }
  private static String verifiedPhone(Jwt actor) {
    Object phone=actor.getClaims().get("phone_number");
    if(!Boolean.TRUE.equals(actor.getClaims().get("phone_number_verified")) || !(phone instanceof String value) || !value.matches("\\+861[3-9][0-9]{9}"))
      throw new DomainException(HttpStatus.PRECONDITION_REQUIRED,"VERIFIED_PHONE_REQUIRED");
    return value;
  }
  private static String phone(String input) {
    if(input==null)throw DomainException.invalid("INVALID_MAINLAND_PHONE");
    String value=input.strip();if(value.matches("1[3-9][0-9]{9}"))value="+86"+value;
    if(!value.matches("\\+861[3-9][0-9]{9}"))throw DomainException.invalid("INVALID_MAINLAND_PHONE");return value;
  }
  private static String mask(String phone){String local=phone.substring(3);return local.substring(0,3)+"****"+local.substring(7);}
  private static String phoneHash(String phone){return SecretMaterial.hash("family-invitation-phone-v1\0"+phone);}
  private static void uuid(String value) {
    try {var id=UUID.fromString(value);if(!id.toString().equals(value)||id.version()!=4)throw new IllegalArgumentException();}
    catch(IllegalArgumentException|NullPointerException malformed){throw DomainException.invalid("INVALID_INVITATION_REFERENCE");}
  }
  private static void token(String value) {
    try {if(value==null || !value.matches("[A-Za-z0-9_-]{43}"))throw new IllegalArgumentException();
      byte[] decoded=Base64.getUrlDecoder().decode(value);
      if(decoded.length!=32 || !Base64.getUrlEncoder().withoutPadding().encodeToString(decoded).equals(value))throw new IllegalArgumentException();
    }catch(IllegalArgumentException malformed){throw DomainException.invalid("INVALID_INVITATION_SECRET");}
  }
  private record MemberRow(String actor,String key,String role,long version){}
  private record Invite(String id,String tenantId,String inviter,String phoneHash,String maskedPhone,String tokenHash,long expiresAt,
      Long consumedAt,String consumedBy,Long revokedAt,Long acceptedVersion){}
  record Member(String memberKey,String displayName,String role,long version,boolean self,boolean canRemove){}
  record Members(String tenantId,String currentRole,boolean guardianDeclarationRequired,List<Member> members){}
  record Summary(String id,String role,String targetPhoneMasked,long expiresAt,String state){}
  record Invitations(String tenantId,List<Summary> items){}
  record Preview(String invitationId,String tenantId,String tenantName,String role,long expiresAt,String state){}
  record Reference(String id){}
  record Accepted(String invitationId,String tenantId,long memberVersion){}
  record Acceptance(String invitationId,String tenantId,String role,long memberVersion,String currentState){}
  record DeclarationReceipt(String declarationVersion,long declaredAt){}
}
