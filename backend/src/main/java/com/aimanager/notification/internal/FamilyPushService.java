package com.aimanager.notification.internal;

import com.aimanager.identity.ActorKeys;
import com.aimanager.notification.FamilyAttentionEvent;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.MembershipRevoked;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.*;
import org.springframework.context.event.EventListener;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
class FamilyPushService {
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final Clock clock;
  FamilyPushService(JdbcTemplate jdbc,TenantAccess access,Clock clock) {
    this.jdbc=jdbc; this.access=access; this.clock=clock;
  }

  @Transactional(timeout=10)
  public Installation register(String tenant,String actor,String id,Registration request) {
    writeAuthority(tenant,actor); uuid(id,true);
    if(request==null || !"ALIYUN".equals(request.provider()) || !"ANDROID".equals(request.platform())
        || request.providerToken()==null || !request.providerToken().matches("[A-Za-z0-9_-]{8,255}"))
      throw DomainException.invalid("INVALID_PUSH_REGISTRATION");
    if(!request.notificationConsent() || !request.permissionGranted())
      throw DomainException.invalid("PUSH_CONSENT_REQUIRED");
    String key=ActorKeys.key(actor), tokenHash=ActorKeys.key(request.providerToken());
    long memberVersion=jdbc.queryForObject("SELECT version FROM tenant_members WHERE tenant_id=? AND actor_key=?",Long.class,tenant,key);
    var existing=jdbc.queryForList("SELECT tenant_id,actor_key,provider_token,member_version,version,revoked_at,updated_at FROM family_push_installations WHERE installation_id=? FOR UPDATE",id);
    if(!existing.isEmpty() && (!tenant.equals(existing.get(0).get("tenant_id")) || !key.equals(existing.get(0).get("actor_key"))))
      throw DomainException.denied();
    var claimed=jdbc.queryForList("SELECT installation_id FROM family_push_installations WHERE token_hash=? FOR UPDATE",String.class,tokenHash);
    if(!claimed.isEmpty() && !id.equals(claimed.get(0))) throw DomainException.invalid("PUSH_TOKEN_ALREADY_BOUND");
    try {
      if(existing.isEmpty()) jdbc.update("INSERT INTO family_push_installations(installation_id,tenant_id,actor_key,provider,platform,provider_token,token_hash,notification_consent,permission_granted,member_version,version,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
          id,tenant,key,request.provider(),request.platform(),request.providerToken(),tokenHash,true,true,memberVersion,1,clock.millis());
      else {
        var old=existing.get(0);
        boolean unchanged=request.providerToken().equals(old.get("provider_token")) && old.get("revoked_at")==null
            && ((Number)old.get("member_version")).longValue()==memberVersion;
        jdbc.update("UPDATE family_push_installations SET provider_token=?,token_hash=?,notification_consent=TRUE,permission_granted=TRUE,member_version=?,version=version+?,updated_at=?,revoked_at=NULL WHERE installation_id=?",
            request.providerToken(),tokenHash,memberVersion,unchanged ? 0 : 1,unchanged?((Number)old.get("updated_at")).longValue():clock.millis(),id);
      }
    } catch(DuplicateKeyException conflict) { throw DomainException.invalid("PUSH_TOKEN_ALREADY_BOUND"); }
    return new Installation(id,"ALIYUN","ANDROID",true,true,false);
  }

  @Transactional(timeout=10)
  public void revoke(String tenant,String actor,String id) {
    writeAuthority(tenant,actor); uuid(id,true);
    String key=ActorKeys.key(actor);
    var owners=jdbc.queryForList("SELECT actor_key,tenant_id FROM family_push_installations WHERE installation_id=? FOR UPDATE",id);
    if(!owners.isEmpty() && (!key.equals(owners.get(0).get("actor_key")) || !tenant.equals(owners.get(0).get("tenant_id"))))
      throw DomainException.denied();
    jdbc.update("UPDATE family_push_installations SET provider_token=NULL,token_hash=NULL,notification_consent=FALSE,permission_granted=FALSE,revoked_at=?,version=version+1,updated_at=? WHERE installation_id=? AND tenant_id=? AND actor_key=?",
        clock.millis(),clock.millis(),id,tenant,key);
  }

  /** A former member retains only the ability to lower their own installation's authority. */
  @Transactional(timeout=10)
  public void revokeOwned(String actor,String id) {
    uuid(id,true);
    String key=ActorKeys.key(actor);
    var owners=jdbc.queryForList("SELECT tenant_id,actor_key FROM family_push_installations WHERE installation_id=? FOR UPDATE",id);
    if(owners.isEmpty())return;
    if(!key.equals(owners.get(0).get("actor_key")))throw DomainException.denied();
    jdbc.update("UPDATE family_push_installations SET provider_token=NULL,token_hash=NULL,notification_consent=FALSE,permission_granted=FALSE,revoked_at=?,version=version+1,updated_at=? WHERE installation_id=? AND actor_key=?",clock.millis(),clock.millis(),id,key);
    jdbc.update("UPDATE family_push_outbox SET state='SUPPRESSED',last_error='INSTALLATION_REVOKED',lease_id=NULL,lease_until=NULL,updated_at=? WHERE installation_id=? AND state IN ('PENDING','LEASED')",clock.millis(),id);
  }

  @Transactional(readOnly=true)
  public Preferences preferences(String tenant,String actor) {
    access.requireRole(tenant,actor,TenantAccess.Role.OWNER,TenantAccess.Role.GUARDIAN); family(tenant);
    return preference(tenant,ActorKeys.key(actor));
  }

  @Transactional(timeout=10)
  public Preferences preferences(String tenant,String actor,Preferences value) {
    writeAuthority(tenant,actor);
    if(value==null) throw DomainException.invalid("INVALID_NOTIFICATION_PREFERENCES");
    String key=ActorKeys.key(actor);
    int changed=jdbc.update("UPDATE family_notification_preferences SET enabled=?,requests_enabled=?,device_attention_enabled=?,rule_expiry_enabled=?,updated_at=? WHERE tenant_id=? AND actor_key=?",
        value.enabled(),value.requests(),value.deviceAttention(),value.ruleExpiry(),clock.millis(),tenant,key);
    if(changed==0) jdbc.update("INSERT INTO family_notification_preferences(tenant_id,actor_key,enabled,requests_enabled,device_attention_enabled,rule_expiry_enabled,updated_at) VALUES(?,?,?,?,?,?,?)",
        tenant,key,value.enabled(),value.requests(),value.deviceAttention(),value.ruleExpiry(),clock.millis());
    return value;
  }

  @EventListener
  @Transactional(propagation=Propagation.MANDATORY)
  public void record(FamilyAttentionEvent event) {
    if(!"FAMILY".equals(jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?",String.class,event.tenantId()))) return;
    uuid(event.eventId(),false);
    if(!Set.of("FAMILY_REQUEST_PENDING","FAMILY_REQUEST_DECIDED","FAMILY_DEVICE_ATTENTION","FAMILY_RULE_EXPIRES_SOON","FAMILY_SUBSCRIPTION_EXPIRES_SOON","FAMILY_SUBSCRIPTION_EXPIRED","FAMILY_SUBSCRIPTION_SELECTION_DUE").contains(event.kind()) || event.occurredAt()<0)
      throw new IllegalArgumentException("Invalid family attention event");
    try {
      jdbc.update("INSERT INTO family_push_events(tenant_id,event_id,kind,occurred_at) VALUES(?,?,?,?)",event.tenantId(),event.eventId(),event.kind(),event.occurredAt());
    } catch(DuplicateKeyException duplicate) {
      var old=jdbc.queryForMap("SELECT kind,occurred_at FROM family_push_events WHERE tenant_id=? AND event_id=?",event.tenantId(),event.eventId());
      if(!event.kind().equals(old.get("kind")) || ((Number)old.get("occurred_at")).longValue()!=event.occurredAt())
        throw new IllegalStateException("Conflicting family attention event");
      return;
    }
    String category=category(event.kind());
    boolean timedReminder=event.kind().startsWith("FAMILY_SUBSCRIPTION_") || Set.of("FAMILY_DEVICE_ATTENTION","FAMILY_RULE_EXPIRES_SOON").contains(event.kind());
    String consentAt=timedReminder?" AND i.updated_at<=? AND p.updated_at<=?":"";
    Object[] arguments=timedReminder?new Object[]{event.tenantId(),event.occurredAt(),event.occurredAt()}:new Object[]{event.tenantId()};
    var recipients=jdbc.query("SELECT i.installation_id,i.version,i.actor_key FROM family_push_installations i JOIN tenant_members m ON m.tenant_id=i.tenant_id AND m.actor_key=i.actor_key JOIN family_notification_preferences p ON p.tenant_id=i.tenant_id AND p.actor_key=i.actor_key WHERE i.tenant_id=? AND m.revoked_at IS NULL AND m.role IN ('OWNER','GUARDIAN') AND m.version=i.member_version AND i.revoked_at IS NULL AND i.notification_consent=TRUE AND i.permission_granted=TRUE AND i.provider_token IS NOT NULL AND p.enabled=TRUE AND p."+category+"=TRUE"+consentAt,
        (r,n)->new Recipient(r.getString(1),r.getLong(2),r.getString(3)),arguments);
    for(var recipient:recipients) jdbc.update("INSERT INTO family_push_outbox(delivery_id,tenant_id,event_id,installation_id,installation_version,actor_key,state,attempts,next_attempt_at,created_at,updated_at) VALUES(?,?,?,?,?,?,'PENDING',0,?,?,?)",
        UUID.randomUUID().toString(),event.tenantId(),event.eventId(),recipient.installation(),recipient.version(),recipient.actorKey(),clock.millis(),clock.millis(),clock.millis());
  }

  @EventListener
  @Transactional(propagation=Propagation.MANDATORY)
  public void membershipRevoked(MembershipRevoked event) {
    jdbc.update("UPDATE family_push_installations SET provider_token=NULL,token_hash=NULL,notification_consent=FALSE,permission_granted=FALSE,revoked_at=?,version=version+1,updated_at=? WHERE tenant_id=? AND actor_key=?",
        clock.millis(),clock.millis(),event.tenantId(),event.actorKey());
    jdbc.update("DELETE FROM family_notification_preferences WHERE tenant_id=? AND actor_key=?",event.tenantId(),event.actorKey());
    jdbc.update("UPDATE family_push_outbox SET state='SUPPRESSED',last_error='MEMBERSHIP_REVOKED',lease_id=NULL,lease_until=NULL,updated_at=? WHERE tenant_id=? AND actor_key=? AND state IN ('PENDING','LEASED')",clock.millis(),event.tenantId(),event.actorKey());
  }

  static String category(String kind) {
    return switch(kind) {
      case "FAMILY_REQUEST_PENDING","FAMILY_REQUEST_DECIDED" -> "requests_enabled";
      case "FAMILY_DEVICE_ATTENTION" -> "device_attention_enabled";
      case "FAMILY_RULE_EXPIRES_SOON","FAMILY_SUBSCRIPTION_EXPIRES_SOON","FAMILY_SUBSCRIPTION_EXPIRED","FAMILY_SUBSCRIPTION_SELECTION_DUE" -> "rule_expiry_enabled";
      default -> throw new IllegalArgumentException("Invalid family event kind");
    };
  }
  private Preferences preference(String tenant,String key) {
    var values=jdbc.query("SELECT enabled,requests_enabled,device_attention_enabled,rule_expiry_enabled FROM family_notification_preferences WHERE tenant_id=? AND actor_key=?",
        (r,n)->new Preferences(r.getBoolean(1),r.getBoolean(2),r.getBoolean(3),r.getBoolean(4)),tenant,key);
    return values.isEmpty() ? new Preferences(false,false,false,false) : values.get(0);
  }
  private void writeAuthority(String tenant,String actor) {
    access.requireWriteRole(tenant,actor,TenantAccess.Role.OWNER,TenantAccess.Role.GUARDIAN); family(tenant);
  }
  private void family(String tenant) {
    if(!"FAMILY".equals(jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?",String.class,tenant))) throw DomainException.denied();
  }
  static void uuid(String id,boolean random) {
    try { var parsed=UUID.fromString(id); if(!parsed.toString().equals(id) || (random && parsed.version()!=4)) throw new IllegalArgumentException(); }
    catch(IllegalArgumentException|NullPointerException malformed) { throw DomainException.invalid("INVALID_PUSH_IDENTIFIER"); }
  }
  record Registration(String provider,String platform,String providerToken,boolean notificationConsent,boolean permissionGranted) {}
  record Installation(String installationId,String provider,String platform,boolean notificationConsent,boolean permissionGranted,boolean deliveryVerified) {}
  record Preferences(boolean enabled,boolean requests,boolean deviceAttention,boolean ruleExpiry) {}
  private record Recipient(String installation,long version,String actorKey) {}
}
