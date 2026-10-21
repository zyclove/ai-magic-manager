package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import com.aimanager.family.*;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.*;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.*;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Real HTTP/domain/SQL, with an explicit model boundary and fixture paid rights. No live vendor claims. */
@SpringBootTest(properties={"spring.datasource.url=jdbc:h2:mem:family-core;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "manager.family.rule-renewal.enabled=false","manager.exports.worker.enabled=false","manager.report-jobs.worker.enabled=false"})
@AutoConfigureMockMvc
class FamilyCoreJourneyTest {
  @Autowired MockMvc mvc; @Autowired JdbcTemplate jdbc; @Autowired ObjectMapper json;
  @MockitoBean JwtDecoder decoder; @MockitoBean FamilyAiGateway ai;
  String tenant,owner,subject; long now;
  final Map<String,Object> spec=Map.of("enabled",true,"dailyAllowanceSeconds",1800,"timeZoneId","Asia/Shanghai",
      "meteredPackages",List.of("com.example.game"),"allowedWindows",List.of());
  @BeforeEach void family() throws Exception {
    now=Instant.now().toEpochMilli();owner="core-"+UUID.randomUUID();
    tenant=body(mvc.perform(post("/api/v1/family-onboarding").with(adult(owner)).header("Idempotency-Key",UUID.randomUUID().toString())
      .contentType(MediaType.APPLICATION_JSON).content("{\"adultGuardian\":true,\"declarationVersion\":\"family-guardian-v1\"}"))
      .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("id").asText();
    subject=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,?,'AGE_7_12',?)",tenant,subject,"小明",now);
    jdbc.update("INSERT INTO commercial_accounts(tenant_id,version) VALUES(?,1)",tenant);
    jdbc.update("INSERT INTO commercial_sources(tenant_id,source_system,source_key,source_revision,product_key,capacity_kind,device_capacity,features_json,active_from,expires_at,state,payload_hash,evidence_hash,verified_by,verified_at) VALUES(?,'TRIAL',?,1,'FAMILY_SUBSCRIPTION','BASE',3,?,?,?,'ACTIVE',?,?,?,?)",
      tenant,UUID.randomUUID().toString(),"[\"AI_INSIGHTS\",\"FAMILY_MULTI_DEVICE\",\"FAMILY_ASSISTED_LIMITS\"]",now-1000,now+86400000,"a".repeat(64),"b".repeat(64),"test-fixture",now);
    when(ai.available()).thenReturn(true);when(ai.model()).thenReturn("fixture-not-live");
  }
  @Test void consumerOnboardingRequiresVerifiedPhoneAndRecordsDeclarationIdempotently() throws Exception {
    String actor="new-"+UUID.randomUUID(),key=UUID.randomUUID().toString();
    String declaration="{\"adultGuardian\":true,\"declarationVersion\":\"family-guardian-v1\"}";
    mvc.perform(post("/api/v1/family-onboarding").with(jwt().jwt(j->j.subject(actor)))
      .header("Idempotency-Key",key).contentType(MediaType.APPLICATION_JSON).content(declaration))
      .andExpect(status().isPreconditionRequired());
    mvc.perform(post("/api/v1/family-onboarding").with(adult(actor)).header("Idempotency-Key",key)
      .contentType(MediaType.APPLICATION_JSON).content("{\"adultGuardian\":false,\"declarationVersion\":\"family-guardian-v1\"}"))
      .andExpect(status().isBadRequest());
    String first=mvc.perform(post("/api/v1/family-onboarding").with(adult(actor)).header("Idempotency-Key",key)
      .contentType(MediaType.APPLICATION_JSON).content(declaration)).andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
    mvc.perform(post("/api/v1/family-onboarding").with(adult(actor)).header("Idempotency-Key",key)
      .contentType(MediaType.APPLICATION_JSON).content(declaration)).andExpect(status().isCreated()).andExpect(jsonPath("$.id").value(body(first).path("id").asText()));
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_guardian_declarations WHERE tenant_id=?",Integer.class,body(first).path("id").asText())).isEqualTo(1);
  }
  @Test void phoneGuardianCanCreateChildAndPairWhileOrganizationStillRequiresMfa() throws Exception {
    mvc.perform(post(base()+"/subjects/changes").with(adult(owner)).header("Idempotency-Key",UUID.randomUUID().toString())
      .contentType(MediaType.APPLICATION_JSON).content("{\"operation\":\"CREATE\",\"nickname\":\"小雨\",\"ageBand\":\"AGE_7_12\"}"))
      .andExpect(status().isOk()).andExpect(jsonPath("$.nickname").value("小雨"));
    mvc.perform(post(base()+"/enrollments").with(adult(owner)).header("Client-Request-Id",UUID.randomUUID().toString())
      .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of("subjectId",subject,"requestedMode","BYOD","platform","ANDROID"))))
      .andExpect(status().isCreated());
    String organization=body(mvc.perform(post("/api/v1/tenants").with(adult(owner)).contentType(MediaType.APPLICATION_JSON)
      .content("{\"name\":\"机构\",\"kind\":\"ORGANIZATION\",\"timeZone\":\"Asia/Shanghai\"}"))
      .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("id").asText();
    mvc.perform(post("/api/v1/tenants/"+organization+"/subjects/changes").with(adult(owner)).header("Idempotency-Key",UUID.randomUUID().toString())
      .contentType(MediaType.APPLICATION_JSON).content("{\"operation\":\"CREATE\",\"nickname\":\"学生\",\"ageBand\":\"AGE_7_12\"}"))
      .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
  }
  @Test void twoDeviceApprovalsKeepContentRevisionAndReplayingDoesNotExtendAbsoluteGrant() throws Exception {
    var first=device();var second=device(); save(spec,0,"initial");
    String requestA=submit(first,900),requestB=submit(second,900);
    mvc.perform(get(base()+"/family-dashboard").with(adult(owner))).andExpect(status().isOk()).andExpect(jsonPath("$.pendingRequestCount").value(2));
    String path=base()+"/family-access-requests/"+requestA+"/decision";
    String command="{\"decision\":\"APPROVE\",\"grantedSeconds\":600}";
    var firstResult=body(mvc.perform(post(path).with(adult(owner)).header("If-Match","\"0\"").header("Idempotency-Key","decision-a")
      .contentType(MediaType.APPLICATION_JSON).content(command)).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    mvc.perform(post(path).with(adult(owner)).header("If-Match","\"0\"").header("Idempotency-Key","decision-a")
      .contentType(MediaType.APPLICATION_JSON).content(command)).andExpect(status().isOk()).andExpect(jsonPath("$.notAfter").value(firstResult.path("notAfter").asLong()));
    mvc.perform(post(base()+"/family-access-requests/"+requestB+"/decision").with(adult(owner)).header("If-Match","\"0\"").header("Idempotency-Key","decision-b")
      .contentType(MediaType.APPLICATION_JSON).content(command)).andExpect(status().isOk());
    assertThat(jdbc.queryForObject("SELECT version FROM family_rules WHERE tenant_id=? AND subject_id=?",Long.class,tenant,subject)).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT source_sequence FROM family_rules WHERE tenant_id=? AND subject_id=?",Long.class,tenant,subject)).isEqualTo(3);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_temporary_grants WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(2);
    mvc.perform(get(base()+"/family-dashboard").with(adult(owner))).andExpect(status().isOk()).andExpect(jsonPath("$.pendingRequestCount").value(0));
    var document=body(jdbc.queryForObject("SELECT d.document_json FROM configuration_deliveries d JOIN configuration_streams s ON s.tenant_id=d.tenant_id AND s.delivery_id=d.id WHERE d.tenant_id=? AND d.device_id=?",String.class,tenant,first.id()));
    assertThat(document.path("familyAssistance").path("exceptionUntil").asLong()).isEqualTo(firstResult.path("notAfter").asLong());
    mvc.perform(get(base()+"/family-access-requests/"+requestA).with(jwt().jwt(j->j.subject("outsider")))).andExpect(status().isForbidden());
    mvc.perform(get("/api/v1/device-api/family/access-requests/"+requestA).header("Authorization","Bearer "+second.token())).andExpect(status().isNotFound());
  }
  @Test void newRuleContentInvalidatesOldRequestAndExpiryStillAllowsDisablingRules() throws Exception {
    var device=device();save(spec,0,"initial");String request=submit(device,300);
    var relaxed=new LinkedHashMap<>(spec);relaxed.put("dailyAllowanceSeconds",3600);save(relaxed,1,"changed");
    mvc.perform(post(base()+"/family-access-requests/"+request+"/decision").with(adult(owner)).header("If-Match","\"0\"").header("Idempotency-Key","old-rule-request")
      .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"APPROVE\",\"grantedSeconds\":300}")).andExpect(status().isConflict());
    jdbc.update("UPDATE commercial_sources SET expires_at=? WHERE tenant_id=?",now-1,tenant);
    var furtherRelaxed=new LinkedHashMap<>(relaxed);furtherRelaxed.put("dailyAllowanceSeconds",7200);save(furtherRelaxed,2,"relax-without-payment");
    mvc.perform(put(base()+"/subjects/"+subject+"/family-rules").with(adult(owner)).header("If-Match","\"3\"").header("Idempotency-Key","tighten-without-payment")
      .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(spec))).andExpect(status().isPaymentRequired());
    var disabled=new LinkedHashMap<>(furtherRelaxed);disabled.put("enabled",false);save(disabled,3,"recover-without-payment");
    mvc.perform(get(base()+"/subjects/"+subject+"/family-rules").with(adult(owner))).andExpect(status().isOk()).andExpect(jsonPath("$.enabled").value(false));
  }
  @Test void aiIsMinimizedIdempotentChargedOnceAndDraftConflictsAfterManualChange() throws Exception {
    save(spec,0,"initial");when(ai.suggest(anyMap())).thenReturn(Map.of("summary","建议每天最多半小时","limitations",List.of(),"ruleDraft",spec));
    String path=base()+"/assistant/suggestions",input=json.writeValueAsString(Map.of("task","RULE_DRAFT","prompt","小明的手机号13912345678，游戏半小时","subjectId",subject,"cloudConsent",true));
    var result=body(mvc.perform(post(path).with(adult(owner)).header("Idempotency-Key","ai-one").contentType(MediaType.APPLICATION_JSON).content(input))
      .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("READY")).andReturn().getResponse().getContentAsString());
    mvc.perform(post(path).with(adult(owner)).header("Idempotency-Key","ai-one").contentType(MediaType.APPLICATION_JSON).content(input)).andExpect(status().isOk()).andExpect(jsonPath("$.id").value(result.path("id").asText()));
    mvc.perform(post(path).with(adult(owner)).header("Idempotency-Key","ai-one").contentType(MediaType.APPLICATION_JSON).content(input.replace("游戏半小时","游戏一小时"))).andExpect(status().isConflict());
    ArgumentCaptor<Map<String,Object>> captured=ArgumentCaptor.forClass(Map.class);verify(ai,times(1)).suggest(captured.capture());
    String sent=json.writeValueAsString(captured.getValue());assertThat(sent).doesNotContain("小明","13912345678",subject,tenant,owner);
    assertThat(jdbc.queryForObject("SELECT completed FROM family_ai_months WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
    mvc.perform(post(path+"/"+result.path("id").asText()+"/drafts").with(adult(owner))).andExpect(status().isOk()).andExpect(jsonPath("$.requiresConfirmation").value(true));
    var changed=new LinkedHashMap<>(spec);changed.put("dailyAllowanceSeconds",3600);save(changed,1,"manual-change");
    mvc.perform(post(path+"/"+result.path("id").asText()+"/drafts").with(adult(owner))).andExpect(status().isConflict());
  }
  @Test void unauthorizedAiApplicationIsRejectedWithoutChargingAndUnavailableModelIsTruthful() throws Exception {
    save(spec,0,"initial");var unauthorized=new LinkedHashMap<>(spec);unauthorized.put("meteredPackages",List.of("com.unapproved.app"));
    when(ai.suggest(anyMap())).thenReturn(Map.of("summary","建议","ruleDraft",unauthorized));
    String input=json.writeValueAsString(Map.of("task","RULE_DRAFT","prompt","游戏半小时","subjectId",subject,"cloudConsent",true));
    mvc.perform(post(base()+"/assistant/suggestions").with(adult(owner)).header("Idempotency-Key","ai-invalid")
      .contentType(MediaType.APPLICATION_JSON).content(input)).andExpect(status().isBadRequest());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_ai_suggestions WHERE tenant_id=?",Integer.class,tenant)).isZero();
    when(ai.available()).thenReturn(false);
    mvc.perform(post(base()+"/assistant/suggestions").with(adult(owner)).header("Idempotency-Key","ai-unavailable")
      .contentType(MediaType.APPLICATION_JSON).content(input)).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("FALLBACK")).andExpect(jsonPath("$.ruleDraft").isEmpty());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_ai_suggestions WHERE tenant_id=?",Integer.class,tenant)).isZero();
  }
  record DeviceFixture(String id,String registration,String token){}
  DeviceFixture device(){String id=UUID.randomUUID().toString(),registration=UUID.randomUUID().toString(),token=SecretMaterial.token();
    jdbc.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}',?,?)",tenant,id,subject,registration,"手机","a".repeat(64),now);
    jdbc.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,TRUE)",tenant,registration,id);
    jdbc.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,TRUE,?,?)",UUID.randomUUID().toString(),tenant,id,registration,SecretMaterial.hash(token),now,now+3600000);return new DeviceFixture(id,registration,token);}
  String submit(DeviceFixture device,int seconds)throws Exception {String id=UUID.randomUUID().toString();mvc.perform(post("/api/v1/device-api/family/access-requests").header("Authorization","Bearer "+device.token()).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of("requestId",id,"requestedSeconds",seconds,"reason","想完成这一局")))).andExpect(status().isOk());return id;}
  void save(Map<String,?> value,long version,String key)throws Exception {mvc.perform(put(base()+"/subjects/"+subject+"/family-rules").with(adult(owner)).header("If-Match","\""+version+"\"").header("Idempotency-Key",key).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(value))).andExpect(status().isOk());}
  RequestPostProcessor adult(String id){return jwt().jwt(j->j.subject(id).claim("phone_number","+8613912345678").claim("phone_number_verified",true).claim("auth_time",Instant.now().getEpochSecond()).claim("amr",List.of("sms"))).authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));}
  String base(){return "/api/v1/tenants/"+tenant;}
  JsonNode body(String text)throws Exception{return json.readTree(text);}
}
