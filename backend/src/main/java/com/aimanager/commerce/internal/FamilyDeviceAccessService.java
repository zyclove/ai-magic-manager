package com.aimanager.commerce.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.commerce.FamilyDeviceAccess;
import com.aimanager.commerce.FamilySubscriptionReminders;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** One database account lock serializes admission, choice, purchases and verified refunds. */
@Service
class FamilyDeviceAccessService implements FamilyDeviceAccess,FamilySubscriptionReminders {
  private static final ZoneId FAMILY_ZONE=ZoneId.of("Asia/Shanghai");
  private final JdbcTemplate jdbc;
  private final Clock clock;
  private final TenantAccess access;
  private final IdempotencyService idempotency;
  private final AuditService audit;

  FamilyDeviceAccessService(JdbcTemplate jdbc,Clock clock,TenantAccess access,
      IdempotencyService idempotency,AuditService audit) {
    this.jdbc=jdbc;this.clock=clock;this.access=access;this.idempotency=idempotency;this.audit=audit;
  }

  @Override public void lockFamily(String tenant) {
    if(!TransactionSynchronizationManager.isActualTransactionActive())throw new IllegalStateException("Family admission needs transaction");
    if(!family(tenant))return;
    jdbc.update("INSERT INTO commercial_accounts(tenant_id,version) VALUES(?,0) ON DUPLICATE KEY UPDATE tenant_id=tenant_id",tenant);
    jdbc.queryForObject("SELECT version FROM commercial_accounts WHERE tenant_id=? FOR UPDATE",Long.class,tenant);
    // Current locking reads are essential under MySQL REPEATABLE READ after waiting for the
    // account. Take subject locks before any device locks, in the same order as subject writers.
    jdbc.queryForList("SELECT id FROM subjects WHERE tenant_id=? ORDER BY id FOR UPDATE",String.class,tenant);
  }

  @Transactional(timeout=10)
  View read(String tenant,String actor) {
    access.requireWriteRole(tenant,actor,TenantAccess.Role.OWNER,TenantAccess.Role.GUARDIAN);
    return state(tenant);
  }

  @Transactional(timeout=10)
  View select(String tenant,String actor,String device,String registration,long expected,String key) {
    access.requireWriteRole(tenant,actor,TenantAccess.Role.OWNER,TenantAccess.Role.GUARDIAN);
    canonical(device);canonical(registration);
    if(key==null || key.isBlank())throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
    lockFamily(tenant);
    if(!family(tenant))throw DomainException.denied();
    return idempotency.execute(tenant,actor,"family.device.selection",key,
        Map.of("deviceId",device,"registrationId",registration,"expected",expected),View.class,()->{
          View before=state(tenant);
          ResourceVersions.check(expected,before.version());
          if("PAID".equals(before.status()))throw conflict("FAMILY_SELECTION_NOT_REQUIRED");
          var chosen=before.devices().stream().filter(d->device.equals(d.id()) && registration.equals(d.registrationId()) && d.canSelect()).findFirst()
              .orElseThrow(()->conflict("FAMILY_SELECTION_DEVICE_UNAVAILABLE"));
          Long anchor=membership(tenant).endedAt();
          jdbc.update("UPDATE family_device_access_accounts SET selected_device_id=?,selected_registration_id=?,selection_anchor=? WHERE tenant_id=?",
              device,registration,anchor,tenant);
          audit.record(tenant,actor,"FAMILY_BASIC_DEVICE_SELECTED",device);
          return state(tenant);
        },view->ResponseOwnership.subjects(tenant,view.devices().stream().map(DeviceAccess::subjectId).distinct().toList()));
  }

  @Override @Transactional(timeout=10)
  public View state(String tenant) {
    lockFamily(tenant);
    if(!family(tenant))throw DomainException.denied();
    jdbc.update("INSERT INTO family_device_access_accounts(tenant_id,version) VALUES(?,0) ON DUPLICATE KEY UPDATE tenant_id=tenant_id",tenant);
    Head head=jdbc.queryForObject("SELECT version,projection_hash,selected_device_id,selected_registration_id,selection_anchor FROM family_device_access_accounts WHERE tenant_id=? FOR UPDATE",
        (r,i)->new Head(r.getLong(1),r.getString(2),r.getString(3),r.getString(4),(Long)r.getObject(5)),tenant);
    var membership=membership(tenant);
    Long anchor=membership.endedAt();
    Long graceEnd=anchor==null?null:Instant.ofEpochMilli(anchor).atZone(FAMILY_ZONE).plusDays(7).toInstant().toEpochMilli();
    String status=membership.active()?"PAID":anchor==null?"FREE":clock.millis()<graceEnd && !Objects.equals(head.selectionAnchor(),anchor)?"GRACE":"EXPIRED";
    List<Connected> connected=connected(tenant);
    String selected=head.device(),registration=head.registration();
    Long selectionAnchor=head.selectionAnchor();
    if("FREE".equals(status) && selected==null) {
      Connected first=connected.stream().filter(Connected::selectable).findFirst().orElse(null);
      selected=first==null?null:first.id();registration=first==null?null:first.registration();
    } else if("EXPIRED".equals(status) && (!Objects.equals(selectionAnchor,anchor) || selected==null)) {
      Connected first=connected.stream().filter(Connected::selectable).findFirst().orElse(null);
      selected=first==null?null:first.id();registration=first==null?null:first.registration();selectionAnchor=anchor;
    }
    List<DeviceAccess> devices=new ArrayList<>();
    for(var d:connected) {
      if(!d.live())continue;
      boolean chosen=d.selectable() && d.id().equals(selected) && d.registration().equals(registration);
      String level="PAID".equals(status)?"MEMBER":"GRACE".equals(status)?"GRACE":chosen?"BASIC":"RECOVERY_ONLY";
      devices.add(new DeviceAccess(d.id(),d.registration(),d.displayName(),d.subject(),d.subjectName(),d.state(),d.createdAt(),level,chosen,d.selectable()));
    }
    int count=(int)connected.stream().filter(Connected::live).count();
    int limit="PAID".equals(status)?3:1;
    long commercialVersion=jdbc.queryForObject("SELECT version FROM commercial_accounts WHERE tenant_id=? FOR UPDATE",Long.class,tenant);
    String hash=FamilySubscriptionService.hash(status+"|"+anchor+"|"+selectionAnchor+"|"+selected+"|"+registration+"|"+commercialVersion+"|"+devices);
    long version=head.version();
    if(!hash.equals(head.hash())) {
      version++;
      jdbc.update("UPDATE family_device_access_accounts SET version=?,projection_hash=?,selected_device_id=?,selected_registration_id=?,selection_anchor=? WHERE tenant_id=?",
          version,hash,selected,registration,selectionAnchor,tenant);
    }
    boolean selectedConnected=devices.stream().anyMatch(DeviceAccess::selected);
    return new View(tenant,version,status,limit,count,graceEnd,selectedConnected?selected:null,selectedConnected?registration:null,List.copyOf(devices));
  }

  @Override public void requireEnrollmentSeat(String tenant,String existingDevice) {
    lockFamily(tenant);if(!family(tenant))return;
    View view=state(tenant);
    long occupied=connected(tenant).stream().filter(Connected::live).filter(d->!d.id().equals(existingDevice)).count();
    if(occupied>=view.effectiveDeviceLimit())throw new DomainException(HttpStatus.PAYMENT_REQUIRED,"FAMILY_DEVICE_LIMIT_REACHED");
  }

  @Override public void requireManagedChange(String tenant,List<String> devices,boolean relaxing) {
    lockFamily(tenant);if(!family(tenant) || relaxing)return;
    View view=state(tenant);
    for(String id:devices) {
      var found=view.devices().stream().filter(d->id.equals(d.id())).findFirst();
      if(found.isEmpty() || !List.of("BASIC","MEMBER").contains(found.get().access()))
        throw new DomainException(HttpStatus.PAYMENT_REQUIRED,"FAMILY_DEVICE_RECOVERY_ONLY");
    }
  }

  @Override public void requireAdvancedService(String tenant,List<String> devices) {
    lockFamily(tenant);if(!family(tenant))return;
    View view=state(tenant);
    if(!"PAID".equals(view.status()) || devices.stream().anyMatch(id->view.devices().stream().noneMatch(d->id.equals(d.id()) && "MEMBER".equals(d.access()))))
      throw new DomainException(HttpStatus.PAYMENT_REQUIRED,"ENTITLEMENT_REQUIRED");
  }

  private List<Connected> connected(String tenant) {
    var reservations=jdbc.queryForList("SELECT device_id FROM device_enrollments WHERE tenant_id=? AND state='AWAITING_CONFIRMATION' AND expires_at>? ORDER BY id FOR UPDATE",String.class,tenant,clock.millis());
    return jdbc.query("SELECT d.id,d.registration_id,d.display_name,d.subject_id,s.nickname,d.state,d.created_at,s.archived_at"
        +" FROM devices d JOIN subjects s ON s.tenant_id=d.tenant_id AND s.id=d.subject_id WHERE d.tenant_id=? AND d.platform='ANDROID'"
        +" AND d.state IN ('ACTIVE','AWAITING_CONFIRMATION') ORDER BY d.id FOR UPDATE",
        (r,i)->new Connected(r.getString(1),r.getString(2),r.getString(3),r.getString(4),r.getString(5),r.getString(6),r.getLong(7),"ACTIVE".equals(r.getString(6)) || reservations.contains(r.getString(1)),r.getObject(8)!=null),tenant)
        .stream().sorted(Comparator.comparingLong(Connected::createdAt).thenComparing(Connected::id)).toList();
  }

  /** Immutable source revisions retain actual past coverage, even when the first read is late. */
  private Membership membership(String tenant) {
    return membership(tenant,true);
  }

  @Override @Transactional(readOnly=true,timeout=10)
  public FamilySubscriptionReminders.Window current(String tenant) {
    return reminderWindow(tenant,false);
  }

  @Override @Transactional(timeout=10)
  public FamilySubscriptionReminders.Window lockCurrent(String tenant) {
    lockFamily(tenant);
    return reminderWindow(tenant,true);
  }

  private FamilySubscriptionReminders.Window reminderWindow(String tenant,boolean lock) {
    if(!family(tenant))throw DomainException.denied();
    Membership membership=membership(tenant,lock);
    Long ended=membership.endedAt();
    Long grace=ended==null?null:Instant.ofEpochMilli(ended).atZone(FAMILY_ZONE).plusDays(7).toInstant().toEpochMilli();
    var selections=jdbc.query("SELECT selection_anchor FROM family_device_access_accounts WHERE tenant_id=?"+(lock?" FOR UPDATE":""),
        (r,i)->(Long)r.getObject(1),tenant);
    Long selected=selections.isEmpty()?null:selections.get(0);
    int connected=jdbc.queryForList("SELECT d.id FROM devices d JOIN subjects s ON s.tenant_id=d.tenant_id AND s.id=d.subject_id WHERE d.tenant_id=? AND d.platform='ANDROID' AND d.state='ACTIVE' AND s.archived_at IS NULL ORDER BY d.id"+(lock?" FOR UPDATE":""),String.class,tenant).size();
    return new FamilySubscriptionReminders.Window(membership.activeEnd(),ended,grace,
        ended!=null && clock.millis()<grace && !Objects.equals(ended,selected) && connected>1);
  }

  private Membership membership(String tenant,boolean lock) {
    String suffix=lock?" FOR UPDATE":"";
    var events=jdbc.query("SELECT source_system,source_key,source_revision,active_from,expires_at,state,verified_at FROM commercial_source_events WHERE tenant_id=? AND capacity_kind='BASE' AND device_capacity>0 ORDER BY source_system,source_key,source_revision"+suffix,
        (r,i)->new Source(r.getString(1),r.getString(2),r.getLong(3),r.getLong(4),r.getLong(5),r.getString(6),r.getLong(7)),tenant);
    var refunds=new HashMap<String,Long>();
    jdbc.query("SELECT o.id,r.refunded_at FROM family_orders o JOIN family_refund_requests r ON r.order_id=o.id WHERE o.tenant_id=? AND r.status='REFUNDED' AND r.refunded_at IS NOT NULL ORDER BY o.id"+suffix,r->{
      refunds.put(FamilySubscriptionService.hash("WECHAT_PAY\u0000"+r.getString(1)),r.getLong(2));
    },tenant);
    Map<String,List<Source>> sources=new HashMap<>();
    for(var e:events)sources.computeIfAbsent(e.system()+":"+e.key(),ignored->new ArrayList<>()).add(e);
    // Imported ledgers may not have immutable revisions yet.
    for(var source:jdbc.query("SELECT source_system,source_key,source_revision,active_from,expires_at,state,verified_at FROM commercial_sources WHERE tenant_id=? AND capacity_kind='BASE' AND device_capacity>0 ORDER BY source_system,source_key"+suffix,
        (r,i)->new Source(r.getString(1),r.getString(2),r.getLong(3),r.getLong(4),r.getLong(5),r.getString(6),r.getLong(7)),tenant))
      sources.putIfAbsent(source.system()+":"+source.key(),List.of(source));
    List<Interval> periods=new ArrayList<>();
    for(var revisions:sources.values())for(int i=0;i<revisions.size();i++) {
      Source source=revisions.get(i);
      if(!"ACTIVE".equals(source.state()))continue;
      long end=source.end();
      if(i+1<revisions.size()) {
        Source next=revisions.get(i+1);
        long effectiveChange="REVOKED".equals(next.state()) && "WECHAT_PAY".equals(next.system())
            ?Math.min(refunds.getOrDefault(next.key(),next.verifiedAt()),next.verifiedAt()):next.verifiedAt();
        end=Math.min(end,effectiveChange);
      }
      // An immediately refunded current purchase can have millisecond-equal start/end. It did
      // become effective; a scheduled purchase refunded before its start never did.
      if(end>=source.start())periods.add(new Interval(source.start(),end));
    }
    periods.sort(Comparator.comparingLong(Interval::start).thenComparingLong(Interval::end));
    List<Interval> merged=new ArrayList<>();
    for(var period:periods) {
      if(merged.isEmpty() || period.start()>merged.get(merged.size()-1).end())merged.add(period);
      else {var previous=merged.remove(merged.size()-1);merged.add(new Interval(previous.start(),Math.max(previous.end(),period.end())));}
    }
    Long ended=null;
    for(var period:merged) {
      if(period.start()<=clock.millis() && period.end()>clock.millis())return new Membership(true,null,period.end());
      if(period.end()<=clock.millis())ended=period.end();
    }
    return new Membership(false,ended,null);
  }

  private boolean family(String tenant){return "FAMILY".equals(jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?",String.class,tenant));}
  private static void canonical(String id){try{if(id==null || !UUID.fromString(id).toString().equals(id))throw new IllegalArgumentException();}catch(IllegalArgumentException invalid){throw DomainException.invalid("INVALID_RESOURCE_ID");}}
  private static DomainException conflict(String code){return new DomainException(HttpStatus.CONFLICT,code);}
  private record Head(long version,String hash,String device,String registration,Long selectionAnchor){}
  private record Connected(String id,String registration,String displayName,String subject,String subjectName,String state,long createdAt,boolean live,boolean archived){boolean selectable(){return "ACTIVE".equals(state) && !archived;}}
  private record Source(String system,String key,long revision,long start,long end,String state,long verifiedAt){}
  private record Interval(long start,long end){}
  private record Membership(boolean active,Long endedAt,Long activeEnd){}
}
