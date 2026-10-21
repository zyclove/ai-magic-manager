package com.aimanager.commerce.internal;

import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import java.time.*;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

@SpringBootTest(properties={
    "spring.datasource.url=jdbc:h2:mem:family-expiry-services;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "manager.exports.worker.enabled=false","manager.report-jobs.worker.enabled=false"})
@AutoConfigureMockMvc
class FamilyExpiryServicesJourneyTest {
  @Autowired org.springframework.test.web.servlet.MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired CommercialLedger ledger;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean Clock clock;
  String tenant,subject,device,owner;
  long now=Instant.parse("2026-02-10T02:00:00Z").toEpochMilli();
  long today=Instant.parse("2026-02-09T16:00:00Z").toEpochMilli();

  @BeforeEach void setup() {
    when(clock.millis()).thenReturn(now);when(clock.instant()).thenReturn(Instant.ofEpochMilli(now));
    when(clock.getZone()).thenReturn(ZoneId.of("UTC"));
    tenant=UUID.randomUUID().toString();subject=UUID.randomUUID().toString();device=UUID.randomUUID().toString();owner="expiry-"+UUID.randomUUID();
    db.update("INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Expiry','FAMILY','Asia/Shanghai',?)",tenant,now);
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'OWNER')",tenant,owner,ActorKeys.key(owner));
    db.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'Child','AGE_7_12',?)",tenant,subject,now);
    db.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,device,subject,UUID.randomUUID().toString(),"Device",now);
  }
  String base(){return "/api/v1/tenants/"+tenant;}
  org.springframework.test.web.servlet.ResultActions report(long from,String zone)throws Exception {
    return mvc.perform(get(base()+"/usage-reports").with(jwt().jwt(t->t.subject(owner)))
        .param("deviceId",device).param("from",Long.toString(from)).param("to",Long.toString(now)).param("timeZone",zone));
  }
  void paid(long end){ledger.apply(new CommercialFact(tenant,CommercialFact.SourceSystem.CONTRACT,"history",1,"FAMILY",CommercialFact.CapacityKind.BASE,3,
      Set.of(CommercialFact.Feature.FAMILY_MULTI_DEVICE),now-86400000,end,CommercialFact.State.ACTIVE,"a".repeat(64),"system:test"));}

  @Test void freeKeepsTodayButCannotReadHistoryOrBypassWithAnotherTimezone()throws Exception {
    report(today,"Asia/Shanghai").andExpect(status().isOk());
    report(today-1,"UTC").andExpect(status().isPaymentRequired()).andExpect(jsonPath("$.errorCode").value("ENTITLEMENT_REQUIRED"));
  }
  @Test void renewalRestoresHistoryAndExpiryStopsItWithoutRemovingToday()throws Exception {
    paid(now+60000);report(today-86400000,"Asia/Shanghai").andExpect(status().isOk());
    when(clock.millis()).thenReturn(now+120000);
    report(today-86400000,"Asia/Shanghai").andExpect(status().isPaymentRequired());
    report(today,"Asia/Shanghai").andExpect(status().isOk());
  }
  @Test void organizationReportAccessKeepsItsExistingAuthority()throws Exception {
    db.update("UPDATE tenants SET kind='ORGANIZATION' WHERE id=?",tenant);
    report(today-86400000,"UTC").andExpect(status().isOk());
  }
  @Test void aPreviouslyGeneratedAiDraftCannotBeLoadedAfterMembershipExpires()throws Exception {
    String suggestion=UUID.randomUUID().toString();
    String result="{\"id\":\""+suggestion+"\",\"task\":\"RULE_DRAFT\",\"status\":\"READY\",\"summary\":\"建议\",\"evidence\":[],\"limitations\":[],\"ruleDraft\":{\"enabled\":false,\"dailyAllowanceSeconds\":86400,\"timeZoneId\":\"Asia/Shanghai\",\"meteredPackages\":[],\"allowedWindows\":[]},\"expiresAt\":"+(now+86400000)+",\"model\":\"fixture\",\"remainingRequests\":99}";
    db.update("INSERT INTO family_ai_suggestions(tenant_id,id,actor_key,subject_id,rule_version,request_hash,task,result_json,created_at,expires_at) VALUES(?,?,?,?,0,?,'RULE_DRAFT',?,?,?)",
        tenant,suggestion,ActorKeys.key(owner),subject,"a".repeat(64),result,now,now+86400000);
    mvc.perform(post(base()+"/assistant/suggestions/"+suggestion+"/drafts").with(jwt().jwt(t->t.subject(owner))))
        .andExpect(status().isPaymentRequired()).andExpect(jsonPath("$.errorCode").value("ENTITLEMENT_REQUIRED"));
  }
}
