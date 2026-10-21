package com.aimanager.family;
import com.aimanager.commerce.FamilyAssistedActivationGate;
import com.aimanager.shared.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.*;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;

/** An operator-supplied acceptance list is required; self-reported health alone never opens sales. */
@Configuration
@ConditionalOnProperty(name="manager.family.acceptance.enabled",havingValue="true")
class FamilyAcceptanceConfiguration {
  record Profile(String manufacturer,String model,int apiLevel,long validUntil,String evidenceHash){}
  @Bean @Primary FamilyAssistedActivationGate acceptedFamilyActivation(JdbcTemplate jdbc,ObjectMapper json,Clock clock,
      @Value("${manager.family.acceptance.models-file:}")String file){
    List<Profile> profiles;
    try{var path=Path.of(file);if(file.isBlank()||Files.size(path)>65536)throw new IllegalArgumentException();
      profiles=List.of(json.readValue(Files.readString(path),Profile[].class));
      if(profiles.isEmpty()||profiles.size()>100 || profiles.stream().anyMatch(p->p.manufacturer()==null||p.model()==null||p.apiLevel()<24||p.evidenceHash()==null||!p.evidenceHash().matches("[0-9a-f]{64}")))throw new IllegalArgumentException();
    }catch(Exception failure){throw new IllegalArgumentException("Verified family model acceptance file required");}
    return (tenant,device)->{
      var rows=jdbc.queryForList("SELECT r.report_json,r.observed_at,d.registration_id FROM family_runtime_reports r JOIN devices d ON d.tenant_id=r.tenant_id AND d.id=r.device_id AND d.registration_id=r.registration_id WHERE r.tenant_id=? AND r.device_id=? AND d.state='ACTIVE' AND d.platform='ANDROID'",tenant,device);
      if(rows.size()!=1)throw unverified();
      try{
        var report=json.readTree((String)rows.get(0).get("report_json"));
        long observed=((Number)rows.get(0).get("observed_at")).longValue();
        if(observed<clock.millis()-300000 || observed>clock.millis() || !"ACTIVE".equals(report.path("health").asText())
            || !"HOME_RETURNED".equals(report.path("interventionStatus").asText()) || report.path("systemEnforced").asBoolean(true))throw unverified();
        var profile=profiles.stream().filter(p->p.validUntil()>clock.millis() && p.manufacturer().equals(report.path("manufacturer").asText())
            && p.model().equals(report.path("model").asText()) && p.apiLevel()==report.path("apiLevel").asInt()).findFirst().orElseThrow(FamilyAcceptanceConfiguration::unverified);
        var delivery=jdbc.queryForList("SELECT d.document_json FROM configuration_streams s JOIN configuration_deliveries d ON d.tenant_id=s.tenant_id AND d.id=s.delivery_id WHERE d.tenant_id=? AND d.device_id=? AND d.registration_id=? AND d.policy_id=? AND d.version_id=? AND d.source_sequence=?",tenant,device,rows.get(0).get("registration_id"),report.path("policyId").asText(),report.path("versionId").asText(),report.path("sourceSequence").asLong());
        if(delivery.size()!=1 || !json.readTree((String)delivery.get(0).get("document_json")).path("familyAssistance").path("enabled").asBoolean(false))throw unverified();
        return new FamilyAssistedActivationGate.VerifiedActivation(tenant,device,(String)rows.get(0).get("registration_id"),observed,
            SecretMaterial.hash((String)rows.get(0).get("report_json")+"\u0000"+profile.evidenceHash()));
      }catch(com.aimanager.shared.DomainException failure){throw failure;}catch(Exception failure){throw unverified();}
    };
  }
  private static DomainException unverified(){return new DomainException(HttpStatus.CONFLICT,"TRIAL_ACTIVATION_NOT_VERIFIED");}
}
