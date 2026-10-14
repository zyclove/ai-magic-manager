package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;
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

@SpringBootTest(properties = {"spring.datasource.url=jdbc:h2:mem:quota_plan_recovery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password="})
@AutoConfigureMockMvc
class QuotaPlanRecoveryTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;

  RequestPostProcessor actor(String subject, boolean recent) {
    return jwt().jwt(t -> t.subject(subject).claim("auth_time", recent ? Instant.now().getEpochSecond() : 1L)
        .claim("amr", recent ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  JsonNode mutate(String path, String actor, String key, Integer version, String body, int status) throws Exception {
    var request = (version == null ? post(path) : put(path)).with(actor(actor, true))
        .contentType(MediaType.APPLICATION_JSON).content(body);
    if (key != null) request.header("Idempotency-Key", key);
    if (version != null) request.header("If-Match", "\"" + version + "\"");
    return json.readTree(mvc.perform(request).andExpect(status().is(status)).andReturn().getResponse().getContentAsString());
  }

  @Test void recoverOriginalAndLatestWithCurrentScopeAndExactBodyWithoutReplayingWrites() throws Exception {
    String owner = "plan-recovery-" + UUID.randomUUID();
    String tenant = mutate("/api/v1/tenants", owner, null, null,
        "{\"name\":\"Plan recovery\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}", 201).get("id").asText();
    String root = "/api/v1/tenants/" + tenant;
    String subject = mutate(root + "/subjects", owner, null, null,
        "{\"nickname\":\"Child\",\"ageBand\":\"AGE_7_12\"}", 201).get("id").asText();
    var weekly = new TreeMap<String, Long>();
    for (var day : DayOfWeek.values()) weekly.put(day.name(), 3600L);
    String input = json.writeValueAsString(Map.of("name", "Weekly", "subjectId", subject, "scope", "TOTAL",
        "timeZone", "UTC", "effectiveFrom", LocalDate.now(ZoneOffset.UTC).toString(), "weeklyLimits", weekly, "dateOverrides", Map.of()));
    String createKey = UUID.randomUUID().toString();
    var created = mutate(root + "/quota-plans", owner, createKey, null, input, 201);
    String planId = created.get("id").asText(), path = root + "/quota-plans/" + planId;
    String paused = json.writeValueAsString(Map.of("name", "Weekly", "state", "PAUSED", "weeklyLimits", weekly, "dateOverrides", Map.of()));
    String updateKey = UUID.randomUUID().toString();
    var saved = mutate(path, owner, updateKey, 0, paused, 200);
    mutate(path, owner, UUID.randomUUID().toString(), 1, paused.replace("PAUSED", "ACTIVE"), 200);
    String creationPath = root + "/quota-plans/creation-results/" + createKey + "/query";
    String updatePath = path + "/update-results/" + updateKey + "/query";
    var result = json.readTree(mvc.perform(post(creationPath).with(actor(owner, false))
        .contentType(MediaType.APPLICATION_JSON).content(input)).andExpect(status().isOk())
        .andExpect(header().string("Cache-Control", "no-store")).andReturn().getResponse().getContentAsString());
    assertThat(result.get("operation").asText()).isEqualTo("PLAN_CREATE");
    assertThat(result.get("committed")).isEqualTo(created);
    assertThat(result.get("current").get("version").asLong()).isEqualTo(2);
    result = json.readTree(mvc.perform(post(updatePath).with(actor(owner, false)).header("If-Match", "\"0\"")
        .contentType(MediaType.APPLICATION_JSON).content(paused)).andExpect(status().isOk())
        .andReturn().getResponse().getContentAsString());
    assertThat(result.get("operation").asText()).isEqualTo("PLAN_UPDATE");
    assertThat(result.get("committed")).isEqualTo(saved);
    assertThat(result.get("current").get("state").asText()).isEqualTo("ACTIVE");
    assertThat(saved.get("effectiveFrom").asText()).isEqualTo(LocalDate.now(ZoneOffset.UTC).plusDays(1).toString());
    assertThat(mutate(path, owner, updateKey, 0, paused, 200)).isEqualTo(saved);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM quota_plan_revisions WHERE tenant_id=?", Long.class, tenant)).isEqualTo(3);
    mvc.perform(post(updatePath).with(actor(owner, false)).header("If-Match", "\"1\"")
        .contentType(MediaType.APPLICATION_JSON).content(paused)).andExpect(status().isConflict());
    mvc.perform(post(creationPath).with(actor(owner, false)).contentType(MediaType.APPLICATION_JSON)
        .content(input.replace("3600", "1800"))).andExpect(status().isConflict());
    mvc.perform(post(root + "/quota-plans/creation-results/" + UUID.randomUUID() + "/query").with(actor(owner, false))
        .contentType(MediaType.APPLICATION_JSON).content(input)).andExpect(status().isNotFound());
    mvc.perform(post(creationPath).contentType(MediaType.APPLICATION_JSON).content(input)).andExpect(status().isUnauthorized());
    for (var role : List.of("GUARDIAN", "AUDITOR", "CHILD")) {
      String member = owner + role;
      db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,?,?)", tenant, member, ActorKeys.key(member), role, role.equals("CHILD") ? subject : null);
      mvc.perform(post(creationPath).with(actor(member, true)).contentType(MediaType.APPLICATION_JSON).content(input))
          .andExpect(status().is(role.equals("GUARDIAN") ? 404 : 403));
    }
    mvc.perform(post(creationPath).with(actor("other-tenant-owner", true)).contentType(MediaType.APPLICATION_JSON).content(input))
        .andExpect(status().isForbidden());
    db.update("UPDATE idempotency_requests SET expires_at=1 WHERE scope_id=?", tenant);
    mvc.perform(post(creationPath).with(actor(owner, false)).contentType(MediaType.APPLICATION_JSON).content(input)).andExpect(status().isOk());
    db.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?", Instant.now().toEpochMilli(), tenant, subject);
    mvc.perform(post(creationPath).with(actor(owner, false)).contentType(MediaType.APPLICATION_JSON).content(input)).andExpect(status().isForbidden());
    mvc.perform(post(updatePath).with(actor(owner, false)).header("If-Match", "\"0\"")
        .contentType(MediaType.APPLICATION_JSON).content(paused)).andExpect(status().isForbidden());
  }
}
