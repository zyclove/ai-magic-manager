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

@SpringBootTest(properties = {"spring.datasource.url=jdbc:h2:mem:quota_recovery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password="})
@AutoConfigureMockMvc
class QuotaOperationRecoveryTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  RequestPostProcessor actor(String subject, boolean recent) {
    return jwt().jwt(t -> t.subject(subject).claim("auth_time", recent ? Instant.now().getEpochSecond() : 1L)
        .claim("amr", recent ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  JsonNode mutate(String path, String actor, String key, Integer version, String body, int status) throws Exception {
    var request = post(path).with(actor(actor, true)).contentType(MediaType.APPLICATION_JSON).content(body);
    if (key != null) request.header("Idempotency-Key", key);
    if (version != null) request.header("If-Match", "\"" + version + "\"");
    return mapper.readTree(mvc.perform(request).andExpect(status().is(status)).andReturn().getResponse().getContentAsString());
  }
  @Test void recoverySeparatesHistoricalAndCurrentBalanceWithoutMutatingOrRequiringFreshMfa() throws Exception {
    String owner = "quota-recovery-" + UUID.randomUUID();
    String tenant = mutate("/api/v1/tenants", owner, null, null,
        "{\"name\":\"额度恢复\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}", 201).get("id").asText();
    String root = "/api/v1/tenants/" + tenant;
    String subject = mutate(root + "/subjects", owner, null, null,
        "{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}", 201).get("id").asText();
    String input = mapper.writeValueAsString(Map.of("name", "当天额度", "subjectId", subject, "scope", "TOTAL",
        "periodId", LocalDate.now(ZoneOffset.UTC).toString(), "timeZone", "UTC", "limitSeconds", 3600));
    String createKey = UUID.randomUUID().toString();
    var created = mutate(root + "/quota-pools", owner, createKey, null, input, 201);
    String pool = created.get("id").asText();
    String adjustment = "{\"deltaSeconds\":900,\"reason\":\"EXTRA_TIME\"}";
    String adjustKey = UUID.randomUUID().toString();
    var adjusted = mutate(root + "/quota-pools/" + pool + "/adjustments", owner, adjustKey, 0, adjustment, 200);
    mutate(root + "/quota-pools/" + pool + "/adjustments", owner, UUID.randomUUID().toString(), 1, adjustment, 200);
    String creationPath = root + "/quota-pools/creation-results/" + createKey + "/query";
    String adjustmentPath = root + "/quota-pools/" + pool + "/adjustment-results/" + adjustKey + "/query";
    var creationResult = mapper.readTree(mvc.perform(post(creationPath).with(actor(owner, false))
        .contentType(MediaType.APPLICATION_JSON).content(input)).andExpect(status().isOk())
        .andExpect(header().string("Cache-Control", "no-store")).andReturn().getResponse().getContentAsString());
    assertThat(creationResult.get("committed")).isEqualTo(created);
    assertThat(creationResult.get("current").get("limitSeconds").asLong()).isEqualTo(5400);
    var adjustmentResult = mapper.readTree(mvc.perform(post(adjustmentPath).with(actor(owner, false))
        .header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON).content(adjustment))
        .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    assertThat(adjustmentResult.get("committed")).isEqualTo(adjusted);
    assertThat(adjustmentResult.get("current").get("version").asLong()).isEqualTo(2);
    // Repeating the exact old adjustment returns its original response, without a second increment.
    assertThat(mutate(root + "/quota-pools/" + pool + "/adjustments", owner, adjustKey, 0, adjustment, 200)).isEqualTo(adjusted);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM quota_ledger WHERE tenant_id=? AND pool_id=?", Long.class, tenant, pool)).isEqualTo(3);
    mvc.perform(post(adjustmentPath).with(actor(owner, false)).header("If-Match", "\"1\"")
        .contentType(MediaType.APPLICATION_JSON).content(adjustment)).andExpect(status().isConflict());
    mvc.perform(post(creationPath).with(actor(owner, false)).contentType(MediaType.APPLICATION_JSON)
        .content(input.replace("3600", "1800"))).andExpect(status().isConflict());
    mvc.perform(post(root + "/quota-pools/creation-results/" + UUID.randomUUID() + "/query").with(actor(owner, false))
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
    assertThat(db.queryForObject("SELECT limit_seconds FROM quota_pools WHERE tenant_id=? AND id=?", Long.class, tenant, pool)).isEqualTo(5400);
  }
}
