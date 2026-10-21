package com.aimanager.overview.internal;
import com.aimanager.family.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController
class FamilyDashboardController {
  private final FamilyAuthority authority;
  private final FamilyRulesService rules;
  private final OverviewReadService overview;
  private final JdbcTemplate jdbc;
  private final ObjectMapper json;
  private final Clock clock;
  private final com.aimanager.commerce.FamilyDeviceAccess access;
  FamilyDashboardController(FamilyAuthority authority,FamilyRulesService rules,OverviewReadService overview,JdbcTemplate jdbc,ObjectMapper json,Clock clock,com.aimanager.commerce.FamilyDeviceAccess access){
    this.authority=authority;this.rules=rules;this.overview=overview;this.jdbc=jdbc;this.json=json;this.clock=clock;this.access=access;
  }
  @GetMapping("/api/v1/tenants/{tenant}/family-dashboard")
  @Transactional(timeout=10)
  ResponseEntity<Map<String,Object>> read(@AuthenticationPrincipal Jwt actor,@PathVariable String tenant){
    authority.write(tenant,actor.getSubject());
    var deviceAccess=access.state(tenant);
    var summary=overview.read(tenant,actor.getSubject());
    var children=jdbc.query("SELECT id,nickname,age_band FROM subjects WHERE tenant_id=? AND archived_at IS NULL ORDER BY created_at,id LIMIT 20",(row,index)->{
      String subject=row.getString(1);
      var devices=jdbc.query("SELECT id,display_name,registration_id,last_heartbeat_at FROM devices WHERE tenant_id=? AND subject_id=? AND state='ACTIVE' ORDER BY id LIMIT 20",(d,i)->{
        var item=new LinkedHashMap<String,Object>();
        item.put("id",d.getString(1));item.put("displayName",d.getString(2));item.put("registrationId",d.getString(3));item.put("lastHeartbeatAt",d.getObject(4));
        var reports=jdbc.queryForList("SELECT report_json,observed_at FROM family_runtime_reports WHERE tenant_id=? AND device_id=? AND registration_id=?",tenant,d.getString(1),d.getString(3));
        Map<String,Object> runtime=null;
        if(!reports.isEmpty()){
          try{runtime=json.readValue((String)reports.get(0).get("report_json"),new com.fasterxml.jackson.core.type.TypeReference<Map<String,Object>>(){});}
          catch(Exception failure){throw new IllegalStateException("Invalid runtime report");}
          long observed=((Number)reports.get(0).get("observed_at")).longValue();
          runtime.put("stale",clock.millis()-observed>300000);runtime.put("evidenceStatus","AGENT_REPORTED_UNVERIFIED");
        }
        item.put("runtime",runtime);item.put("ruleState",runtime==null?"UNKNOWN":Boolean.TRUE.equals(runtime.get("stale"))?"STALE":runtime.get("health"));
        return item;
      },tenant,subject);
      var child=new LinkedHashMap<String,Object>();child.put("id",subject);child.put("nickname",row.getString(2));child.put("ageBand",row.getString(3));
      child.put("devices",devices);child.put("rules",rules.read(tenant,actor.getSubject(),subject));return child;
    },tenant);
    authority.read(tenant,actor.getSubject());
    var result=new LinkedHashMap<String,Object>();result.put("tenantId",tenant);result.put("generatedAt",clock.millis());result.put("systemEnforced",false);
    long familyPending=jdbc.queryForObject("SELECT COUNT(*) FROM family_access_requests r JOIN devices d ON d.tenant_id=r.tenant_id AND d.id=r.device_id AND d.registration_id=r.registration_id JOIN subjects s ON s.tenant_id=r.tenant_id AND s.id=r.subject_id WHERE r.tenant_id=? AND r.state='PENDING' AND r.expires_at>? AND d.state='ACTIVE' AND s.archived_at IS NULL",Long.class,tenant,clock.millis());
    result.put("children",children);result.put("pendingRequestCount",familyPending);result.put("openHelpRequestCount",summary.openHelpRequestCount());
    result.put("deviceAccess",deviceAccess);
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).header("Vary","Authorization").body(result);
  }
}
