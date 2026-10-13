package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Clock;
import java.time.DayOfWeek;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Actual quota HTTP, transaction and journal wiring; only the external issuer is substituted. */
@SpringBootTest(properties = {
    "spring.flyway.enabled=true",
    "manager.quota.materialization-job.enabled=false",
    "manager.approval.expiry-job.enabled=false",
    "manager.lifecycle.expiry-job.enabled=false"
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
@Import(QuotaIdempotencyAttributionJourneyTest.TimeConfig.class)
class QuotaIdempotencyAttributionJourneyTest {
  private static final Clock TIME =
      Clock.fixed(Instant.parse("2026-10-09T02:00:00Z"), ZoneOffset.UTC);
  private static final String H2_URL =
      "jdbc:h2:mem:quota-idempotency-attribution;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE";

  @DynamicPropertySource
  static void database(DynamicPropertyRegistry properties) {
    String externalUrl = System.getenv("P0_QUOTA_TEST_DATABASE_URL");
    // Validate before Spring creates its DataSource or Flyway can touch an external schema.
    if (externalUrl != null
        && !externalUrl.matches(
            "jdbc:mysql://127\\.0\\.0\\.1:3308/notification_it_[a-f0-9]{32}(?:\\?[^\\s#]*)?")) {
      throw new IllegalArgumentException("Quota attribution requires an isolated local MySQL schema");
    }
    String url = externalUrl == null ? H2_URL : externalUrl;
    String username = System.getenv().getOrDefault("P0_QUOTA_TEST_DATABASE_USERNAME", "sa");
    String password = System.getenv().getOrDefault("P0_QUOTA_TEST_DATABASE_PASSWORD", "");
    properties.add("spring.datasource.url", () -> url);
    properties.add("spring.datasource.username", () -> username);
    properties.add("spring.datasource.password", () -> password);
  }

  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;

  @ParameterizedTest
  @ValueSource(strings = {"TOTAL", "APPLICATION"})
  void poolCreationBelongsToItsChildAndReplaysTheOriginalSnapshot(String quotaScope)
      throws Exception {
    var s = scope();
    var request = poolCreation(s, quotaScope);
    var created = success(s, request);
    assertAttribution(s, request, created);
    assertThat(created.get("scope").asText()).isEqualTo(quotaScope);
    assertThat(created.get("limitSeconds").asLong()).isEqualTo(600);

    success(s, adjustment(s, created, 0, 120));
    var beforeReplay = snapshot(s);
    assertThat(success(s, request)).isEqualTo(created);
    assertThat(snapshot(s)).isEqualTo(beforeReplay);
    assertAttribution(s, request, created);
    assertThat(count(s, "quota_pools")).isEqualTo(1);
    assertThat(count(s, "quota_ledger")).isEqualTo(2);
    assertThat(db.queryForObject(
            "SELECT limit_seconds FROM quota_pools WHERE tenant_id=?", Long.class, s.tenant()))
        .isEqualTo(720);
  }

  @Test
  void adjustmentBelongsToThePoolsChildAndReplayDoesNotAdjustAgain() throws Exception {
    var s = scope();
    var pool = success(s, poolCreation(s, "TOTAL"));
    var request = adjustment(s, pool, 0, 120);
    var adjusted = success(s, request);
    assertAttribution(s, request, adjusted);
    assertThat(adjusted.get("version").asLong()).isEqualTo(1);
    assertThat(adjusted.get("limitSeconds").asLong()).isEqualTo(720);

    success(s, adjustment(s, pool, 1, 60));
    var beforeReplay = snapshot(s);
    assertThat(success(s, request)).isEqualTo(adjusted);
    assertThat(snapshot(s)).isEqualTo(beforeReplay);
    assertAttribution(s, request, adjusted);
    assertThat(count(s, "quota_pools")).isEqualTo(1);
    assertThat(count(s, "quota_ledger")).isEqualTo(3);
    assertThat(db.queryForObject(
            "SELECT version FROM quota_pools WHERE tenant_id=?", Long.class, s.tenant()))
        .isEqualTo(2);
    assertThat(db.queryForObject(
            "SELECT limit_seconds FROM quota_pools WHERE tenant_id=?", Long.class, s.tenant()))
        .isEqualTo(780);
  }

  @ParameterizedTest
  @ValueSource(strings = {"TOTAL", "APPLICATION"})
  void planCreationBelongsToItsChildAndReplaysWithoutAnotherDailyPool(String quotaScope)
      throws Exception {
    var s = scope();
    var request = planCreation(s, quotaScope);
    var created = success(s, request);
    assertAttribution(s, request, created);
    assertThat(created.get("scope").asText()).isEqualTo(quotaScope);
    assertThat(created.get("state").asText()).isEqualTo("ACTIVE");

    success(s, planUpdate(s, created, 0, "PAUSED"));
    var beforeReplay = snapshot(s);
    assertThat(success(s, request)).isEqualTo(created);
    assertThat(snapshot(s)).isEqualTo(beforeReplay);
    assertAttribution(s, request, created);
    assertThat(count(s, "quota_plans")).isEqualTo(1);
    assertThat(count(s, "quota_plan_revisions")).isEqualTo(2);
    assertThat(count(s, "quota_pools")).isEqualTo(1);
    assertThat(count(s, "quota_ledger")).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(strings = {"ACTIVE", "PAUSED"})
  void planUpdateBelongsToThePlansChildAndReplaysWithoutAnotherRevision(String state)
      throws Exception {
    var s = scope();
    var plan = success(s, planCreation(s, "TOTAL"));
    var request = planUpdate(s, plan, 0, state);
    var updated = success(s, request);
    assertAttribution(s, request, updated);
    assertThat(updated.get("state").asText()).isEqualTo(state);
    assertThat(updated.get("version").asLong()).isEqualTo(1);
    assertThat(updated.get("effectiveFrom").asText()).isEqualTo("2026-10-10");

    success(s, planUpdate(s, plan, 1, state.equals("PAUSED") ? "ACTIVE" : "PAUSED"));
    var beforeReplay = snapshot(s);
    assertThat(success(s, request)).isEqualTo(updated);
    assertThat(snapshot(s)).isEqualTo(beforeReplay);
    assertAttribution(s, request, updated);
    assertThat(count(s, "quota_plans")).isEqualTo(1);
    assertThat(count(s, "quota_plan_revisions")).isEqualTo(3);
    assertThat(count(s, "quota_pools")).isEqualTo(1);
    assertThat(count(s, "quota_ledger")).isEqualTo(1);
    assertThat(db.queryForObject(
            "SELECT version FROM quota_plans WHERE tenant_id=?", Long.class, s.tenant()))
        .isEqualTo(2);
  }

  @ParameterizedTest
  @EnumSource(Operation.class)
  void erasedExpiredResultIsTerminalWhileCurrentSubjectAuthorizationStillRuns(Operation operation)
      throws Exception {
    var s = scope();
    var request = committedRequest(s, operation);
    erase(s, request);
    var beforeReplay = snapshot(s);

    var changed = new LinkedHashMap<>(request.input());
    if (operation == Operation.POOL_ADJUST) changed.put("deltaSeconds", 300);
    else changed.put("name", "重放修改");
    for (Map<String, Object> input : List.of(request.input(), changed)) {
      var response = perform(s, request, input)
          .andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"))
          .andReturn().getResponse().getContentAsString();
      assertThat(response).doesNotContain(s.subject(), "每日总额度", "重复计划", "次日安排");
    }
    assertThat(snapshot(s)).isEqualTo(beforeReplay);
    assertErasedMarker(s, request);

    // Resource/lifecycle denial remains before journal access even for a retained tombstone.
    db.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?",
        TIME.millis(), s.tenant(), s.subject());
    perform(s, request, request.input())
        .andExpect(status().isForbidden())
        .andExpect(jsonPath("$.errorCode").value("SCOPE_DENIED"));
    assertThat(snapshot(s)).isEqualTo(beforeReplay);
    assertErasedMarker(s, request);
  }

  @ParameterizedTest
  @EnumSource(Operation.class)
  void revokedCallerIsDeniedBeforeActiveAndErasedQuotaResults(Operation operation) throws Exception {
    var s = scope();
    var request = committedRequest(s, operation);
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP"
        + " WHERE tenant_id=? AND actor_id=?", s.tenant(), s.owner());

    for (boolean erased : List.of(false, true)) {
      if (erased) erase(s, request);
      var beforeReplay = snapshot(s);
      perform(s, request, request.input())
          .andExpect(status().isForbidden())
          .andExpect(jsonPath("$.errorCode").value("SCOPE_DENIED"));
      assertThat(snapshot(s)).isEqualTo(beforeReplay);
    }
    assertErasedMarker(s, request);
  }

  private Write committedRequest(Scope s, Operation operation) throws Exception {
    Write request = switch (operation) {
      case POOL_CREATE -> poolCreation(s, "TOTAL");
      case POOL_ADJUST -> adjustment(s, success(s, poolCreation(s, "TOTAL")), 0, 120);
      case PLAN_CREATE -> planCreation(s, "TOTAL");
      case PLAN_UPDATE -> planUpdate(s, success(s, planCreation(s, "TOTAL")), 0, "PAUSED");
    };
    success(s, request);
    return request;
  }

  private void assertAttribution(Scope s, Write request, JsonNode response) throws Exception {
    assertThat(response.get("subjectId").asText()).isEqualTo(s.subject());
    assertThat(db.queryForList(
            "SELECT response_state FROM idempotency_requests"
                + " WHERE scope_id=? AND operation_key=? AND key_hash=?",
            String.class, s.tenant(), sha256(request.operation()), sha256(request.key())))
        .containsExactly("SCOPED");
    // Independent digest: neither ResponseOwnership nor its helpers supply this expectation.
    String childDigest = sha256("idempotency-subject-v1\n" + s.tenant() + "\n" + s.subject());
    String actorDigest = sha256("idempotency-subject-v1\n" + s.tenant() + "\n" + s.owner());
    var owners = db.queryForList(
        "SELECT tenant_id,subject_key FROM idempotency_subject_owners"
            + " WHERE scope_id=? AND operation_key=? AND key_hash=?",
        s.tenant(), sha256(request.operation()), sha256(request.key()));
    assertThat(owners).hasSize(1);
    assertThat(owners.get(0).get("tenant_id")).isEqualTo(s.tenant());
    assertThat(owners.get(0).get("subject_key")).isEqualTo(childDigest).isNotEqualTo(actorDigest);
  }

  private void erase(Scope s, Write request) throws Exception {
    // Model the committed marker written by the independently exercised erasure worker.
    assertThat(db.update(
            "UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL,"
                + "actor_id='',operation='',request_hash=?,expires_at=0"
                + " WHERE scope_id=? AND operation_key=? AND key_hash=?",
            "0".repeat(64), s.tenant(), sha256(request.operation()), sha256(request.key())))
        .isEqualTo(1);
  }

  private void assertErasedMarker(Scope s, Write request) throws Exception {
    var rows = db.queryForList(
        "SELECT response_state,response_body,actor_id,operation,request_hash,expires_at"
            + " FROM idempotency_requests WHERE scope_id=? AND operation_key=? AND key_hash=?",
        s.tenant(), sha256(request.operation()), sha256(request.key()));
    assertThat(rows).hasSize(1);
    var marker = rows.get(0);
    assertThat(marker.get("response_state")).isEqualTo("ERASED");
    assertThat(marker.get("response_body")).isNull();
    assertThat(marker.get("actor_id")).isEqualTo("");
    assertThat(marker.get("operation")).isEqualTo("");
    assertThat(marker.get("request_hash")).isEqualTo("0".repeat(64));
    assertThat(((Number) marker.get("expires_at")).longValue()).isZero();
  }

  private Map<String, List<Map<String, Object>>> snapshot(Scope s) {
    var result = new LinkedHashMap<String, List<Map<String, Object>>>();
    for (String table : List.of("quota_pools", "quota_ledger", "quota_plans",
        "quota_outbox", "audit_events", "idempotency_subject_owners")) {
      result.put(table, db.queryForList(
          "SELECT * FROM " + table + " WHERE tenant_id=? ORDER BY id", s.tenant()));
    }
    result.put("quota_plan_revisions", db.queryForList(
        "SELECT * FROM quota_plan_revisions WHERE tenant_id=? ORDER BY plan_id,version", s.tenant()));
    result.put("idempotency_requests", db.queryForList(
        "SELECT * FROM idempotency_requests WHERE scope_id=? ORDER BY id", s.tenant()));
    return result;
  }

  private int count(Scope s, String table) {
    return db.queryForObject("SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?",
        Integer.class, s.tenant());
  }

  private JsonNode success(Scope s, Write request) throws Exception {
    var result = perform(s, request, request.input())
        .andExpect(status().is(request.status())).andReturn();
    var response = mapper.readTree(result.getResponse().getContentAsString());
    assertThat(result.getResponse().getHeader("ETag"))
        .isEqualTo("\"" + response.get("version").asLong() + "\"");
    return response;
  }

  private ResultActions perform(Scope s, Write request, Map<String, Object> input) throws Exception {
    MockHttpServletRequestBuilder http = request.operation().equals("quota.plan.update")
        ? put(request.path()) : post(request.path());
    if (request.etag() != null) http.header("If-Match", request.etag());
    return mvc.perform(http.with(actor(s.owner())).header("Idempotency-Key", request.key())
        .contentType(APPLICATION_JSON).content(mapper.writeValueAsString(input)));
  }

  private Write poolCreation(Scope s, String quotaScope) {
    var input = new LinkedHashMap<String, Object>();
    input.put("subjectId", s.subject());
    input.put("name", "每日总额度");
    input.put("scope", quotaScope);
    if (quotaScope.equals("APPLICATION")) input.put("applicationId", s.application());
    input.put("periodId", "2026-10-09");
    input.put("timeZone", "UTC");
    input.put("limitSeconds", 600);
    return new Write("quota.create", key(), root(s) + "/quota-pools", null, input, 201);
  }

  private Write adjustment(Scope s, JsonNode pool, long version, long seconds) {
    return new Write("quota.adjust", key(),
        root(s) + "/quota-pools/" + pool.get("id").asText() + "/adjustments",
        "\"" + version + "\"", Map.of("deltaSeconds", seconds, "reason", "EXTRA_TIME"), 200);
  }

  private Write planCreation(Scope s, String quotaScope) {
    var input = new LinkedHashMap<String, Object>();
    input.put("subjectId", s.subject());
    input.put("name", "重复计划");
    input.put("scope", quotaScope);
    if (quotaScope.equals("APPLICATION")) input.put("applicationId", s.application());
    input.put("timeZone", "UTC");
    input.put("effectiveFrom", "2026-10-09");
    input.put("weeklyLimits", weekly(3600));
    input.put("dateOverrides", Map.of("2026-10-09", 1200));
    return new Write("quota.plan.create", key(), root(s) + "/quota-plans", null, input, 201);
  }

  private Write planUpdate(Scope s, JsonNode plan, long version, String state) {
    return new Write("quota.plan.update", key(),
        root(s) + "/quota-plans/" + plan.get("id").asText(), "\"" + version + "\"",
        Map.of("name", "次日安排", "state", state, "weeklyLimits", weekly(600),
            "dateOverrides", Map.of()), 200);
  }

  private Map<String, Long> weekly(long seconds) {
    var limits = new LinkedHashMap<String, Long>();
    for (DayOfWeek day : DayOfWeek.values()) limits.put(day.name(), seconds);
    return limits;
  }

  private Scope scope() throws Exception {
    String owner = "quota-attribution-" + UUID.randomUUID();
    String child = "child-" + UUID.randomUUID();
    String tenant = mapper.readTree(mvc.perform(post("/api/v1/tenants").with(actor(owner))
            .contentType(APPLICATION_JSON)
            .content("{\"name\":\"额度归属验收\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString())
        .get("id").asText();
    String prefix = "/api/v1/tenants/" + tenant;
    String subject = mapper.readTree(mvc.perform(post(prefix + "/subjects").with(actor(owner))
            .contentType(APPLICATION_JSON)
            .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString())
        .get("id").asText();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
        + " VALUES(?,?,?,'CHILD',?)", tenant, child, ActorKeys.key(child), subject);
    String application = mapper.readTree(mvc.perform(post(prefix + "/applications").with(actor(owner))
            .contentType(APPLICATION_JSON)
            .content("{\"displayName\":\"学习\",\"platform\":\"ANDROID\","
                + "\"packageName\":\"org.example.attribution\",\"profile\":\"PRIMARY\","
                + "\"signingDigests\":[]}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString())
        .get("id").asText();
    return new Scope(owner, tenant, subject, application);
  }

  private RequestPostProcessor actor(String id) {
    return jwt().jwt(token -> token.subject(id)
            .claim("auth_time", TIME.instant().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private String root(Scope s) {
    return "/api/v1/tenants/" + s.tenant();
  }

  private String key() {
    return UUID.randomUUID().toString();
  }

  private static String sha256(String text) throws Exception {
    return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
        .digest(text.getBytes(StandardCharsets.UTF_8)));
  }

  enum Operation { POOL_CREATE, POOL_ADJUST, PLAN_CREATE, PLAN_UPDATE }

  record Scope(String owner, String tenant, String subject, String application) {}

  record Write(String operation, String key, String path, String etag,
      Map<String, Object> input, int status) {}

  @TestConfiguration
  static class TimeConfig {
    @Bean
    @Primary
    Clock quotaAttributionClock() {
      return TIME;
    }
  }
}
