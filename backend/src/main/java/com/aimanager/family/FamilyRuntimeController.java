package com.aimanager.family;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

@RestController
class FamilyRuntimeController {
  private final DeviceAccess devices;private final JdbcTemplate jdbc;private final ObjectMapper json;private final Clock clock;
  FamilyRuntimeController(DeviceAccess devices,JdbcTemplate jdbc,ObjectMapper json,Clock clock){this.devices=devices;this.jdbc=jdbc;this.json=json;this.clock=clock;}
  record Report(String tenantId,String deviceId,String registrationId,String policyId,String versionId,long sourceSequence,
      long reportSequence,long observedAt,String health,String limitStatus,String reason,Long remainingSeconds,
      boolean optedIn,boolean usageGranted,boolean accessibilityConnected,boolean systemEnforced,
      String manufacturer,String model,Integer apiLevel,String interventionStatus){}
  @PostMapping("/api/v1/device-api/family/assisted-execution-reports")
  @Transactional(timeout=10)
  ResponseEntity<Map<String,Object>> accept(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal,@RequestBody Report report){
    var identity=DeviceContext.from(principal);var device=devices.lockActive(identity);
    if(!identity.tenantId().equals(report.tenantId()) || !identity.deviceId().equals(report.deviceId()) || !identity.registrationId().equals(report.registrationId()))throw DomainException.denied();
    long now=clock.millis();
    if(report.systemEnforced() || report.reportSequence()<1 || report.sourceSequence()<1 || report.observedAt()>now+30000 || report.observedAt()<now-86400000
        || report.manufacturer()!=null && report.manufacturer().length()>100 || report.model()!=null && report.model().length()>100
        || report.apiLevel()!=null && (report.apiLevel()<24||report.apiLevel()>100)
        || report.interventionStatus()!=null && !Set.of("NOT_REQUIRED","HOME_RETURNED","ACTION_FAILED").contains(report.interventionStatus())
        || report.remainingSeconds()!=null && (report.remainingSeconds()<0||report.remainingSeconds()>86400)
        || report.reason()==null || !report.reason().matches("[a-zA-Z0-9_]{1,100}")
        || report.health()==null || !Set.of("ACTIVE","CONSENT_REQUIRED","PERMISSION_MISSING","CONFIGURATION_UNAVAILABLE","NATIVE_OBSERVATION_UNAVAILABLE","INITIALIZING","CLOCK_ANOMALY","EXPIRED","FOREGROUND_UNAVAILABLE","STORAGE_FAILURE","CONFIGURATION_INVALID","DISABLED").contains(report.health())
        || report.limitStatus()==null || !Set.of("ALLOW","RESTRICT","UNKNOWN").contains(report.limitStatus()))throw DomainException.invalid("INVALID_ASSISTED_REPORT");
    if("ACTIVE".equals(report.health()) && (!report.optedIn() || !report.usageGranted() || !report.accessibilityConnected()))throw DomainException.invalid("INVALID_ASSISTED_REPORT");
    Integer referenced=jdbc.queryForObject("SELECT COUNT(*) FROM configuration_streams s JOIN configuration_deliveries d ON d.tenant_id=s.tenant_id AND d.id=s.delivery_id WHERE d.tenant_id=? AND d.device_id=? AND d.registration_id=? AND d.policy_id=? AND d.version_id=? AND d.source_sequence=? AND d.document_json IS NOT NULL",Integer.class,
        identity.tenantId(),identity.deviceId(),identity.registrationId(),report.policyId(),report.versionId(),report.sourceSequence());
    if(referenced!=1)throw DomainException.invalid("ASSISTED_CONFIGURATION_STALE");
    var prior=jdbc.queryForList("SELECT report_sequence,registration_id,report_json FROM family_runtime_reports WHERE tenant_id=? AND device_id=? FOR UPDATE",identity.tenantId(),identity.deviceId());
    String encoded;try{encoded=json.writeValueAsString(report);}catch(Exception failure){throw DomainException.invalid("INVALID_ASSISTED_REPORT");}
    if(!prior.isEmpty() && identity.registrationId().equals(prior.get(0).get("registration_id"))){
      long previous=((Number)prior.get(0).get("report_sequence")).longValue();
      if(report.reportSequence()<previous || report.reportSequence()==previous&&!encoded.equals(prior.get(0).get("report_json")))throw new DomainException(HttpStatus.CONFLICT,"ASSISTED_REPORT_REPLAY");
      if(report.reportSequence()==previous)return accepted(now);
    }
    if(prior.isEmpty())jdbc.update("INSERT INTO family_runtime_reports(tenant_id,device_id,registration_id,report_sequence,observed_at,received_at,report_json) VALUES(?,?,?,?,?,?,?)",identity.tenantId(),identity.deviceId(),identity.registrationId(),report.reportSequence(),report.observedAt(),now,encoded);
    else jdbc.update("UPDATE family_runtime_reports SET registration_id=?,report_sequence=?,observed_at=?,received_at=?,report_json=? WHERE tenant_id=? AND device_id=?",identity.registrationId(),report.reportSequence(),report.observedAt(),now,encoded,identity.tenantId(),identity.deviceId());
    return accepted(now);
  }
  private ResponseEntity<Map<String,Object>> accepted(long now){return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(Map.of("accepted",true,"receivedAt",now,"evidenceStatus","AGENT_REPORTED_UNVERIFIED"));}
}
