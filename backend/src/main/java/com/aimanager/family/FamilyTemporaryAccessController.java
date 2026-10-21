package com.aimanager.family;
import com.aimanager.audit.AuditService;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.shared.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

/** Family assistance requests have their own domain; they never create managed access leases. */
@RestController
class FamilyTemporaryAccessController {
  private final FamilyAuthority authority;private final DeviceAccess devices;private final JdbcTemplate jdbc;
  private final Clock clock;private final RecentAuthentication recent;private final FamilyRulesService rules;
  private final IdempotencyService idempotency;private final AuditService audit;private final ApplicationEventPublisher events;
  FamilyTemporaryAccessController(FamilyAuthority authority,DeviceAccess devices,JdbcTemplate jdbc,Clock clock,RecentAuthentication recent,
      FamilyRulesService rules,IdempotencyService idempotency,AuditService audit,ApplicationEventPublisher events){
    this.authority=authority;this.devices=devices;this.jdbc=jdbc;this.clock=clock;this.recent=recent;this.rules=rules;this.idempotency=idempotency;this.audit=audit;this.events=events;
  }
  record Submit(String requestId,int requestedSeconds,String reason){}
  record Decide(String decision,int grantedSeconds){}
  public record View(String id,String subjectId,String deviceId,String state,int requestedSeconds,Integer grantedSeconds,String reason,long expiresAt,Long notAfter,long version){}
  @PostMapping("/api/v1/device-api/family/access-requests")
  @Transactional(timeout=10)
  ResponseEntity<View> submit(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal,@RequestBody Submit request){
    var identity=DeviceContext.from(principal);var device=devices.lockActive(identity);
    if(!"FAMILY".equals(jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?",String.class,identity.tenantId())))throw DomainException.denied();
    if(request.requestId()==null || !request.requestId().matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") || request.requestedSeconds()<60 || request.requestedSeconds()>3600
        || request.reason()!=null && request.reason().length()>300)throw DomainException.invalid("INVALID_FAMILY_ACCESS_REQUEST");
    String reason=request.reason()==null?"":request.reason().strip();
    var old=jdbc.queryForList("SELECT id,registration_id,requested_seconds,reason FROM family_access_requests WHERE tenant_id=? AND id=?",identity.tenantId(),request.requestId());
    if(!old.isEmpty()){
      var existing=old.get(0);if(!identity.registrationId().equals(existing.get("registration_id")) || ((Number)existing.get("requested_seconds")).intValue()!=request.requestedSeconds() || !reason.equals(existing.get("reason")))throw new DomainException(HttpStatus.CONFLICT,"IDEMPOTENCY_KEY_REUSED");
      return result(read(identity.tenantId(),request.requestId()));
    }
    if(jdbc.queryForObject("SELECT COUNT(*) FROM family_access_requests WHERE tenant_id=? AND device_id=? AND state='PENDING' AND expires_at>?",Integer.class,identity.tenantId(),identity.deviceId(),clock.millis())>0)
      throw new DomainException(HttpStatus.CONFLICT,"FAMILY_REQUEST_ALREADY_PENDING");
    if(jdbc.queryForObject("SELECT COUNT(*) FROM family_access_requests WHERE tenant_id=? AND device_id=? AND created_at>?",Integer.class,identity.tenantId(),identity.deviceId(),clock.millis()-3600000)>=10)
      throw new DomainException(HttpStatus.TOO_MANY_REQUESTS,"FAMILY_REQUEST_RATE_LIMITED");
    var configured=jdbc.queryForList("SELECT version,rules_json FROM family_rules WHERE tenant_id=? AND subject_id=?",identity.tenantId(),device.subjectId());
    if(configured.isEmpty())throw DomainException.invalid("FAMILY_RULES_NOT_CONFIGURED");
    jdbc.update("INSERT INTO family_access_requests(tenant_id,id,subject_id,device_id,registration_id,base_rule_version,state,requested_seconds,reason,created_at,expires_at,version) VALUES(?,?,?,?,?,?,'PENDING',?,?,?,?,0)",
        identity.tenantId(),request.requestId(),device.subjectId(),device.id(),identity.registrationId(),configured.get(0).get("version"),request.requestedSeconds(),reason,clock.millis(),clock.millis()+3600000);
    event(identity.tenantId(),request.requestId(),device.subjectId(),device.id(),"FAMILY_REQUEST_PENDING");
    return result(read(identity.tenantId(),request.requestId()));
  }
  @GetMapping("/api/v1/tenants/{tenant}/family-access-requests")
  @Transactional(readOnly=true,timeout=10)
  ResponseEntity<ItemPage<View>> list(@AuthenticationPrincipal Jwt actor,@PathVariable String tenant,@RequestParam(defaultValue="20")int limit,@RequestParam(required=false)String cursor){
    authority.read(tenant,actor.getSubject());ItemPage.validate(limit,cursor);
    var rows=jdbc.query("SELECT * FROM family_access_requests WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?",(r,i)->map(r),tenant,cursor==null?"":cursor,limit+1);
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(ItemPage.from(rows,limit,View::id));
  }
  @PostMapping("/api/v1/tenants/{tenant}/family-access-requests/{id}/decision")
  @Transactional(timeout=10)
  ResponseEntity<View> decide(@AuthenticationPrincipal Jwt actor,@PathVariable String tenant,@PathVariable String id,@RequestHeader("If-Match")String version,
      @RequestHeader("Idempotency-Key")String key,@RequestBody Decide decision){
    authority.write(tenant,actor.getSubject());recent.requireForTenant(actor,tenant,jdbc);
    long expected=ResourceVersions.require(version);
    if(!Set.of("APPROVE","DENY").contains(decision.decision()) || decision.grantedSeconds()<0 || decision.grantedSeconds()>3600)throw DomainException.invalid("INVALID_FAMILY_DECISION");
    var result=idempotency.execute(tenant,actor.getSubject(),"family.access.decide",key,Map.of("id",id,"version",expected,"decision",decision),View.class,()->{
      var before=read(tenant,id);rules.lockSubject(tenant,actor.getSubject(),before.subjectId());
      var rows=jdbc.queryForList("SELECT * FROM family_access_requests WHERE tenant_id=? AND id=? FOR UPDATE",tenant,id);
      if(rows.isEmpty())throw DomainException.denied();var raw=rows.get(0);var current=read(tenant,id);
      ResourceVersions.check(expected,current.version());
      if(!"PENDING".equals(current.state()) || current.expiresAt()<=clock.millis())throw new DomainException(HttpStatus.CONFLICT,"FAMILY_REQUEST_NOT_PENDING");
      var device=devices.lockVisibleActive(tenant,actor.getSubject(),current.deviceId());
      if(!device.registrationId().equals(raw.get("registration_id")))throw DomainException.denied();
      boolean approve="APPROVE".equals(decision.decision());
      if(approve && (decision.grantedSeconds()<60||decision.grantedSeconds()>current.requestedSeconds()))throw DomainException.invalid("GRANT_EXCEEDS_REQUEST");
      Long end=approve?clock.millis()+decision.grantedSeconds()*1000L:null;
      if(approve){
        if(rules.read(tenant,actor.getSubject(),current.subjectId()).version()!=((Number)raw.get("base_rule_version")).longValue())throw new DomainException(HttpStatus.CONFLICT,"RESOURCE_VERSION_CONFLICT");
        jdbc.update("INSERT INTO family_temporary_grants(tenant_id,device_id,registration_id,subject_id,not_after,request_id) VALUES(?,?,?,?,?,?) ON DUPLICATE KEY UPDATE registration_id=VALUES(registration_id),subject_id=VALUES(subject_id),not_after=VALUES(not_after),request_id=VALUES(request_id)",tenant,device.id(),device.registrationId(),current.subjectId(),end,id);
        rules.republish(tenant,actor.getSubject(),current.subjectId());
      }
      jdbc.update("UPDATE family_access_requests SET state=?,granted_seconds=?,not_after=?,version=version+1 WHERE tenant_id=? AND id=?",approve?"APPROVED":"DENIED",approve?decision.grantedSeconds():null,end,tenant,id);
      audit.record(tenant,actor.getSubject(),"FAMILY_ACCESS_DECIDED",id);event(tenant,id,current.subjectId(),current.deviceId(),"FAMILY_REQUEST_DECIDED");
      return read(tenant,id);
    });return result(result);
  }
  @GetMapping("/api/v1/tenants/{tenant}/family-access-requests/{id}")
  @Transactional(readOnly=true,timeout=10)
  ResponseEntity<View> adultRead(@AuthenticationPrincipal Jwt actor,@PathVariable String tenant,@PathVariable String id){
    authority.read(tenant,actor.getSubject());return result(read(tenant,id));
  }
  @GetMapping("/api/v1/device-api/family/access-requests/{id}")
  @Transactional(timeout=10)
  ResponseEntity<View> deviceRead(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal,@PathVariable String id){
    var identity=DeviceContext.from(principal);devices.lockActive(identity);
    var rows=jdbc.queryForList("SELECT id FROM family_access_requests WHERE tenant_id=? AND id=? AND device_id=? AND registration_id=?",identity.tenantId(),id,identity.deviceId(),identity.registrationId());
    if(rows.isEmpty())throw new DomainException(HttpStatus.NOT_FOUND,"FAMILY_REQUEST_NOT_FOUND");
    return result(read(identity.tenantId(),id));
  }
  private View read(String tenant,String id){var rows=jdbc.query("SELECT * FROM family_access_requests WHERE tenant_id=? AND id=?",(r,i)->map(r),tenant,id);if(rows.isEmpty())throw DomainException.denied();return rows.get(0);}
  private View map(java.sql.ResultSet r)throws java.sql.SQLException{
    Long end=r.getObject("not_after")==null?null:r.getLong("not_after");String state=r.getString("state");
    if("PENDING".equals(state)&&r.getLong("expires_at")<=clock.millis() || "APPROVED".equals(state)&&end!=null&&end<=clock.millis())state="EXPIRED";
    return new View(r.getString("id"),r.getString("subject_id"),r.getString("device_id"),state,r.getInt("requested_seconds"),r.getObject("granted_seconds")==null?null:r.getInt("granted_seconds"),r.getString("reason"),r.getLong("expires_at"),end,r.getLong("version"));
  }
  private ResponseEntity<View> result(View view){return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(view);}
  private void event(String tenant,String id,String subject,String device,String kind){
    String eventId=UUID.nameUUIDFromBytes((id+"\u0000"+kind).getBytes(java.nio.charset.StandardCharsets.UTF_8)).toString();
    events.publishEvent(new com.aimanager.notification.FamilyAttentionEvent(tenant,eventId,subject,device,kind,clock.millis()));
  }
}
