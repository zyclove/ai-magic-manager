package com.aimanager.family;

import com.aimanager.audit.AuditService;
import com.aimanager.commerce.CommercialCapacity;
import com.aimanager.commerce.FamilyDeviceAccess;
import com.aimanager.delivery.FamilyConfigurationPublisher;
import com.aimanager.delivery.FamilyAssistanceDocument;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class FamilyRulesService {
  private final JdbcTemplate jdbc;
  private final FamilyAuthority authority;
  private final ObjectMapper json;
  private final Clock clock;
  private final AuditService audit;
  private final IdempotencyService idempotency;
  private final CommercialCapacity capacity;
  private final FamilyConfigurationPublisher publisher;
  private final FamilyDeviceAccess deviceAccess;
  public FamilyRulesService(JdbcTemplate jdbc,FamilyAuthority authority,ObjectMapper json,Clock clock,
      AuditService audit,IdempotencyService idempotency,CommercialCapacity capacity,FamilyConfigurationPublisher publisher,FamilyDeviceAccess deviceAccess){
    this.jdbc=jdbc;this.authority=authority;this.json=json;this.clock=clock;this.audit=audit;
    this.idempotency=idempotency;this.capacity=capacity;this.publisher=publisher;
    this.deviceAccess=deviceAccess;
  }
  public record View(String subjectId,long version,boolean enabled,int dailyAllowanceSeconds,String timeZoneId,
      List<String> meteredPackages,List<FamilyRuleSpec.Window> allowedWindows,String deliveryState){}
  public View read(String tenant,String actor,String subject){
    authority.read(tenant,actor);subject(tenant,subject,false);return stored(tenant,subject);
  }
  /** Mutation consumers need a current read after waiting for commercial and subject locks. */
  @Transactional(timeout=10)
  public View readForUpdate(String tenant,String actor,String subject){
    lockSubject(tenant,actor,subject);return stored(tenant,subject,true);
  }
  @Transactional(timeout=10)
  public View save(String tenant,String actor,String subject,FamilyRuleSpec input,long expected,String key){
    authority.write(tenant,actor);deviceAccess.lockFamily(tenant);subject(tenant,subject,true);
    if(key==null || key.isBlank())throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
    var spec=input.validated();
    return idempotency.execute(tenant,actor,"family.rules.save",key,Map.of("subject",subject,"expected",expected,"rules",spec),View.class,()->{
      View previous=stored(tenant,subject,true);
      if(previous.version()!=expected)throw new DomainException(HttpStatus.CONFLICT,"RESOURCE_VERSION_CONFLICT");
      long rights=capacity.currentForUpdate(tenant);
      boolean relaxing = relaxing(previous,spec);
      if(spec.enabled() && rights==0 && !relaxing && spec.dailyAllowanceSeconds()<86400)
        throw new DomainException(HttpStatus.PAYMENT_REQUIRED,"ENTITLEMENT_REQUIRED");
      var deviceIds=jdbc.queryForList("SELECT id FROM devices WHERE tenant_id=? AND subject_id=? AND state='ACTIVE' ORDER BY id FOR UPDATE",String.class,tenant,subject);
      if(!relaxing) {
        var manageable=deviceAccess.state(tenant).devices().stream().filter(d->List.of("BASIC","MEMBER").contains(d.access())).map(FamilyDeviceAccess.DeviceAccess::id).toList();
        var targets=deviceIds.stream().filter(manageable::contains).toList();
        if(!deviceIds.isEmpty() && targets.isEmpty())throw new DomainException(HttpStatus.PAYMENT_REQUIRED,"FAMILY_DEVICE_RECOVERY_ONLY");
        deviceAccess.requireManagedChange(tenant,targets,false);
        deviceIds=targets;
      }
      String policy=jdbc.query("SELECT policy_id FROM family_rules WHERE tenant_id=? AND subject_id=? FOR UPDATE",r->r.next()?r.getString(1):UUID.randomUUID().toString(),tenant,subject);
      long version=expected+1;
      var sequences=jdbc.queryForList("SELECT source_sequence FROM family_rules WHERE tenant_id=? AND subject_id=? FOR UPDATE",Long.class,tenant,subject);
      long sequence=sequences.isEmpty()?1:sequences.get(0)+1;
      String encoded=encode(spec);
      // A relaxation must not shorten another device's already-approved absolute release.
      if(!relaxing)for(String device:deviceIds)jdbc.update("DELETE FROM family_temporary_grants WHERE tenant_id=? AND device_id=?",tenant,device);
      if(expected==0)jdbc.update("INSERT INTO family_rules(tenant_id,subject_id,policy_id,version,source_sequence,rules_json,updated_at) VALUES(?,?,?,?,?,?,?)",tenant,subject,policy,version,sequence,encoded,clock.millis());
      else jdbc.update("UPDATE family_rules SET version=?,source_sequence=?,rules_json=?,updated_at=? WHERE tenant_id=? AND subject_id=?",version,sequence,encoded,clock.millis(),tenant,subject);
      if(!deviceIds.isEmpty()) {
        if(relaxing && spec.enabled()) {
          var allTargets=deviceIds;
          var allowed=deviceAccess.state(tenant).devices().stream().filter(d->allTargets.contains(d.id()) && List.of("BASIC","MEMBER").contains(d.access())).map(FamilyDeviceAccess.DeviceAccess::id).toList();
          publisher.publishRetainingExisting(tenant,actor,deviceIds,policy,sequence,document(spec),allowed,true);
        } else publisher.publish(tenant,actor,deviceIds,policy,sequence,document(spec));
      }
      audit.record(tenant,actor,"FAMILY_RULES_SAVED",subject);
      return view(subject,version,spec,deviceIds.isEmpty()?"NO_DEVICE":"CONFIGURED_NOT_ENFORCED");
    });
  }
  private void subject(String tenant,String subject,boolean lock){
    var rows=jdbc.queryForList("SELECT id FROM subjects WHERE tenant_id=? AND id=? AND archived_at IS NULL"+(lock?" FOR UPDATE":""),String.class,tenant,subject);
    if(rows.size()!=1)throw DomainException.denied();
  }
  public void lockSubject(String tenant,String actor,String subject){authority.write(tenant,actor);deviceAccess.lockFamily(tenant);subject(tenant,subject,true);}
  @Transactional(timeout=10)
  public void republish(String tenant,String actor,String subject){
    lockSubject(tenant,actor,subject);
    var previous=stored(tenant,subject,true);
    var spec=new FamilyRuleSpec(previous.enabled(),previous.dailyAllowanceSeconds(),previous.timeZoneId(),previous.meteredPackages(),previous.allowedWindows());
    String policy=jdbc.queryForObject("SELECT policy_id FROM family_rules WHERE tenant_id=? AND subject_id=? FOR UPDATE",String.class,tenant,subject);
    long sequence=jdbc.queryForObject("SELECT source_sequence FROM family_rules WHERE tenant_id=? AND subject_id=? FOR UPDATE",Long.class,tenant,subject)+1;
    jdbc.update("UPDATE family_rules SET source_sequence=?,updated_at=? WHERE tenant_id=? AND subject_id=?",sequence,clock.millis(),tenant,subject);
    var ids=jdbc.queryForList("SELECT id FROM devices WHERE tenant_id=? AND subject_id=? AND state='ACTIVE' ORDER BY id FOR UPDATE",String.class,tenant,subject);
    var allowed=deviceAccess.state(tenant).devices().stream().filter(d->ids.contains(d.id()) && List.of("BASIC","MEMBER").contains(d.access())).map(FamilyDeviceAccess.DeviceAccess::id).toList();
    if(!ids.isEmpty())publisher.publishRetainingExisting(tenant,actor,ids,policy,sequence,document(spec),allowed);
  }
  private FamilyAssistanceDocument document(FamilyRuleSpec spec){
    return new FamilyAssistanceDocument(1,"FAMILY_ASSISTED",spec.enabled(),spec.dailyAllowanceSeconds(),spec.timeZoneId(),spec.meteredPackages(),
        spec.allowedWindows().stream().map(w->new FamilyAssistanceDocument.Window(w.daysOfWeek(),w.startMinute(),w.endMinute())).toList(),clock.millis()+7L*86400000,null);
  }
  private boolean relaxing(View previous,FamilyRuleSpec next){
    if(!next.enabled())return true;
    if(!previous.enabled() || next.dailyAllowanceSeconds()<previous.dailyAllowanceSeconds()
        || !previous.meteredPackages().containsAll(next.meteredPackages()))return false;
    boolean[] before=minutes(previous.allowedWindows()),after=minutes(next.allowedWindows());
    for(int i=0;i<before.length;i++)if(before[i]&&!after[i])return false;
    return true;
  }
  private boolean[] minutes(List<FamilyRuleSpec.Window> windows){
    boolean[] result=new boolean[7*1440];
    if(windows.isEmpty()){java.util.Arrays.fill(result,true);return result;}
    for(var window:windows)for(int day:window.daysOfWeek()){
      int start=(day-1)*1440+window.startMinute(),duration=window.endMinute()-window.startMinute();
      if(duration<0)duration+=1440;
      for(int i=0;i<duration;i++)result[(start+i)%result.length]=true;
    }return result;
  }
  private View stored(String tenant,String subject){
    return stored(tenant,subject,false);
  }
  private View stored(String tenant,String subject,boolean lock){
    var rows=jdbc.query("SELECT version,rules_json FROM family_rules WHERE tenant_id=? AND subject_id=?"+(lock?" FOR UPDATE":""),(r,i)->{
      try{return view(subject,r.getLong(1),json.readValue(r.getString(2),FamilyRuleSpec.class),"CONFIGURED_NOT_ENFORCED");}
      catch(Exception e){throw new IllegalStateException("Invalid family rule record");}
    },tenant,subject);
    return rows.isEmpty()?view(subject,0,new FamilyRuleSpec(false,86400,"Asia/Shanghai",List.of(),List.of()),"NOT_CONFIGURED"):rows.get(0);
  }
  private View view(String subject,long version,FamilyRuleSpec s,String state){return new View(subject,version,s.enabled(),s.dailyAllowanceSeconds(),s.timeZoneId(),s.meteredPackages(),s.allowedWindows(),state);}
  private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw new IllegalStateException("Cannot encode family rules");}}
}
