package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.http.MediaType.APPLICATION_JSON;
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
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    properties = {
      "spring.datasource.url=jdbc:h2:mem:quota-management;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
      "spring.datasource.username=sa",
      "spring.datasource.password="
    })
@AutoConfigureMockMvc
@Import(QuotaJourneyTest.TimeConfig.class)
class QuotaJourneyTest {
  static final Clock TIME = Clock.fixed(Instant.parse("2026-10-09T02:00:00Z"), ZoneOffset.UTC);

  @TestConfiguration
  static class TimeConfig {
    @Bean
    @Primary
    Clock quotaClock() {
      return TIME;
    }
  }

  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;

  RequestPostProcessor actor(String id) {
    return jwt()
        .jwt(
            t ->
                t.subject(id)
                    .claim("auth_time", TIME.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  JsonNode body(String text) throws Exception {
    return mapper.readTree(text);
  }

  Scope scope() throws Exception {
    String owner = "quota-" + UUID.randomUUID(), child = "child-" + UUID.randomUUID();
    String tenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(APPLICATION_JSON)
                        .content("{\"name\":\"额度验收\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
            .get("id")
            .asText();
    String subject =
        body(mvc.perform(
                    post("/api/v1/tenants/" + tenant + "/subjects")
                        .with(actor(owner))
                        .contentType(APPLICATION_JSON)
                        .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
            .get("id")
            .asText();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    return new Scope(owner, child, tenant, subject);
  }

  String path(Scope s) {
    return "/api/v1/tenants/" + s.tenant() + "/quota-pools";
  }

  Map<String, Object> input(Scope s, String date, String zone) {
    return Map.of(
        "subjectId",
        s.subject(),
        "name",
        "每日总额度",
        "scope",
        "TOTAL",
        "periodId",
        date,
        "timeZone",
        zone,
        "limitSeconds",
        600);
  }

  JsonNode create(Scope s, String key) throws Exception {
    return body(
        mvc.perform(
                post(path(s))
                    .with(actor(s.owner()))
                    .header("Idempotency-Key", key)
                    .contentType(APPLICATION_JSON)
                    .content(
                        mapper.writeValueAsString(input(s, LocalDate.now(TIME).toString(), "UTC"))))
            .andExpect(status().isCreated())
            .andExpect(header().string("ETag", "\"0\""))
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  @Test
  void poolCreationIsIdempotentScopedAndDoesNotClaimDeviceEnforcement() throws Exception {
    var s = scope();
    var pool = create(s, "create");
    assertThat(create(s, "create")).isEqualTo(pool);
    assertThat(pool.get("availableSeconds").asLong()).isEqualTo(600);
    assertThat(pool.get("evidenceStatus").asText()).isEqualTo("LEDGER_ONLY");
    mvc.perform(get(path(s)).with(actor(s.child())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1));
    mvc.perform(get(path(s)).with(actor("outsider"))).andExpect(status().isForbidden());
    mvc.perform(
            post(path(s))
                .with(actor(s.child()))
                .header("Idempotency-Key", "child")
                .contentType(APPLICATION_JSON)
                .content(
                    mapper.writeValueAsString(input(s, LocalDate.now(TIME).toString(), "UTC"))))
        .andExpect(status().isForbidden());
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM quota_pools WHERE tenant_id=?", Integer.class, s.tenant()))
        .isEqualTo(1);
  }

  @Test
  void adjustmentsRequireMfaVersionIdempotencyAndWriteLedger() throws Exception {
    var s = scope();
    var p = create(s, "create");
    String url = path(s) + "/" + p.get("id").asText() + "/adjustments";
    String data = "{\"deltaSeconds\":120,\"reason\":\"EXTRA_TIME\"}";
    mvc.perform(
            post(url)
                .with(jwt().jwt(t -> t.subject(s.owner())))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "weak")
                .contentType(APPLICATION_JSON)
                .content(data))
        .andExpect(status().isUnauthorized());
    var result =
        mvc.perform(
                post(url)
                    .with(actor(s.owner()))
                    .header("If-Match", "\"0\"")
                    .header("Idempotency-Key", "extra")
                    .contentType(APPLICATION_JSON)
                    .content(data))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.limitSeconds").value(720))
            .andExpect(header().string("ETag", "\"1\""))
            .andReturn()
            .getResponse()
            .getContentAsString();
    mvc.perform(
            post(url)
                .with(actor(s.owner()))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "extra")
                .contentType(APPLICATION_JSON)
                .content(data))
        .andExpect(status().isOk())
        .andExpect(content().json(result));
    mvc.perform(
            post(url)
                .with(actor(s.owner()))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "stale")
                .contentType(APPLICATION_JSON)
                .content(data))
        .andExpect(status().isPreconditionFailed());
    mvc.perform(get(path(s) + "/" + p.get("id").asText() + "/ledger").with(actor(s.child())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(2));
  }

  @Test
  void calendarIsImmutableAcrossScopesAndDstUsesLocalMidnight() throws Exception {
    var s = scope();
    String date =
        LocalDate.now(TIME.withZone(ZoneId.of("America/New_York")))
            .withMonth(11)
            .withDayOfMonth(1)
            .toString();
    var p =
        body(
            mvc.perform(
                    post(path(s))
                        .with(actor(s.owner()))
                        .header("Idempotency-Key", "dst")
                        .contentType(APPLICATION_JSON)
                        .content(mapper.writeValueAsString(input(s, date, "America/New_York"))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    assertThat(p.get("periodEnd").asLong() - p.get("periodStart").asLong())
        .isEqualTo(25 * 3600000L);
    mvc.perform(
            post(path(s))
                .with(actor(s.owner()))
                .header("Idempotency-Key", "timezone-reset")
                .contentType(APPLICATION_JSON)
                .content(
                    mapper.writeValueAsString(input(s, LocalDate.now(TIME).toString(), "UTC"))))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("QUOTA_TIME_ZONE_LOCKED"));
  }

  record Scope(String owner, String child, String tenant, String subject) {}
}
