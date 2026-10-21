package com.aimanager.notification.internal;

import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Local leases provide one active worker; every external attempt retains its delivery identifier. */
@Service
class FamilyPushDispatcher {
  private final JdbcTemplate jdbc;
  private final TransactionTemplate tx;
  private final FamilyPushGateway gateway;
  private final Clock clock;
  private final int maxAttempts;
  private final long leaseMillis;
  private final Optional<FamilyReminderFreshness> reminders;
  FamilyPushDispatcher(JdbcTemplate jdbc,PlatformTransactionManager manager,FamilyPushGateway gateway,Clock clock,
      @Value("${manager.family.push.max-attempts:5}") int maxAttempts,
      @Value("${manager.family.push.lease-seconds:60}") int leaseSeconds,Optional<FamilyReminderFreshness> reminders) {
    if(maxAttempts<1 || maxAttempts>10 || leaseSeconds<30 || leaseSeconds>300)
      throw new IllegalArgumentException("Invalid push retry configuration");
    this.jdbc=jdbc; this.tx=new TransactionTemplate(manager); tx.setTimeout(15);
    this.gateway=gateway; this.clock=clock; this.maxAttempts=maxAttempts; this.leaseMillis=leaseSeconds*1000L;
    this.reminders=reminders;
  }

  public int dispatch(int limit) {
    if(limit<1 || limit>100) throw new IllegalArgumentException("Invalid push batch");
    if(!gateway.available()) return 0;
    var candidates=jdbc.queryForList("SELECT delivery_id FROM family_push_outbox WHERE (state='PENDING' AND next_attempt_at<=?) OR (state='LEASED' AND lease_until<=?) ORDER BY next_attempt_at,delivery_id LIMIT ?",
        String.class,clock.millis(),clock.millis(),limit);
    int processed=0;
    for(String id:candidates) {
      String lease=UUID.randomUUID().toString();
      boolean claimed=Boolean.TRUE.equals(tx.execute(status->jdbc.update("UPDATE family_push_outbox SET state='LEASED',lease_id=?,lease_until=?,updated_at=? WHERE delivery_id=? AND ((state='PENDING' AND next_attempt_at<=?) OR (state='LEASED' AND lease_until<=?))",
          lease,clock.millis()+leaseMillis,clock.millis(),id,clock.millis(),clock.millis())==1));
      if(claimed) { tx.executeWithoutResult(status->deliver(id,lease)); processed++; }
    }
    return processed;
  }

  private void deliver(String id,String lease) {
    var snapshots=jdbc.query("SELECT tenant_id,actor_key,installation_id FROM family_push_outbox WHERE delivery_id=? AND state='LEASED' AND lease_id=?",
        (r,n)->new Recipient(r.getString(1),r.getString(2),r.getString(3)),id,lease);
    if(snapshots.isEmpty()) return;
    var recipient=snapshots.get(0);
    // Same authority-first lock order as registration/revocation. Revocation waits for a bounded send.
    var members=jdbc.queryForList("SELECT role,revoked_at,version FROM tenant_members WHERE tenant_id=? AND actor_key=? FOR UPDATE",recipient.tenant(),recipient.actorKey());
    var installations=jdbc.queryForList("SELECT * FROM family_push_installations WHERE installation_id=? FOR UPDATE",recipient.installation());
    var preferences=jdbc.queryForList("SELECT * FROM family_notification_preferences WHERE tenant_id=? AND actor_key=? FOR UPDATE",recipient.tenant(),recipient.actorKey());
    var rows=jdbc.queryForList("SELECT o.*,e.kind,e.occurred_at FROM family_push_outbox o JOIN family_push_events e ON e.tenant_id=o.tenant_id AND e.event_id=o.event_id WHERE o.delivery_id=? AND o.state='LEASED' AND o.lease_id=? FOR UPDATE",id,lease);
    if(rows.isEmpty()) return;
    var row=rows.get(0);
    String kind=(String)row.get("kind");
    boolean allowed="FAMILY".equals(jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?",String.class,recipient.tenant()))
        && members.size()==1 && installations.size()==1 && preferences.size()==1;
    if(allowed) {
      var member=members.get(0); var installation=installations.get(0); var preference=preferences.get(0);
      allowed=Set.of("OWNER","GUARDIAN").contains(member.get("role")) && member.get("revoked_at")==null
          && recipient.tenant().equals(installation.get("tenant_id")) && recipient.actorKey().equals(installation.get("actor_key"))
          && number(member,"version")==number(installation,"member_version")
          && number(row,"installation_version")==number(installation,"version")
          && installation.get("revoked_at")==null && installation.get("provider_token")!=null
          && Boolean.TRUE.equals(installation.get("notification_consent")) && Boolean.TRUE.equals(installation.get("permission_granted"))
          && Boolean.TRUE.equals(preference.get("enabled")) && Boolean.TRUE.equals(preference.get(FamilyPushService.category(kind)));
    }
    if(!allowed || number(row,"occurred_at")<clock.millis()-86_400_000L) {
      finish(id,lease,"SUPPRESSED",null,"CURRENT_AUTHORITY_OR_CONSENT_UNAVAILABLE",number(row,"attempts"),clock.millis()); return;
    }
    if(reminders.isPresent() && !reminders.get().allows(recipient.tenant(),(String)row.get("event_id"))) {
      finish(id,lease,"SUPPRESSED",null,"REMINDER_NO_LONGER_CURRENT",number(row,"attempts"),clock.millis());return;
    }
    int attempt=(int)number(row,"attempts")+1;
    if(attempt>maxAttempts) { finish(id,lease,"DEAD",null,"RETRY_LIMIT",attempt-1,clock.millis()); return; }
    String eventId=(String)row.get("event_id");
    var command=new FamilyPushGateway.Command(id,(String)installations.get(0).get("provider_token"),eventId,recipient.installation(),
        "家庭提醒","家庭中有待查看的更新，请打开应用查看。","aimanager://notifications/"+eventId);
    try {
      var accepted=gateway.send(command);
      finish(id,lease,"ACCEPTED",accepted.providerMessageId(),null,attempt,clock.millis());
    } catch(FamilyPushGateway.Failure failure) {
      boolean retry=failure.retryable && attempt<maxAttempts;
      finish(id,lease,retry ? "PENDING" : "DEAD",null,safeCode(failure.getMessage()),attempt,
          clock.millis()+Math.min(3600_000L,60_000L*(1L<<Math.min(attempt-1,6))));
    } catch(RuntimeException failure) {
      // An unknown integration failure may have happened after acceptance. Never record a receipt.
      finish(id,lease,"DEAD",null,"PROVIDER_OUTCOME_UNKNOWN",attempt,clock.millis());
    }
  }
  private void finish(String id,String lease,String state,String message,String error,long attempts,long next) {
    jdbc.update("UPDATE family_push_outbox SET state=?,attempts=?,next_attempt_at=?,provider_message_id=?,last_error=?,lease_id=NULL,lease_until=NULL,updated_at=? WHERE delivery_id=? AND state='LEASED' AND lease_id=?",
        state,attempts,next,message,error,clock.millis(),id,lease);
  }
  private static String safeCode(String code) { return code!=null && code.matches("[A-Z_]{1,60}") ? code : "PROVIDER_FAILURE"; }
  private static long number(Map<String,Object> row,String key) { return ((Number)row.get(key)).longValue(); }
  private record Recipient(String tenant,String actorKey,String installation) {}
}
