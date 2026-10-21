package com.aimanager.family;
import com.aimanager.commerce.CommercialCapacity;
import com.aimanager.identity.ActorKeys;
import com.aimanager.reporting.FamilyReportEvidence;
import com.aimanager.shared.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class FamilyAssistantService {
  private final FamilyAuthority authority;private final FamilyRulesService rules;private final FamilyAiGateway gateway;
  private final FamilyReportEvidence evidence;private final CommercialCapacity capacity;private final JdbcTemplate jdbc;private final ObjectMapper json;private final Clock clock;
  private final com.aimanager.commerce.FamilyDeviceAccess familyAccess;
  public FamilyAssistantService(FamilyAuthority authority,FamilyRulesService rules,FamilyAiGateway gateway,FamilyReportEvidence evidence,
      CommercialCapacity capacity,JdbcTemplate jdbc,ObjectMapper json,Clock clock,com.aimanager.commerce.FamilyDeviceAccess familyAccess){this.authority=authority;this.rules=rules;this.gateway=gateway;this.evidence=evidence;this.capacity=capacity;this.jdbc=jdbc;this.json=json;this.clock=clock;this.familyAccess=familyAccess;}
  public record Request(String task,String prompt,String subjectId,String deviceId,boolean cloudConsent){}
  public record Suggestion(String id,String task,String status,String summary,List<Map<String,Object>> evidence,List<String> limitations,
      FamilyRuleSpec ruleDraft,long expiresAt,String model,Integer remainingRequests){}
  @Transactional(timeout=25)
  public Suggestion generate(String tenant,String actor,Request request,String key){
    authority.write(tenant,actor);
    familyAccess.lockFamily(tenant);
    if(!request.cloudConsent())throw DomainException.invalid("AI_CONSENT_REQUIRED");
    if(request.task()==null || !Set.of("RULE_DRAFT","REPORT_EXPLANATION").contains(request.task()) || request.prompt()==null || request.prompt().isBlank() || request.prompt().length()>500)
      throw DomainException.invalid("INVALID_ASSISTANT_REQUEST");
    var current=rules.readForUpdate(tenant,actor,request.subjectId());
    if(capacity.currentForUpdate(tenant)==0)throw new DomainException(HttpStatus.PAYMENT_REQUIRED,"ENTITLEMENT_REQUIRED");
    if(key==null || !key.matches("[A-Za-z0-9_-]{1,100}"))throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
    String id=UUID.nameUUIDFromBytes((tenant+"\u0000"+actor+"\u0000"+key).getBytes(java.nio.charset.StandardCharsets.UTF_8)).toString();
    String requestHash=SecretMaterial.hash(encode(request));
    var old=jdbc.queryForList("SELECT result_json,expires_at,request_hash FROM family_ai_suggestions WHERE tenant_id=? AND id=? AND actor_key=? FOR UPDATE",tenant,id,ActorKeys.key(actor));
    if(!old.isEmpty()){
      if(!requestHash.equals(old.get(0).get("request_hash")))throw new DomainException(HttpStatus.CONFLICT,"IDEMPOTENCY_KEY_REUSED");
      if(((Number)old.get(0).get("expires_at")).longValue()<=clock.millis())throw new DomainException(HttpStatus.CONFLICT,"AI_SUGGESTION_EXPIRED");
      return decode((String)old.get(0).get("result_json"),Suggestion.class);
    }
    if(!gateway.available())return new Suggestion(id,request.task(),"FALLBACK","云端助手暂不可用，你仍可直接设置作息和查看报告。",List.of(),List.of("本次未调用云端模型，也未消耗AI次数。"),null,clock.millis()+86400000,null,null);
    boolean trial=jdbc.queryForList("SELECT source_key FROM commercial_sources WHERE tenant_id=? AND source_system='WECHAT_PAY' AND state='ACTIVE' AND active_from<=? AND expires_at>? FOR UPDATE",String.class,tenant,clock.millis(),clock.millis()).isEmpty();
    String month=trial?"TRIAL":YearMonth.now(clock.withZone(ZoneId.of("Asia/Shanghai"))).toString();
    jdbc.update("INSERT INTO family_ai_months(tenant_id,month_key,completed) VALUES(?,?,0) ON DUPLICATE KEY UPDATE tenant_id=tenant_id",tenant,month);
    int used=jdbc.queryForObject("SELECT completed FROM family_ai_months WHERE tenant_id=? AND month_key=? FOR UPDATE",Integer.class,tenant,month);
    int allowance=trial?10:100;
    if(used>=allowance)throw new DomainException(HttpStatus.TOO_MANY_REQUESTS,"AI_QUOTA_EXHAUSTED");
    var input=new LinkedHashMap<String,Object>();input.put("task",request.task());
    // Prevent accidental identifiers in the request; user text is not included in persistent logs.
    String minimized=request.prompt().replaceAll("(?<![0-9])1[3-9][0-9]{9}(?![0-9])","[手机号已隐藏]")
        .replaceAll("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}","[邮箱已隐藏]");
    for(String nickname:jdbc.queryForList("SELECT nickname FROM subjects WHERE tenant_id=?",String.class,tenant))
      if(nickname!=null&&!nickname.isBlank())minimized=minimized.replace(nickname,"孩子");
    input.put("request",minimized);
    input.put("currentRules",new FamilyRuleSpec(current.enabled(),current.dailyAllowanceSeconds(),current.timeZoneId(),current.meteredPackages(),current.allowedWindows()));
    Map<String,Object> report=null;
    if("REPORT_EXPLANATION".equals(request.task())){
      if(request.deviceId()==null)throw DomainException.invalid("ASSISTANT_DEVICE_REQUIRED");
      report=evidence.read(tenant,actor,request.subjectId(),request.deviceId());
      if(!"OBSERVED".equals(report.get("status")) || ((Number)report.get("coverageMillis")).longValue()*100<((Number)report.get("windowMillis")).longValue()*80)
        return new Suggestion(id,request.task(),"FALLBACK","当前记录不足，先检查设备授权和数据覆盖。",List.of(),List.of("没有把缺失记录当作零使用；本次未调用模型。"),null,clock.millis()+86400000,null,allowance-used);
      input.put("report",report);
    }
    Map<String,Object> output;
    try{output=gateway.suggest(input);}catch(DomainException failure){return new Suggestion(id,request.task(),"FALLBACK","云端助手暂时没有返回结果，请稍后重试或直接修改规则。",List.of(),List.of("本次未消耗AI次数。"),null,clock.millis()+86400000,null,allowance-used);}
    String summary=output.get("summary") instanceof String value?value:"";
    if(output.keySet().stream().anyMatch(k->!Set.of("summary","limitations","ruleDraft").contains(k)))throw DomainException.invalid("AI_RESPONSE_INVALID");
    if(summary.isBlank()||summary.length()>1500)throw DomainException.invalid("AI_RESPONSE_INVALID");
    FamilyRuleSpec draft=null;
    if(output.get("ruleDraft")!=null){
      if(!"RULE_DRAFT".equals(request.task()))throw DomainException.invalid("AI_RESPONSE_INVALID");
      try{draft=json.convertValue(output.get("ruleDraft"),FamilyRuleSpec.class).validated();}catch(Exception failure){throw DomainException.invalid("AI_RESPONSE_INVALID");}
      if(!current.meteredPackages().containsAll(draft.meteredPackages()))throw DomainException.invalid("AI_APPLICATION_NOT_AUTHORIZED");
    }
    if("RULE_DRAFT".equals(request.task()) && draft==null)return new Suggestion(id,request.task(),"FALLBACK",summary,List.of(),List.of("尚未生成可用规则草稿，请补充要求或手动设置；本次未计次。"),null,clock.millis()+86400000,null,allowance-used);
    var limits=new ArrayList<String>();limits.add("建议仅供家长确认，不会自动修改或发布规则。");
    if(output.get("limitations") instanceof List<?> items)for(Object item:items.stream().limit(5).toList())if(item instanceof String text && text.length()<=300)limits.add(text);
    var refs=new ArrayList<Map<String,Object>>();
    if(report!=null)refs.add(Map.of("label","数据覆盖毫秒","value",report.get("coverageMillis")));
    var result=new Suggestion(id,request.task(),"READY",summary,List.copyOf(refs),List.copyOf(limits),draft,clock.millis()+86400000,gateway.model(),allowance-used-1);
    authority.write(tenant,actor);
    jdbc.update("INSERT INTO family_ai_suggestions(tenant_id,id,actor_key,subject_id,rule_version,request_hash,task,result_json,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?)",tenant,id,ActorKeys.key(actor),request.subjectId(),current.version(),requestHash,request.task(),encode(result),clock.millis(),result.expiresAt());
    jdbc.update("UPDATE family_ai_months SET completed=completed+1 WHERE tenant_id=? AND month_key=?",tenant,month);
    return result;
  }
  @Transactional(timeout=10)
  public Map<String,Object> draft(String tenant,String actor,String id){
    authority.write(tenant,actor);
    familyAccess.lockFamily(tenant);
    if(capacity.currentForUpdate(tenant)==0)throw new DomainException(HttpStatus.PAYMENT_REQUIRED,"ENTITLEMENT_REQUIRED");
    var row=jdbc.queryForList("SELECT subject_id,rule_version,result_json,expires_at FROM family_ai_suggestions WHERE tenant_id=? AND id=? AND actor_key=? FOR UPDATE",tenant,id,ActorKeys.key(actor));
    if(row.isEmpty())throw DomainException.denied();var record=row.get(0);
    if(((Number)record.get("expires_at")).longValue()<=clock.millis())throw new DomainException(HttpStatus.CONFLICT,"AI_SUGGESTION_EXPIRED");
    var result=decode((String)record.get("result_json"),Suggestion.class);
    var current=rules.readForUpdate(tenant,actor,(String)record.get("subject_id"));
    if(current.version()!=((Number)record.get("rule_version")).longValue())throw new DomainException(HttpStatus.CONFLICT,"RESOURCE_VERSION_CONFLICT");
    if(result.ruleDraft()==null)throw DomainException.invalid("AI_RULE_DRAFT_UNAVAILABLE");
    return Map.of("subjectId",current.subjectId(),"ruleVersion",current.version(),"ruleDraft",result.ruleDraft(),"requiresConfirmation",true);
  }
  private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw new IllegalStateException("Assistant persistence failed");}}
  private <T>T decode(String value,Class<T> type){try{return json.readValue(value,type);}catch(Exception e){throw new IllegalStateException("Assistant persistence invalid");}}
}
