package com.aimanager;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import java.util.UUID;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(properties={"spring.datasource.url=jdbc:h2:mem:family-experience;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE","manager.exports.worker.enabled=false"})
@AutoConfigureMockMvc
class FamilyExperienceJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @MockitoBean JwtDecoder decoder;
  @Test void familyDashboardHasTruthfulEmptyStateAndRejectsAnotherAdult() throws Exception {
    String owner="family-"+UUID.randomUUID();
    var actor=jwt().jwt(j->j.subject(owner)).authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    var created=mvc.perform(post("/api/v1/tenants").with(actor).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"我的家庭\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn();
    String tenant=json.readTree(created.getResponse().getContentAsString()).path("id").asText();
    mvc.perform(get("/api/v1/tenants/"+tenant+"/family-dashboard").with(actor))
        .andExpect(status().isOk()).andExpect(jsonPath("$.tenantId").value(tenant))
        .andExpect(jsonPath("$.children").isEmpty()).andExpect(jsonPath("$.systemEnforced").value(false))
        .andExpect(jsonPath("$.deviceAccess.status").value("FREE"))
        .andExpect(jsonPath("$.deviceAccess.effectiveDeviceLimit").value(1))
        .andExpect(jsonPath("$.deviceAccess.activeCount").value(0))
        .andExpect(header().string("Cache-Control",org.hamcrest.Matchers.containsString("no-store")));
    mvc.perform(get("/api/v1/tenants/"+tenant+"/family-dashboard").with(jwt().jwt(j->j.subject("stranger"))))
        .andExpect(status().isForbidden());
  }
  @Test void cloudAssistantRequiresExplicitConsentAndCurrentFamilyMembership() throws Exception {
    String owner="assistant-"+UUID.randomUUID();
    var actor=jwt().jwt(j->j.subject(owner)).authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    var created=mvc.perform(post("/api/v1/tenants").with(actor).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"我的家庭\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn();
    String tenant=json.readTree(created.getResponse().getContentAsString()).path("id").asText();
    mvc.perform(post("/api/v1/tenants/"+tenant+"/assistant/suggestions").with(actor).contentType(MediaType.APPLICATION_JSON)
        .content("{\"task\":\"RULE_DRAFT\",\"prompt\":\"工作日游戏最多半小时\",\"cloudConsent\":false}"))
        .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("AI_CONSENT_REQUIRED"));
    mvc.perform(post("/api/v1/tenants/"+tenant+"/assistant/suggestions").with(jwt().jwt(j->j.subject("stranger")))
        .contentType(MediaType.APPLICATION_JSON).content("{\"task\":\"RULE_DRAFT\",\"prompt\":\"半小时\",\"cloudConsent\":true}"))
        .andExpect(status().isForbidden());
  }
  @Test void temporaryFamilyRequestsAreAdultScoped() throws Exception {
    String owner="requests-"+UUID.randomUUID();
    var actor=jwt().jwt(j->j.subject(owner)).authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    var created=mvc.perform(post("/api/v1/tenants").with(actor).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"我的家庭\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn();
    String tenant=json.readTree(created.getResponse().getContentAsString()).path("id").asText();
    mvc.perform(get("/api/v1/tenants/"+tenant+"/family-access-requests").with(actor))
        .andExpect(status().isOk()).andExpect(jsonPath("$.items").isEmpty());
    mvc.perform(get("/api/v1/tenants/"+tenant+"/family-access-requests").with(jwt().jwt(j->j.subject("stranger"))))
        .andExpect(status().isForbidden());
  }
}
