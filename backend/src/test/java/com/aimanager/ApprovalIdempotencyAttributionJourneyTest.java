package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.EnumSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/**
 * Real approval HTTP, Spring transactions, JDBC and Flyway. The issuer decoder is the only mock.
 * Seeded CHILD membership and BYOD devices are fixtures, not native registration/execution proof.
 */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:approval-idempotency-attribution;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true",
    "manager.approval.expiry-job.enabled=false", "manager.lifecycle.expiry-job.enabled=false",
    "manager.quota.materialization-job.enabled=false", "manager.notifications.retention-job.enabled=false",
    "manager.exports.worker.enabled=false", "manager.report-jobs.worker.enabled=false",
    "manager.diagnostic-packages.worker.enabled=false", "manager.erasure-previews.cleanup.enabled=false",
    "manager.emm.enrollment-cleanup.enabled=false", "manager.messaging.kafka.enabled=false",
    "manager.messaging.artemis.enabled=false",
    // These retention methods have no enable switch; defer their first run beyond this journey.
    "manager.observation.permission-retention-seconds=86400",
    "manager.observations.retention-delay-millis=86400000"
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
@Import({ApprovalIdempotencyAttributionJourneyTest.TimeConfiguration.class, com.aimanager.support.ControlledIdempotencyTimeConfiguration.class})
class ApprovalIdempotencyAttributionJourneyTest {
  private static final Instant NOW = Instant.parse("2026-10-13T10:00:00Z");
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @Autowired StandaloneTestClock clock;
  @MockitoBean JwtDecoder decoder;

  @DynamicPropertySource
  static void isolatedDatabase(DynamicPropertyRegistry properties) {
    String url = System.getenv("P0_APPROVAL_TEST_DATABASE_URL");
    String username = System.getenv("P0_APPROVAL_TEST_DATABASE_USERNAME");
    String password = System.getenv("P0_APPROVAL_TEST_DATABASE_PASSWORD");
    if (url == null) {
      if (username != null || password != null)
        throw new IllegalArgumentException("Approval database credentials require an isolated URL");
      return;
    }
    // Validate before Spring constructs a DataSource or runs Flyway, not in a test lifecycle hook.
    if (!url.matches("jdbc:mysql://127\\.0\\.0\\.1:3308/notification_it_[a-f0-9]{32}(\\?[^#\\s]*)?")
        || username == null || username.isBlank() || password == null)
      throw new IllegalArgumentException("Approval tests require an isolated loopback schema and explicit credentials");
    properties.add("spring.datasource.url", () -> url);
    properties.add("spring.datasource.username", () -> username);
    properties.add("spring.datasource.password", () -> password);
  }

  @Test
  void requestCacheBelongsToTheActualChildAndExactReplayDoesNotDuplicateAnything() throws Exception {
    var scope = scope();
    String key = key();
    var created = request(scope, key);
    assertThat(created.get("subjectId").asText()).isEqualTo(scope.subject());
    assertScoped(scope, Operation.REQUEST, key);
    var committed = snapshot(scope.tenant());

    assertThat(request(scope, key)).isEqualTo(created);
    assertThat(snapshot(scope.tenant())).isEqualTo(committed);
    assertCount("access_requests", scope.tenant(), 1);
    assertAudit(scope, "ACCESS_REQUEST_CREATED", 1);
  }

  @Test
  void sameTenantChildrenHaveDistinctOwnersEvenWithTheSameRequestKey() throws Exception {
    var first = scope();
    var second = childScope(first.owner(), first.tenant());
    String sharedKey = key();
    var one = request(first, sharedKey);
    var two = request(second, sharedKey);

    assertScoped(first, Operation.REQUEST, sharedKey);
    assertScoped(second, Operation.REQUEST, sharedKey);
    assertThat(ownerDigest(first.tenant(), first.subject()))
        .isNotEqualTo(ownerDigest(second.tenant(), second.subject()));
    assertThat(one.get("id").asText()).isNotEqualTo(two.get("id").asText());
    assertThat(db.queryForList("SELECT DISTINCT subject_key FROM idempotency_subject_owners"
            + " WHERE tenant_id=? AND operation_key=? ORDER BY subject_key", String.class,
        first.tenant(), digest("access.request")))
        .containsExactlyInAnyOrder(ownerDigest(first.tenant(), first.subject()),
            ownerDigest(second.tenant(), second.subject()));
    var committed = snapshot(first.tenant());
    assertThat(request(first, sharedKey)).isEqualTo(one);
    assertThat(request(second, sharedKey)).isEqualTo(two);
    assertThat(snapshot(first.tenant())).isEqualTo(committed);
    assertCount("access_requests", first.tenant(), 2);
    assertAudit(first, "ACCESS_REQUEST_CREATED", 2);

    // The same adult decides for both children; each response must retain exactly its own child.
    String approveKey = key(), denyKey = key();
    var approved = invoke(first, Operation.APPROVE, one.get("id").asText(), approveKey, false);
    var denied = invoke(second, Operation.DENY, two.get("id").asText(), denyKey, false);
    assertScoped(first, Operation.APPROVE, approveKey);
    assertScoped(second, Operation.DENY, denyKey);
    var decisions = snapshot(first.tenant());
    assertThat(invoke(first, Operation.APPROVE, one.get("id").asText(), approveKey, false)).isEqualTo(approved);
    assertThat(invoke(second, Operation.DENY, two.get("id").asText(), denyKey, false)).isEqualTo(denied);
    assertThat(snapshot(first.tenant())).isEqualTo(decisions);
    assertCount("access_request_decisions", first.tenant(), 2);
  }

  @ParameterizedTest
  @EnumSource(value = Operation.class, names = {"APPROVE", "DENY", "CANCEL", "REVOKE"})
  void completedMutationOwnsTheChildResponseAndExactReplayIsReadOnly(Operation operation)
      throws Exception {
    var scope = scope();
    var fixture = complete(scope, operation);
    assertThat(fixture.response().get("subjectId").asText()).isEqualTo(scope.subject());
    assertThat(fixture.response().get("state").asText()).isEqualTo(operation.resultState);
    assertScoped(scope, operation, fixture.key());
    var committed = snapshot(scope.tenant());

    assertThat(invoke(scope, operation, fixture.requestId(), fixture.key(), false))
        .isEqualTo(fixture.response());
    assertThat(snapshot(scope.tenant())).isEqualTo(committed);
    assertCount("access_requests", scope.tenant(), 1);
    assertCount("access_request_decisions", scope.tenant(), operation == Operation.CANCEL ? 0 : 1);
    assertAudit(scope, operation.auditAction, 1);
    assertThat(fixture.response().get("version").asLong())
        .isEqualTo(operation == Operation.REVOKE ? 2 : 1);
  }

  @ParameterizedTest
  @CsvSource({
      "REQUEST,false", "REQUEST,true", "APPROVE,false", "APPROVE,true", "DENY,false", "DENY,true",
      "CANCEL,false", "CANCEL,true", "REVOKE,false", "REVOKE,true"
  })
  void erasedOldKeyRefusesSameAndChangedInputsEvenAfterExpiryWithoutAnotherTransition(
      Operation operation, boolean expired) throws Exception {
    var scope = scope();
    var fixture = complete(scope, operation);
    eraseMarker(scope, operation, fixture.key(), expired);
    var committed = snapshot(scope.tenant());
    var marker = journal(scope, operation, fixture.key());
    var owners = owners(scope, operation, fixture.key());

    // Keep the real resource and current authority: lifecycle checks remain ahead of cache access.
    for (boolean changed : List.of(false, true)) {
      var response = mvc.perform(command(scope, operation, fixture.requestId(), fixture.key(), changed)
              .with(actor(operation.actor(scope))))
          .andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"))
          .andReturn().getResponse().getContentAsString();
      assertThat(response).doesNotContain(scope.subject(), "想和同学一起玩一会");
      assertThat(snapshot(scope.tenant())).isEqualTo(committed);
      assertThat(journal(scope, operation, fixture.key())).isEqualTo(marker);
      assertThat(owners(scope, operation, fixture.key())).isEqualTo(owners);
    }
    assertThat(marker.get("response_state")).isEqualTo("ERASED");
    assertThat(marker.get("response_body")).isNull();
    assertThat(marker.get("actor_id")).isEqualTo("");
    assertThat(marker.get("operation")).isEqualTo("");
    assertThat(marker.get("request_hash")).isEqualTo("0".repeat(64));
  }

  @ParameterizedTest
  @EnumSource(value = Operation.class, names = {"APPROVE", "DENY", "REVOKE"})
  void revokedAdultIsDeniedBeforeActiveOrErasedCachedResults(Operation operation) throws Exception {
    var scope = scope();
    var fixture = complete(scope, operation);
    db.update("UPDATE tenant_members SET revoked_at=? WHERE tenant_id=? AND actor_key=?",
        java.sql.Timestamp.from(clock.instant()), scope.tenant(), ActorKeys.key(scope.owner()));

    for (boolean erased : List.of(false, true)) {
      if (erased) eraseMarker(scope, operation, fixture.key(), true);
      var committed = snapshot(scope.tenant());
      mvc.perform(command(scope, operation, fixture.requestId(), fixture.key(), false)
              .with(actor(scope.owner())))
          .andExpect(status().isForbidden()).andExpect(jsonPath("$.errorCode").value("SCOPE_DENIED"));
      assertThat(snapshot(scope.tenant())).isEqualTo(committed);
    }
  }

  @ParameterizedTest
  @EnumSource(Operation.class)
  void foreignChildIsDeniedBeforeActiveOrErasedCachedResults(Operation operation) throws Exception {
    var scope = scope();
    var fixture = complete(scope, operation);
    var other = childScope(scope.owner(), scope.tenant());

    for (boolean erased : List.of(false, true)) {
      if (erased) eraseMarker(scope, operation, fixture.key(), true);
      var committed = snapshot(scope.tenant());
      mvc.perform(command(scope, operation, fixture.requestId(), fixture.key(), false)
              .with(actor(other.child())))
          .andExpect(status().isForbidden()).andExpect(jsonPath("$.errorCode").value("SCOPE_DENIED"));
      assertThat(snapshot(scope.tenant())).isEqualTo(committed);
    }
  }

  private Fixture complete(Scope scope, Operation operation) throws Exception {
    String key = key();
    var created = request(scope, operation == Operation.REQUEST ? key : key());
    String requestId = created.get("id").asText();
    if (operation == Operation.REQUEST) return new Fixture(requestId, key, created);
    if (operation == Operation.REVOKE) invoke(scope, Operation.APPROVE, requestId, key(), false);
    return new Fixture(requestId, key, invoke(scope, operation, requestId, key, false));
  }

  private JsonNode request(Scope scope, String key) throws Exception {
    return invoke(scope, Operation.REQUEST, null, key, false);
  }

  private JsonNode invoke(Scope scope, Operation operation, String id, String key, boolean changed)
      throws Exception {
    var response = mvc.perform(command(scope, operation, id, key, changed)
            .with(actor(operation.actor(scope))))
        .andExpect(status().is(operation == Operation.REQUEST ? 201 : 200))
        .andExpect(header().string("ETag", operation == Operation.REQUEST ? "\"0\""
            : operation == Operation.REVOKE ? "\"2\"" : "\"1\""))
        .andReturn().getResponse();
    return json.readTree(response.getContentAsString());
  }

  private MockHttpServletRequestBuilder command(
      Scope scope, Operation operation, String id, String key, boolean changed) throws Exception {
    String root = "/api/v1/tenants/" + scope.tenant() + "/access-requests";
    var request = post(root + (operation == Operation.REQUEST ? "" : "/" + id + operation.suffix))
        .header("Idempotency-Key", key);
    if (operation == Operation.REQUEST) {
      var input = new HashMap<>(input(scope));
      if (changed) input.put("requestedWindowSeconds", 601);
      request.contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(input));
    } else {
      int version = operation == Operation.REVOKE ? 1 : 0;
      request.header("If-Match", "\"" + (changed ? version + 1 : version) + "\"");
      if (operation == Operation.APPROVE || operation == Operation.DENY) {
        String decision = operation == Operation.APPROVE
            ? (changed ? "{\"decision\":\"DENY\",\"reasonCode\":\"NOT_NOW\"}"
                : "{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":300}")
            : (changed ? "{\"decision\":\"DENY\",\"reasonCode\":\"OTHER\"}"
                : "{\"decision\":\"DENY\",\"reasonCode\":\"NOT_NOW\"}");
        request.contentType(MediaType.APPLICATION_JSON).content(decision);
      }
    }
    return request;
  }

  private void assertScoped(Scope scope, Operation operation, String key) throws Exception {
    var row = journal(scope, operation, key);
    assertThat(row.get("response_state")).as("%s HTTP result classification", operation.journalOperation)
        .isEqualTo("SCOPED");
    assertThat(json.readTree(row.get("response_body").toString()).get("subjectId").asText())
        .isEqualTo(scope.subject());
    var ownerRows = owners(scope, operation, key);
    assertThat(ownerRows).hasSize(1);
    assertThat(ownerRows.get(0).get("tenant_id")).isEqualTo(scope.tenant());
    // Independent digest: do not reuse the production ResponseOwnership helper in this oracle.
    assertThat(ownerRows.get(0).get("subject_key"))
        .isEqualTo(ownerDigest(scope.tenant(), scope.subject()));
  }

  private Map<String, Object> journal(Scope scope, Operation operation, String key) throws Exception {
    return db.queryForMap("SELECT * FROM idempotency_requests WHERE scope_id=?"
            + " AND actor_key=? AND operation_key=? AND key_hash=?",
        scope.tenant(), ActorKeys.key(operation.actor(scope)), digest(operation.journalOperation), digest(key));
  }

  private List<Map<String, Object>> owners(Scope scope, Operation operation, String key) throws Exception {
    return db.queryForList("SELECT * FROM idempotency_subject_owners WHERE scope_id=?"
            + " AND actor_key=? AND operation_key=? AND key_hash=? ORDER BY tenant_id,subject_key",
        scope.tenant(), ActorKeys.key(operation.actor(scope)), digest(operation.journalOperation), digest(key));
  }

  private void eraseMarker(Scope scope, Operation operation, String key, boolean expired) throws Exception {
    // Model the committed marker; erasure-worker correctness is covered by its own integration suite.
    assertThat(db.update("UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL,"
            + "actor_id='',operation='',request_hash=?,expires_at=? WHERE scope_id=?"
            + " AND actor_key=? AND operation_key=? AND key_hash=?", "0".repeat(64),
        expired ? 0L : clock.millis() + 60000, scope.tenant(), ActorKeys.key(operation.actor(scope)),
        digest(operation.journalOperation), digest(key))).isEqualTo(1);
  }

  private Snapshot snapshot(String tenant) {
    return new Snapshot(
        db.queryForList("SELECT * FROM access_requests WHERE tenant_id=? ORDER BY id", tenant),
        db.queryForList("SELECT * FROM access_request_decisions WHERE tenant_id=? ORDER BY request_id", tenant),
        db.queryForList("SELECT * FROM access_request_slots WHERE tenant_id=? ORDER BY subject_id,registration_id,application_id", tenant),
        db.queryForList("SELECT * FROM audit_events WHERE tenant_id=? ORDER BY id", tenant),
        db.queryForList("SELECT * FROM notification_events WHERE tenant_id=? ORDER BY id", tenant),
        db.queryForList("SELECT * FROM idempotency_requests WHERE scope_id=? ORDER BY id", tenant),
        db.queryForList("SELECT * FROM idempotency_subject_owners WHERE tenant_id=? ORDER BY id", tenant));
  }

  private void assertCount(String table, String tenant, int expected) {
    assertThat(db.queryForObject("SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Integer.class, tenant))
        .isEqualTo(expected);
  }

  private void assertAudit(Scope scope, String action, int expected) {
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action=?",
        Integer.class, scope.tenant(), action)).isEqualTo(expected);
  }

  private Scope scope() throws Exception {
    String owner = "approval-attribution-owner-" + UUID.randomUUID();
    String tenant = create("/api/v1/tenants", owner,
        Map.of("name", "审批归属测试家庭", "kind", "FAMILY", "timeZone", "UTC")).get("id").asText();
    return childScope(owner, tenant);
  }

  private Scope childScope(String owner, String tenant) throws Exception {
    String child = "approval-attribution-child-" + UUID.randomUUID();
    String subject = create("/api/v1/tenants/" + tenant + "/subjects", owner,
        Map.of("nickname", "审批测试孩子", "ageBand", "AGE_7_12")).get("id").asText();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,'CHILD',?)",
        tenant, child, ActorKeys.key(child), subject);
    String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
    db.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant, device, subject, registration, "BYOD fixture", clock.millis());
    String application = create("/api/v1/tenants/" + tenant + "/applications", owner,
        Map.of("displayName", "测试游戏", "platform", "ANDROID", "packageName",
            "org.example.game.g" + UUID.randomUUID().toString().replace("-", ""),
            "profile", "PRIMARY", "signingDigests", List.of("a".repeat(64)))).get("id").asText();
    String policy = create("/api/v1/tenants/" + tenant + "/policies", owner,
        Map.of("name", "游戏规则", "kind", "POLICY", "rules", List.of(Map.of("id", "game",
            "kind", "APP_LAUNCH", "effect", "DENY", "applicationId", application, "required", true))))
        .get("id").asText();
    String policyPath = "/api/v1/tenants/" + tenant + "/policies/" + policy;
    var preview = json.readTree(mvc.perform(post(policyPath + "/previews").with(actor(owner))
            .header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsString(Map.of("deviceIds", List.of(device)))))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    var publication = json.readTree(mvc.perform(post(policyPath + "/publications").with(actor(owner))
            .header("If-Match", "\"0\"").header("Idempotency-Key", key())
            .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of(
                "previewId", preview.get("id").asText(), "previewHash", preview.get("hash").asText(),
                "mode", "CONFIGURE_ONLY"))))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    return new Scope(owner, child, tenant, subject, device, registration, application, policy,
        publication.get("versionId").asText());
  }

  private JsonNode create(String path, String owner, Map<String, ?> input) throws Exception {
    return json.readTree(mvc.perform(post(path).with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsString(input)))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
  }

  private RequestPostProcessor actor(String id) {
    return jwt().jwt(token -> token.subject(id).claim("auth_time", clock.instant().getEpochSecond())
            .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private Map<String, Object> input(Scope scope) {
    return Map.of("deviceId", scope.device(), "policyId", scope.policy(), "baseVersionId", scope.version(),
        "applicationId", scope.application(), "ruleIds", List.of("game"), "requestedWindowSeconds", 600,
        "reason", "想和同学一起玩一会");
  }

  private String ownerDigest(String tenant, String subject) throws Exception {
    return digest("idempotency-subject-v1\n" + tenant + "\n" + subject);
  }

  private String digest(String value) throws Exception {
    return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
        .digest(value.getBytes(StandardCharsets.UTF_8)));
  }

  private String key() { return UUID.randomUUID().toString(); }

  enum Operation {
    REQUEST("access.request", "", "PENDING", "ACCESS_REQUEST_CREATED"),
    APPROVE("access.decide", "/decisions", "APPROVED_PENDING_DELIVERY", "ACCESS_REQUEST_APPROVED"),
    DENY("access.decide", "/decisions", "DENIED", "ACCESS_REQUEST_DENIED"),
    CANCEL("access.cancel", "/cancel", "CANCELLED", "ACCESS_REQUEST_CANCELLED"),
    REVOKE("access.revoke", "/revoke", "REVOKED", "ACCESS_EXCEPTION_REVOKED");

    final String journalOperation, suffix, resultState, auditAction;
    Operation(String operation, String suffix, String state, String action) {
      this.journalOperation = operation;
      this.suffix = suffix;
      this.resultState = state;
      this.auditAction = action;
    }
    String actor(Scope scope) {
      return this == REQUEST || this == CANCEL ? scope.child() : scope.owner();
    }
  }

  private record Scope(String owner, String child, String tenant, String subject, String device,
      String registration, String application, String policy, String version) {}
  private record Fixture(String requestId, String key, JsonNode response) {}
  private record Snapshot(List<Map<String, Object>> requests, List<Map<String, Object>> decisions,
      List<Map<String, Object>> slots, List<Map<String, Object>> audits,
      List<Map<String, Object>> notifications,
      List<Map<String, Object>> journal, List<Map<String, Object>> owners) {}

  @TestConfiguration
  static class TimeConfiguration {
    @Bean @Primary StandaloneTestClock approvalAttributionClock() { return new StandaloneTestClock(); }
  }

  static final class StandaloneTestClock extends Clock {
    @Override public ZoneId getZone() { return ZoneOffset.UTC; }
    @Override public Clock withZone(ZoneId zone) { return Clock.fixed(NOW, zone); }
    @Override public Instant instant() { return NOW; }
  }
}
