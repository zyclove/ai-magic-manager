package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
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

/** Real Spring MVC, authorization and SQL; JWT decoding is a fixture, not live identity-provider proof. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:schedule_presets;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc
class SchedulePresetJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate database;
  @MockitoBean JwtDecoder decoder;

  private RequestPostProcessor actor(String name) {
    return jwt().jwt(t -> t.subject(name).claim("auth_time", Instant.now().getEpochSecond())
        .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  @Test void examplesAreReadOnlyTenantAuthorizedAndSaveThroughExistingContract() throws Exception {
    String owner = "preset-" + UUID.randomUUID();
    String tenant = mapper.readTree(mvc.perform(post("/api/v1/tenants").with(actor(owner))
        .contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"示例验证\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
    String root = "/api/v1/tenants/" + tenant;
    for (var role : List.of("GUARDIAN", "ORG_ADMIN", "AUDITOR", "CHILD", "TEACHER")) {
      String member = owner + "-" + role;
      database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,?)",
          tenant, member, ActorKeys.key(member), role);
      mvc.perform(get(root + "/schedule-presets").with(actor(member)))
          .andExpect(role.equals("CHILD") || role.equals("TEACHER") ? status().isForbidden() : status().isOk());
    }
    mvc.perform(get(root + "/schedule-presets")).andExpect(status().isUnauthorized());
    mvc.perform(get(root + "/schedule-presets").with(actor("stranger"))).andExpect(status().isForbidden());
    String foreignOwner = owner + "-foreign";
    String foreignTenant = mapper.readTree(mvc.perform(post("/api/v1/tenants").with(actor(foreignOwner))
        .contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"另一家庭\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
    mvc.perform(get(root + "/schedule-presets").with(actor(foreignOwner))).andExpect(status().isForbidden());
    mvc.perform(get("/api/v1/tenants/" + foreignTenant + "/schedule-presets").with(actor(owner)))
        .andExpect(status().isForbidden());
    database.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",
        tenant, ActorKeys.key(owner + "-GUARDIAN"));
    mvc.perform(get(root + "/schedule-presets").with(actor(owner + "-GUARDIAN"))).andExpect(status().isForbidden());
    long before = database.queryForObject("SELECT COUNT(*) FROM schedule_definitions WHERE tenant_id=?", Long.class, tenant);
    var catalog = mapper.readTree(mvc.perform(get(root + "/schedule-presets").with(actor(owner)))
        .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(header().stringValues("Vary", org.hamcrest.Matchers.hasItem("Authorization")))
        .andReturn().getResponse().getContentAsString());
    assertThat(database.queryForObject("SELECT COUNT(*) FROM schedule_definitions WHERE tenant_id=?", Long.class, tenant))
        .isEqualTo(before);
    var definition = Map.of("timeZone", "Europe/Berlin", "weekly", catalog.get("items").get(0).get("weekly"),
        "exceptions", List.of(Map.of("date", "2026-10-25", "windows", List.of())));
    String payload = mapper.writeValueAsString(Map.of("name", "独立保存", "definition", definition));
    mvc.perform(post(root + "/schedules").with(actor(owner + "-AUDITOR"))
        .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isForbidden());
    String key = UUID.randomUUID().toString();
    var saved = mapper.readTree(mvc.perform(post(root + "/schedules").with(actor(owner))
        .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(payload))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    assertThat(saved.get("definition")).isEqualTo(mapper.valueToTree(definition));
    var recovered = mapper.readTree(mvc.perform(post(root + "/schedules/creation-results/" + key + "/query").with(actor(owner))
        .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isOk())
        .andReturn().getResponse().getContentAsString());
    assertThat(recovered).isEqualTo(saved);
    mvc.perform(get(root + "/schedules/" + saved.get("id").asText()).with(actor(owner)))
        .andExpect(status().isOk()).andExpect(jsonPath("$.definition.timeZone").value("Europe/Berlin"));
    assertThat(database.queryForObject("SELECT COUNT(*) FROM schedule_definitions WHERE tenant_id=?", Long.class, tenant))
        .isEqualTo(before + 1);
  }
}
