package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Source-prepared integration coverage; mutation and journal must share the same transaction. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:policy_draft_changes;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class PolicyDraftChangeJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;

  private record Scope(String tenant, String owner) {
    String root() { return "/api/v1/tenants/" + tenant; }
  }

  private RequestPostProcessor actor(String id) {
    return jwt().jwt(token -> token.subject(id)
        .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private Scope fixture() throws Exception {
    String owner = UUID.randomUUID().toString();
    var response = mvc.perform(post("/api/v1/tenants").with(actor(owner))
        .contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"策略草稿\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse();
    return new Scope(json.readTree(response.getContentAsString()).path("id").asText(), owner);
  }

  private List<Map<String, Object>> rules(int seconds) {
    return List.of(
        Map.of("id", "daily", "kind", "DAILY_QUOTA", "effect", "LIMIT", "required", true,
            "seconds", seconds),
        Map.of("id", "domain", "kind", "DOMAIN_ACCESS", "effect", "DENY", "required", false,
            "domain", "example.com"));
  }

  private Map<String, Object> create() {
    return Map.of("operation", "CREATE", "name", "原始规则", "kind", "POLICY", "rules", rules(3600));
  }

  private Map<String, Object> update(String id, long revision) {
    return Map.of("operation", "UPDATE", "policyId", id, "revision", revision,
        "name", "调整规则", "rules", rules(2400));
  }

  private MockHttpServletRequestBuilder change(Scope scope, String who, String key, Object body)
      throws Exception {
    var request = post(scope.root() + "/policy-draft-changes").with(actor(who))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body));
    return key == null ? request : request.header("Idempotency-Key", key);
  }

  private MockHttpServletRequestBuilder query(Scope scope, String who, String key, Object body)
      throws Exception {
    return post(scope.root() + "/policy-draft-operation-results/" + key + "/query")
        .with(actor(who)).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body));
  }

  private JsonNode changed(Scope scope, String key, Object input) throws Exception {
    return json.readTree(mvc.perform(change(scope, scope.owner(), key, input))
        .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
        .andReturn().getResponse().getContentAsString());
  }

  private int drafts(Scope scope) {
    return db.queryForObject("SELECT COUNT(*) FROM policy_drafts WHERE tenant_id=?", Integer.class, scope.tenant());
  }

  @Test void fullDraftCreateAndUpdateCommitOnceAndQueriesSeparateOriginalFromCurrent() throws Exception {
    var scope = fixture();
    String createKey = UUID.randomUUID().toString(), updateKey = UUID.randomUUID().toString();
    var created = changed(scope, createKey, create());
    String id = created.path("id").asText();
    assertThat(created.path("revision").asLong()).isZero();
    assertThat(created.path("rules").size()).isEqualTo(2);
    assertThat(created.at("/rules/0/seconds").asInt()).isEqualTo(3600);
    assertThat(created.at("/rules/1/domain").asText()).isEqualTo("example.com");
    assertThat(changed(scope, createKey, create())).isEqualTo(created);
    var input = update(id, 0);
    var updated = changed(scope, updateKey, input);
    assertThat(updated.path("revision").asLong()).isEqualTo(1);
    assertThat(updated.at("/rules/0/seconds").asInt()).isEqualTo(2400);
    assertThat(updated.at("/rules/1/domain").asText()).isEqualTo("example.com");
    assertThat(changed(scope, updateKey, input)).isEqualTo(updated);
    mvc.perform(put(scope.root() + "/policies/" + id).with(actor(scope.owner()))
        .header("If-Match", "\"1\"").contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("name", "后来修改", "rules", List.of()))))
        .andExpect(status().isOk()).andExpect(jsonPath("$.revision").value(2));
    for (var original : List.of(Map.entry(createKey, create()), Map.entry(updateKey, input))) {
      var result = json.readTree(mvc.perform(query(scope, scope.owner(), original.getKey(), original.getValue()))
          .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
          .andExpect(jsonPath("$.current.name").value("后来修改"))
          .andExpect(jsonPath("$.current.revision").value(2))
          .andReturn().getResponse().getContentAsString());
      assertThat(result.path("operation").asText()).isEqualTo(original.getValue().get("operation"));
      assertThat(result.path("committed")).isEqualTo(original.getKey().equals(createKey) ? created : updated);
    }
    assertThat(changed(scope, createKey, create())).isEqualTo(created);
    assertThat(changed(scope, updateKey, input)).isEqualTo(updated);
    assertThat(drafts(scope)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='POLICY_DRAFT_CREATED'",
        Integer.class, scope.tenant())).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='POLICY_DRAFT_UPDATED'",
        Integer.class, scope.tenant())).isEqualTo(2);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=? AND operation='policy.draft.change' AND response_state='NON_SUBJECT'",
        Integer.class, scope.tenant())).isEqualTo(2);
    db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=? AND operation='policy.draft.change'", scope.tenant());
    mvc.perform(query(scope, scope.owner(), createKey, create())).andExpect(status().isOk())
        .andExpect(jsonPath("$.committed.revision").value(0));
  }

  @Test void actorTenantPayloadAndExactRevisionGuardsDoNotWriteOrExposeAnotherResult() throws Exception {
    var scope = fixture();
    String key = UUID.randomUUID().toString();
    String id = changed(scope, key, create()).path("id").asText();
    String otherWriter = UUID.randomUUID().toString();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",
        scope.tenant(), otherWriter, ActorKeys.key(otherWriter));
    mvc.perform(query(scope, otherWriter, key, create())).andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("POLICY_DRAFT_RESULT_UNAVAILABLE"));
    mvc.perform(query(scope, UUID.randomUUID().toString(), key, create())).andExpect(status().isForbidden());
    var otherTenant = fixture();
    mvc.perform(query(otherTenant, otherTenant.owner(), key, create())).andExpect(status().isNotFound());
    mvc.perform(change(otherTenant, otherTenant.owner(), UUID.randomUUID().toString(), update(id, 0)))
        .andExpect(status().isForbidden());
    assertThat(drafts(otherTenant)).isZero();
    var changedBody = new LinkedHashMap<>(create());
    changedBody.put("rules", rules(1800));
    mvc.perform(query(scope, scope.owner(), key, changedBody)).andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
    mvc.perform(change(scope, scope.owner(), key, changedBody)).andExpect(status().isConflict());
    mvc.perform(change(scope, scope.owner(), UUID.randomUUID().toString(), update(id, 7)))
        .andExpect(status().isPreconditionFailed());
    for (Object revision : List.of(7.5, "0", -1L, 9007199254740991L)) {
      var invalid = new LinkedHashMap<>(update(id, 0));
      invalid.put("revision", revision);
      mvc.perform(change(scope, scope.owner(), UUID.randomUUID().toString(), invalid))
          .andExpect(status().isBadRequest());
    }
    for (var invalid : List.of(
        Map.of("operation", "CREATE", "name", "无类型", "rules", rules(3600)),
        Map.of("operation", "CREATE", "name", "不应含旧编号", "kind", "POLICY", "policyId", id, "rules", rules(3600)),
        Map.of("operation", "UPDATE", "name", "不应改变类型", "policyId", id, "revision", 0,
            "kind", "TEMPLATE", "rules", rules(2400)))) {
      mvc.perform(change(scope, scope.owner(), UUID.randomUUID().toString(), invalid))
          .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("INVALID_POLICY_DRAFT_CHANGE"));
    }
    for (String badKey : new String[] {null, "not-a-uuid", "ABCDEFAB-1111-4111-8111-111111111111"}) {
      mvc.perform(change(scope, scope.owner(), badKey, create())).andExpect(status().isBadRequest())
          .andExpect(jsonPath("$.errorCode").value("INVALID_POLICY_DRAFT_CHANGE"));
    }
    mvc.perform(change(scope, scope.owner(), UUID.randomUUID().toString(), update("opaque-missing-policy", 0)))
        .andExpect(status().isForbidden());
    var compilerRejected = new LinkedHashMap<>(update(id, 0));
    compilerRejected.put("rules", List.of(Map.of("id", "bad-effect", "kind", "DAILY_QUOTA", "effect", "ALLOW",
        "required", true, "seconds", 1200)));
    mvc.perform(change(scope, scope.owner(), UUID.randomUUID().toString(), compilerRejected))
        .andExpect(status().isBadRequest());
    assertThat(db.queryForObject("SELECT revision FROM policy_drafts WHERE tenant_id=? AND id=?", Long.class,
        scope.tenant(), id)).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=? AND operation='policy.draft.change'",
        Integer.class, scope.tenant())).isEqualTo(1);
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",
        scope.tenant(), ActorKeys.key(scope.owner()));
    mvc.perform(query(scope, scope.owner(), key, create())).andExpect(status().isForbidden());
    mvc.perform(change(scope, scope.owner(), key, create())).andExpect(status().isForbidden());
  }

  @Test void resultExpiryAndErasureRemainTerminalWithoutReplayingChanges() throws Exception {
    var expired = fixture();
    String expiredKey = UUID.randomUUID().toString();
    changed(expired, expiredKey, create());
    long committedAt = Instant.now().minus(Duration.ofDays(100)).toEpochMilli();
    long expiresAt = committedAt + Duration.ofDays(90).toMillis();
    db.update("UPDATE idempotency_requests SET result_committed_at=?,result_expires_at=?,result_last_observed_at=?"
        + " WHERE scope_id=? AND operation='policy.draft.change'", committedAt, expiresAt, committedAt, expired.tenant());
    for (int attempt = 0; attempt < 2; attempt++) {
      mvc.perform(query(expired, expired.owner(), expiredKey, create())).andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESULT_EXPIRED"));
    }
    assertThat(db.queryForObject("SELECT result_expired_at FROM idempotency_requests WHERE scope_id=? AND operation='policy.draft.change'",
        Long.class, expired.tenant())).isEqualTo(expiresAt);
    mvc.perform(change(expired, expired.owner(), expiredKey, create())).andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_EXPIRED"));
    assertThat(drafts(expired)).isEqualTo(1);

    var erased = fixture();
    String erasedKey = UUID.randomUUID().toString();
    changed(erased, erasedKey, create());
    db.update("UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL,actor_id='',operation='',"
        + "request_hash=?,expires_at=0,result_storage_state='REDACTED',result_redacted_at=? WHERE scope_id=? AND operation='policy.draft.change'",
        "0".repeat(64), Instant.now().toEpochMilli(), erased.tenant());
    var different = new LinkedHashMap<>(create());
    different.put("name", "不能用旧键另存");
    for (var input : List.of(create(), different)) {
      mvc.perform(query(erased, erased.owner(), erasedKey, input)).andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
      mvc.perform(change(erased, erased.owner(), erasedKey, input)).andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
    }
    assertThat(drafts(erased)).isEqualTo(1);
  }
}
