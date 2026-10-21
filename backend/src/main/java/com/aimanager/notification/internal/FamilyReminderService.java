package com.aimanager.notification.internal;

import com.aimanager.commerce.FamilySubscriptionReminders;
import com.aimanager.notification.FamilyAttentionEvent;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Isolation;

/** Bounded, persisted fact projection. Scanning never creates a heartbeat, rule or commercial entitlement. */
@Service
class FamilyReminderService implements FamilyReminderFreshness {
  private static final long DAY=86_400_000L;
  private static final Set<String> INITIAL=Set.of("INITIALIZING","DISABLED","CONFIGURATION_UNAVAILABLE","EXPIRED");
  private static final Set<String> HARD_FAILURE=Set.of("CLOCK_ANOMALY","STORAGE_FAILURE","CONFIGURATION_INVALID","NATIVE_OBSERVATION_UNAVAILABLE","FOREGROUND_UNAVAILABLE");
  private final JdbcTemplate jdbc;
  private final TransactionTemplate tx;
  private final FamilySubscriptionReminders subscriptions;
  private final ApplicationEventPublisher events;
  private final ObjectMapper json;
  private final Clock clock;
  private final long offlineMillis,connectingMillis,freshMillis;

  FamilyReminderService(JdbcTemplate jdbc,PlatformTransactionManager manager,FamilySubscriptionReminders subscriptions,
      ApplicationEventPublisher events,ObjectMapper json,Clock clock,
      @Value("${manager.family.reminders.offline-seconds:1800}") int offlineSeconds,
      @Value("${manager.family.reminders.connecting-grace-seconds:1800}") int connectingSeconds,
      @Value("${manager.family.reminders.runtime-fresh-seconds:600}") int freshSeconds) {
    if(offlineSeconds<300 || offlineSeconds>86400 || connectingSeconds<300 || connectingSeconds>86400 || freshSeconds<60 || freshSeconds>3600)
      throw new IllegalArgumentException("Invalid family reminder thresholds");
    this.jdbc=jdbc;this.tx=new TransactionTemplate(manager);tx.setTimeout(10);
    this.subscriptions=subscriptions;this.events=events;this.json=json;this.clock=clock;
    offlineMillis=offlineSeconds*1000L;connectingMillis=connectingSeconds*1000L;freshMillis=freshSeconds*1000L;
  }

  /** Two short transactions avoid taking a commercial lock after a device lock. */
  public int scan(int limit) {
    if(limit<1 || limit>100)throw new IllegalArgumentException("Invalid family reminder batch");
    int devices=Objects.requireNonNull(tx.execute(status->scanDevices(limit)));
    int accounts=Objects.requireNonNull(tx.execute(status->scanSubscriptions(limit)));
    return devices+accounts;
  }

  private Cursor cursor(String scope) {
    jdbc.update("INSERT INTO family_notification_scan_cursors(scope_key,last_tenant_id,last_entity_id,updated_at) VALUES(?,'','',?) ON DUPLICATE KEY UPDATE scope_key=scope_key",scope,clock.millis());
    return jdbc.queryForObject("SELECT last_tenant_id,last_entity_id FROM family_notification_scan_cursors WHERE scope_key=? FOR UPDATE",(r,i)->new Cursor(r.getString(1),r.getString(2)),scope);
  }
  private void advance(String scope,String tenant,String entity) {
    jdbc.update("UPDATE family_notification_scan_cursors SET last_tenant_id=?,last_entity_id=?,updated_at=? WHERE scope_key=?",tenant,entity,clock.millis(),scope);
  }
  private int scanDevices(int limit) {
    Cursor cursor=cursor("DEVICES");
    var candidates=jdbc.query("SELECT d.tenant_id,d.id,d.subject_id FROM devices d JOIN tenants t ON t.id=d.tenant_id JOIN subjects s ON s.tenant_id=d.tenant_id AND s.id=d.subject_id WHERE t.kind='FAMILY' AND d.state='ACTIVE' AND d.platform='ANDROID' AND s.archived_at IS NULL AND (d.tenant_id>? OR (d.tenant_id=? AND d.id>?)) ORDER BY d.tenant_id,d.id LIMIT ?",
        (r,i)->new Candidate(r.getString(1),r.getString(2),r.getString(3)),cursor.tenant(),cursor.tenant(),cursor.entity(),limit);
    // Lock every subject before any device, in family/subject order. A device-ordered batch
    // otherwise risks B -> A subject locks against commercial admission's A -> B order.
    candidates.stream().map(c->new Cursor(c.tenant(),c.subject())).distinct()
        .sorted(Comparator.comparing(Cursor::tenant).thenComparing(Cursor::entity))
        .forEach(subject->jdbc.queryForList("SELECT id FROM subjects WHERE tenant_id=? AND id=? FOR UPDATE",String.class,subject.tenant(),subject.entity()));
    for(var candidate:candidates)observeDevice(candidate.tenant(),candidate.id());
    Candidate finalCandidate=candidates.isEmpty()?null:candidates.get(candidates.size()-1);
    boolean currentLast=finalCandidate!=null && !jdbc.queryForList("SELECT d.id FROM devices d JOIN subjects s ON s.tenant_id=d.tenant_id AND s.id=d.subject_id WHERE d.tenant_id=? AND d.id=? AND d.state='ACTIVE' AND d.platform='ANDROID' AND s.archived_at IS NULL FOR UPDATE",String.class,finalCandidate.tenant(),finalCandidate.id()).isEmpty();
    Cursor last=candidates.size()<limit || !currentLast?new Cursor("",""):new Cursor(finalCandidate.tenant(),finalCandidate.id());
    advance("DEVICES",last.tenant(),last.entity());return candidates.size();
  }
  private int scanSubscriptions(int limit) {
    Cursor cursor=cursor("SUBSCRIPTIONS");
    var candidates=jdbc.queryForList("SELECT id FROM tenants WHERE kind='FAMILY' AND id>? ORDER BY id LIMIT ?",String.class,cursor.tenant(),limit);
    for(String tenant:candidates) {
      var current=subscriptions.lockCurrent(tenant);
      for(Boundary boundary:boundaries(current))recordBoundary(tenant,boundary);
      var old=jdbc.query("SELECT DISTINCT s.event_id,s.event_kind,s.period_end,s.trigger_at FROM family_notification_subscription_states s JOIN family_push_outbox o ON o.tenant_id=s.tenant_id AND o.event_id=s.event_id WHERE s.tenant_id=? AND o.state IN ('PENDING','LEASED') ORDER BY s.event_id LIMIT 100",
          (r,i)->new StoredBoundary(r.getString(1),new Boundary(r.getString(2),r.getLong(3),r.getLong(4))),tenant);
      for(var prior:old)if(!valid(current,prior.boundary()))suppress(tenant,prior.event());
    }
    advance("SUBSCRIPTIONS",candidates.size()<limit?"":candidates.get(candidates.size()-1),"");return candidates.size();
  }

  private void observeDevice(String tenant,String id) {
    Device device=device(tenant,id,true);if(device==null)return;
    // Exit can win while a candidate waits for its subject lock. Stop before
    // taking the episode lock, which an erasure batch may already be deleting.
    if(!"ACTIVE".equals(device.state()) || !"ANDROID".equals(device.platform()) || device.archived())return;
    var rows=jdbc.query("SELECT registration_id,was_healthy,condition_code,condition_anchor,episode,event_id FROM family_notification_device_states WHERE tenant_id=? AND device_id=? FOR UPDATE",
        (r,i)->new Episode(r.getString(1),r.getBoolean(2),r.getString(3),(Long)r.getObject(4),r.getLong(5),r.getString(6)),tenant,id);
    Episode previous=rows.isEmpty()?null:rows.get(0);
    boolean same=previous!=null && previous.registration().equals(device.registration());
    if(previous!=null && !same && previous.event()!=null)suppress(tenant,previous.event());
    boolean wasHealthy=same && previous.healthy();
    Evidence evidence=evidence(device,wasHealthy,true);
    boolean healthy=wasHealthy || evidence.healthy();
    String event=same?previous.event():null;
    long episode=previous==null?0:previous.number();
    Long anchor=same?previous.anchor():null;
    String code=same?previous.code():null;
    // A later heartbeat proves reconnection even when the worker did not run during it.
    if(event!=null && "OFFLINE".equals(code) && "OFFLINE".equals(evidence.code()) && evidence.anchor()>anchor) {
      suppress(tenant,event);event=null;
    }
    boolean reconnected="OFFLINE".equals(code) && device.heartbeat()!=null && device.heartbeat()+offlineMillis>clock.millis();
    if(evidence.code()==null && (evidence.recovered() || reconnected)) {
      if(event!=null)suppress(tenant,event);
      event=null;anchor=null;code=null;
    } else if(evidence.code()!=null && event==null) {
      event=UUID.randomUUID().toString();episode++;anchor=evidence.anchor();code=evidence.code();
      events.publishEvent(new FamilyAttentionEvent(tenant,event,device.subject(),id,"FAMILY_DEVICE_ATTENTION",anchor));
    }
    if(previous==null)jdbc.update("INSERT INTO family_notification_device_states(tenant_id,device_id,registration_id,was_healthy,condition_code,condition_anchor,episode,event_id,updated_at) VALUES(?,?,?,?,?,?,?,?,?)",tenant,id,device.registration(),healthy,code,anchor,episode,event,clock.millis());
    else jdbc.update("UPDATE family_notification_device_states SET registration_id=?,was_healthy=?,condition_code=?,condition_anchor=?,episode=?,event_id=?,updated_at=? WHERE tenant_id=? AND device_id=?",device.registration(),healthy,code,anchor,episode,event,clock.millis(),tenant,id);
  }

  private Device device(String tenant,String id,boolean lock) {
    if(lock) {
      var subjects=jdbc.queryForList("SELECT subject_id FROM devices WHERE tenant_id=? AND id=?",String.class,tenant,id);
      if(!subjects.isEmpty())jdbc.queryForList("SELECT id FROM subjects WHERE tenant_id=? AND id=? FOR UPDATE",String.class,tenant,subjects.get(0));
    }
    var rows=jdbc.query("SELECT d.registration_id,d.subject_id,d.state,d.platform,d.created_at,d.last_heartbeat_at,s.archived_at FROM devices d JOIN subjects s ON s.tenant_id=d.tenant_id AND s.id=d.subject_id WHERE d.tenant_id=? AND d.id=?"+(lock?" FOR UPDATE":""),
        (r,i)->new Device(tenant,id,r.getString(1),r.getString(2),r.getString(3),r.getString(4),r.getLong(5),(Long)r.getObject(6),r.getObject(7)!=null),tenant,id);
    return rows.isEmpty()?null:rows.get(0);
  }
  private Evidence evidence(Device device,boolean wasHealthy,boolean lock) {
    if(!"ACTIVE".equals(device.state()) || !"ANDROID".equals(device.platform()) || device.archived())return Evidence.clear();
    long disconnectedAt=device.heartbeat()==null?device.created()+connectingMillis:device.heartbeat()+offlineMillis;
    if(clock.millis()>=disconnectedAt)return new Evidence(false,"OFFLINE",disconnectedAt,false);
    var reports=jdbc.query("SELECT observed_at,received_at,report_json FROM family_runtime_reports WHERE tenant_id=? AND device_id=? AND registration_id=?"+(lock?" FOR UPDATE":""),
        (r,i)->new Runtime(r.getLong(1),r.getLong(2),r.getString(3)),device.tenant(),device.id(),device.registration());
    if(reports.isEmpty())return Evidence.none();
    Runtime report=reports.get(0);
    if(report.observed()<clock.millis()-freshMillis || report.observed()>clock.millis()+30000 || report.received()>clock.millis()+30000)return Evidence.none();
    try {
      JsonNode runtime=json.readTree(report.document());
      var documents=jdbc.queryForList("SELECT d.document_json FROM configuration_streams s JOIN configuration_deliveries d ON d.tenant_id=s.tenant_id AND d.id=s.delivery_id WHERE d.tenant_id=? AND d.device_id=? AND d.registration_id=? AND d.policy_id=? AND d.version_id=? AND d.source_sequence=?"+(lock?" FOR UPDATE":""),
          String.class,device.tenant(),device.id(),device.registration(),runtime.path("policyId").asText(),runtime.path("versionId").asText(),runtime.path("sourceSequence").asLong());
      if(documents.size()!=1 || documents.get(0)==null)return Evidence.none();
      JsonNode rule=json.readTree(documents.get(0)).path("familyAssistance");
      if(!"FAMILY_ASSISTED".equals(rule.path("mode").asText()))return Evidence.none();
      if(!rule.path("enabled").asBoolean(false))return Evidence.clear();
      String health=runtime.path("health").asText();
      boolean opted=runtime.path("optedIn").asBoolean(false);
      boolean healthy="ACTIVE".equals(health) && opted && runtime.path("usageGranted").asBoolean(false) && runtime.path("accessibilityConnected").asBoolean(false);
      if(healthy)return new Evidence(true,null,0,true);
      if(INITIAL.contains(health))return Evidence.none();
      if(wasHealthy || opted && HARD_FAILURE.contains(health))return new Evidence(false,"RUNTIME_ATTENTION",Math.min(clock.millis(),report.observed()),false);
      return Evidence.none();
    } catch(java.io.IOException malformed) {return Evidence.none();}
  }

  private List<Boundary> boundaries(FamilySubscriptionReminders.Window value) {
    var result=new ArrayList<Boundary>();
    if(value.activePeriodEnd()!=null && clock.millis()>=value.activePeriodEnd()-3*DAY)
      result.add(new Boundary("FAMILY_SUBSCRIPTION_EXPIRES_SOON",value.activePeriodEnd(),value.activePeriodEnd()-3*DAY));
    if(value.activePeriodEnd()==null && value.lastPeriodEnd()!=null) {
      result.add(new Boundary("FAMILY_SUBSCRIPTION_EXPIRED",value.lastPeriodEnd(),value.lastPeriodEnd()));
      if(value.selectionPending() && value.graceEndsAt()!=null && clock.millis()>=value.graceEndsAt()-DAY)
        result.add(new Boundary("FAMILY_SUBSCRIPTION_SELECTION_DUE",value.lastPeriodEnd(),value.graceEndsAt()-DAY));
    }
    return result;
  }
  private boolean valid(FamilySubscriptionReminders.Window current,Boundary boundary) {
    return switch(boundary.kind()) {
      case "FAMILY_SUBSCRIPTION_EXPIRES_SOON" -> Objects.equals(current.activePeriodEnd(),boundary.end()) && clock.millis()<boundary.end();
      case "FAMILY_SUBSCRIPTION_EXPIRED" -> current.activePeriodEnd()==null && Objects.equals(current.lastPeriodEnd(),boundary.end());
      case "FAMILY_SUBSCRIPTION_SELECTION_DUE" -> current.activePeriodEnd()==null && Objects.equals(current.lastPeriodEnd(),boundary.end()) && current.selectionPending() && current.graceEndsAt()!=null && clock.millis()<current.graceEndsAt();
      default -> false;
    };
  }
  private void recordBoundary(String tenant,Boundary boundary) {
    String key=SecretMaterial.hash(boundary.kind()+":"+boundary.end()+":"+boundary.trigger());
    if(!jdbc.queryForList("SELECT boundary_key FROM family_notification_subscription_states WHERE tenant_id=? AND boundary_key=?",String.class,tenant,key).isEmpty())return;
    String event=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO family_notification_subscription_states(tenant_id,boundary_key,event_kind,period_end,trigger_at,event_id,created_at) VALUES(?,?,?,?,?,?,?)",tenant,key,boundary.kind(),boundary.end(),boundary.trigger(),event,clock.millis());
    events.publishEvent(new FamilyAttentionEvent(tenant,event,null,null,boundary.kind(),boundary.trigger()));
  }
  private void suppress(String tenant,String event) {
    jdbc.update("UPDATE family_push_outbox SET state='SUPPRESSED',last_error='REMINDER_NO_LONGER_CURRENT',lease_id=NULL,lease_until=NULL,updated_at=? WHERE tenant_id=? AND event_id=? AND state IN ('PENDING','LEASED')",clock.millis(),tenant,event);
  }

  /** Non-locking re-read: a provider acceptance cannot be undone if a later recovery races the send. */
  @Override @Transactional(propagation=Propagation.REQUIRES_NEW,readOnly=true,isolation=Isolation.READ_COMMITTED,timeout=5)
  public boolean allows(String tenant,String event) {
    var devices=jdbc.query("SELECT device_id,registration_id,was_healthy FROM family_notification_device_states WHERE tenant_id=? AND event_id=?",
        (r,i)->new GuardDevice(r.getString(1),r.getString(2),r.getBoolean(3)),tenant,event);
    if(!devices.isEmpty()) {
      var previous=devices.get(0);Device device=device(tenant,previous.id(),false);
      return device!=null && device.registration().equals(previous.registration()) && evidence(device,previous.healthy(),false).code()!=null;
    }
    var boundaries=jdbc.query("SELECT event_kind,period_end,trigger_at FROM family_notification_subscription_states WHERE tenant_id=? AND event_id=?",
        (r,i)->new Boundary(r.getString(1),r.getLong(2),r.getLong(3)),tenant,event);
    if(!boundaries.isEmpty())return valid(subscriptions.current(tenant),boundaries.get(0));
    // Device episodes clear their event pointer on recovery. A known reminder without a current
    // pointer is stale, while unrelated request and rule producers retain their normal behavior.
    var kinds=jdbc.queryForList("SELECT kind FROM family_push_events WHERE tenant_id=? AND event_id=?",String.class,tenant,event);
    return kinds.isEmpty() || !kinds.get(0).startsWith("FAMILY_SUBSCRIPTION_") && !"FAMILY_DEVICE_ATTENTION".equals(kinds.get(0));
  }
  private record Cursor(String tenant,String entity) {}
  private record Candidate(String tenant,String id,String subject) {}
  private record Device(String tenant,String id,String registration,String subject,String state,String platform,long created,Long heartbeat,boolean archived) {}
  private record Runtime(long observed,long received,String document) {}
  private record Episode(String registration,boolean healthy,String code,Long anchor,long number,String event) {}
  private record Evidence(boolean healthy,String code,long anchor,boolean recovered) {
    static Evidence none(){return new Evidence(false,null,0,false);}
    static Evidence clear(){return new Evidence(false,null,0,true);}
  }
  private record Boundary(String kind,long end,long trigger) {}
  private record StoredBoundary(String event,Boundary boundary) {}
  private record GuardDevice(String id,String registration,boolean healthy) {}
}
