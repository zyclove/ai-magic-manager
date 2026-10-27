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

/** Real branch writes and CONFIGURE_ONLY versions; fixtures do not certify device execution. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:policy_draft_branches;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class PolicyDraftBranchJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;

  private record Scope(String tenant, String owner, String device) {
    String root() { return "/api/v1/tenants/" + tenant; }
  }

  private record Branches(Scope scope, JsonNode template, JsonNode copy, JsonNode rollback,
      String versionId, String copyKey, String rollbackKey) {
    String copyWriter() { return scope.root() + "/policies/" + template.path("id").asText() + "/copies"; }
    String copyQuery() { return scope.root() + "/policies/" + template.path("id").asText()
        + "/copy-results/" + copyKey + "/query"; }
    String rollbackWriter() { return scope.root() + "/policies/" + copy.path("id").asText()
        + "/versions/" + versionId + "/rollback-drafts"; }
    String rollbackQuery() { return scope.root() + "/policies/" + copy.path("id").asText()
        + "/versions/" + versionId + "/rollback-draft-results/" + rollbackKey + "/query"; }
  }

  private RequestPostProcessor actor(String id, boolean recentMfa) {
    return jwt().jwt(token -> token.subject(id)
        .claim("auth_time", recentMfa ? Instant.now().getEpochSecond() : 1L)
        .claim("amr", recentMfa ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private JsonNode created(MockHttpServletRequestBuilder request) throws Exception {
    return json.readTree(mvc.perform(request).andExpect(status().isCreated())
        .andReturn().getResponse().getContentAsString());
  }

  private Scope scope() throws Exception {
    String owner = UUID.randomUUID().toString();
    var tenant = created(post("/api/v1/tenants").with(actor(owner, true))
        .contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"策略分支\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"));
    String tenantId = tenant.path("id").asText();
    var subject = created(post("/api/v1/tenants/" + tenantId + "/subjects").with(actor(owner, true))
        .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"小星\",\"ageBand\":\"AGE_7_12\"}"));
    String device = UUID.randomUUID().toString();
    // Same scoped active-device fixture as PolicyJourneyTest; no capability receipt is fabricated.
    db.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
        + " VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)", tenantId, device,
        subject.path("id").asText(), UUID.randomUUID().toString(), "测试设备", Instant.now().toEpochMilli());
    return new Scope(tenantId, owner, device);
  }

  private MockHttpServletRequestBuilder named(String path, String who, String etag, String name, boolean mfa)
      throws Exception {
    var request = post(path).with(actor(who, mfa)).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("name", name)));
    return etag == null ? request : request.header("If-Match", etag);
  }

  private JsonNode edit(Scope scope, String id, long revision, String name) throws Exception {
    return json.readTree(mvc.perform(put(scope.root() + "/policies/" + id).with(actor(scope.owner(), true))
        .header("If-Match", "\"" + revision + "\"").contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("name", name, "rules", List.of()))))
        .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
  }

  private Branches branches() throws Exception {
    var scope = scope();
    var application = created(post(scope.root() + "/applications").with(actor(scope.owner(), true))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of(
            "displayName", "阅读应用", "platform", "ANDROID", "packageName", "org.example.reader",
            "profile", "PRIMARY", "signingDigests", List.of("a".repeat(64))))));
    var template = created(post(scope.root() + "/policies").with(actor(scope.owner(), true))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of(
            "name", "原模板", "kind", "TEMPLATE", "rules", List.of(Map.of("id", "reader",
                "kind", "APP_LAUNCH", "effect", "DENY", "required", true,
                "applicationId", application.path("id").asText()))))));
    String copyKey = UUID.randomUUID().toString();
    String policyPath = scope.root() + "/policies/" + template.path("id").asText();
    var copy = created(named(policyPath + "/copies", scope.owner(), "\"0\"", "复制规则", true)
        .header("Idempotency-Key", copyKey));
    String copiedPath = scope.root() + "/policies/" + copy.path("id").asText();
    var preview = created(post(copiedPath + "/previews").with(actor(scope.owner(), true))
        .header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("deviceIds", List.of(scope.device())))));
    var publication = created(post(copiedPath + "/publications").with(actor(scope.owner(), true))
        .header("If-Match", "\"0\"").header("Idempotency-Key", UUID.randomUUID().toString())
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of(
            "previewId", preview.path("id").asText(), "previewHash", preview.path("hash").asText(),
            "mode", "CONFIGURE_ONLY"))));
    assertThat(publication.path("state").asText()).isEqualTo("CONFIGURED_NOT_ENFORCED");
    edit(scope, copy.path("id").asText(), 0, "暂时修改");
    String version = publication.path("versionId").asText(), rollbackKey = UUID.randomUUID().toString();
    var rollback = created(named(copiedPath + "/versions/" + version + "/rollback-drafts",
        scope.owner(), "\"1\"", "恢复规则", true).header("Idempotency-Key", rollbackKey));
    return new Branches(scope, template, copy, rollback, version, copyKey, rollbackKey);
  }

  @Test void branchQueriesKeepOriginalRulesAndSourceSeparateFromLaterDraftRevisions() throws Exception {
    var fixture = branches();
    var scope = fixture.scope();
    String id = fixture.copy().path("id").asText();
    assertThat(fixture.copy().path("kind").asText()).isEqualTo("POLICY");
    assertThat(fixture.copy().path("revision").asLong()).isZero();
    assertThat(fixture.copy().path("rules")).isEqualTo(fixture.template().path("rules"));
    assertThat(fixture.rollback().path("id").asText()).isEqualTo(id);
    assertThat(fixture.rollback().path("revision").asLong()).isEqualTo(2);
    assertThat(fixture.rollback().path("sourceVersionId").asText()).isEqualTo(fixture.versionId());
    assertThat(fixture.rollback().path("rules")).isEqualTo(fixture.copy().path("rules"));
    edit(scope, fixture.template().path("id").asText(), 0, "模板已变化");
    var latest = edit(scope, id, 2, "后来编辑");
    var originalCopy = json.readTree(mvc.perform(named(fixture.copyQuery(), scope.owner(), "\"0\"", "复制规则", false))
        .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(jsonPath("$.requestId").value(fixture.copyKey()))
        .andExpect(jsonPath("$.operation").value("TEMPLATE_COPY"))
        .andReturn().getResponse().getContentAsString());
    var originalRollback = json.readTree(mvc.perform(named(fixture.rollbackQuery(), scope.owner(), "\"1\"", "恢复规则", false))
        .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(jsonPath("$.requestId").value(fixture.rollbackKey()))
        .andExpect(jsonPath("$.operation").value("ROLLBACK_DRAFT"))
        .andReturn().getResponse().getContentAsString());
    assertThat(originalCopy.path("committed")).isEqualTo(fixture.copy());
    assertThat(originalRollback.path("committed")).isEqualTo(fixture.rollback());
    assertThat(originalCopy.path("current")).isEqualTo(latest);
    assertThat(originalRollback.path("current")).isEqualTo(latest);
    assertThat(created(named(fixture.copyWriter(), scope.owner(), "\"0\"", "复制规则", true)
        .header("Idempotency-Key", fixture.copyKey()))).isEqualTo(fixture.copy());
    assertThat(created(named(fixture.rollbackWriter(), scope.owner(), "\"1\"", "恢复规则", true)
        .header("Idempotency-Key", fixture.rollbackKey()))).isEqualTo(fixture.rollback());
    mvc.perform(named(fixture.rollbackWriter(), scope.owner(), "\"1\"", "恢复规则", false)
        .header("Idempotency-Key", fixture.rollbackKey())).andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=? AND operation IN (?,?)",
        scope.tenant(), "policy.template.copy", "policy.rollback-draft");
    mvc.perform(named(fixture.copyQuery(), scope.owner(), "\"0\"", "复制规则", false))
        .andExpect(status().isOk()).andExpect(jsonPath("$.committed.revision").value(0))
        .andExpect(jsonPath("$.current.revision").value(3));
    mvc.perform(named(fixture.rollbackQuery(), scope.owner(), "\"1\"", "恢复规则", false))
        .andExpect(status().isOk()).andExpect(jsonPath("$.committed.revision").value(2))
        .andExpect(jsonPath("$.current.revision").value(3));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM policy_drafts WHERE tenant_id=?", Integer.class, scope.tenant())).isEqualTo(2);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM policy_versions WHERE tenant_id=?", Integer.class, scope.tenant())).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='POLICY_ROLLBACK_DRAFT_CREATED'",
        Integer.class, scope.tenant())).isEqualTo(1);
    assertThat(db.queryForObject("SELECT revision FROM policy_drafts WHERE tenant_id=? AND id=?", Long.class,
        scope.tenant(), id)).isEqualTo(3);
  }

  @Test void exactBodyCreatorTenantAndCurrentWriteRoleGuardEveryLookup() throws Exception {
    var fixture = branches();
    var scope = fixture.scope();
    int journalCount = db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=?",
        Integer.class, scope.tenant());
    mvc.perform(named(fixture.copyQuery(), scope.owner(), "\"0\"", "不同名称", false))
        .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
    mvc.perform(named(fixture.rollbackQuery(), scope.owner(), "\"1\"", "不同名称", false))
        .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
    mvc.perform(named(fixture.copyQuery(), scope.owner(), "\"1\"", "复制规则", false)).andExpect(status().isConflict());
    mvc.perform(named(fixture.copyQuery().replace(fixture.template().path("id").asText(), UUID.randomUUID().toString()),
        scope.owner(), "\"0\"", "复制规则", false)).andExpect(status().isConflict());
    mvc.perform(named(fixture.rollbackQuery(), scope.owner(), "\"0\"", "恢复规则", false)).andExpect(status().isConflict());
    mvc.perform(named(fixture.rollbackQuery().replace(fixture.copy().path("id").asText(), UUID.randomUUID().toString()),
        scope.owner(), "\"1\"", "恢复规则", false)).andExpect(status().isConflict());
    mvc.perform(named(fixture.rollbackQuery().replace(fixture.versionId(), UUID.randomUUID().toString()),
        scope.owner(), "\"1\"", "恢复规则", false)).andExpect(status().isConflict());
    String writer = UUID.randomUUID().toString();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",
        scope.tenant(), writer, ActorKeys.key(writer));
    for (var query : List.of(Map.entry(fixture.copyQuery(), "复制规则"), Map.entry(fixture.rollbackQuery(), "恢复规则"))) {
      String etag = query.getKey().equals(fixture.copyQuery()) ? "\"0\"" : "\"1\"";
      mvc.perform(named(query.getKey(), writer, etag, query.getValue(), false)).andExpect(status().isNotFound())
          .andExpect(jsonPath("$.errorCode").value("POLICY_BRANCH_RESULT_UNAVAILABLE"));
      mvc.perform(named(query.getKey(), UUID.randomUUID().toString(), etag, query.getValue(), false))
          .andExpect(status().isForbidden());
    }
    var other = scope();
    mvc.perform(named(fixture.copyQuery().replace(scope.root(), other.root()), other.owner(),
        "\"0\"", "复制规则", false)).andExpect(status().isNotFound());
    mvc.perform(named(fixture.rollbackQuery().replace(scope.root(), other.root()), other.owner(),
        "\"1\"", "恢复规则", false)).andExpect(status().isNotFound());
    mvc.perform(named(fixture.copyQuery().replace(fixture.copyKey(), UUID.randomUUID().toString()),
        scope.owner(), "\"0\"", "复制规则", false)).andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("POLICY_BRANCH_RESULT_UNAVAILABLE"));
    mvc.perform(named(fixture.rollbackQuery().replace(fixture.rollbackKey(), UUID.randomUUID().toString()),
        scope.owner(), "\"1\"", "恢复规则", false)).andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("POLICY_BRANCH_RESULT_UNAVAILABLE"));
    for (String key : List.of("not-a-uuid", "ABCDEFAB-1111-4111-8111-111111111111")) {
      mvc.perform(named(fixture.copyQuery().replace(fixture.copyKey(), key), scope.owner(),
          "\"0\"", "复制规则", false)).andExpect(status().isBadRequest())
          .andExpect(jsonPath("$.errorCode").value("INVALID_POLICY_RESULT_REFERENCE"));
      mvc.perform(named(fixture.rollbackQuery().replace(fixture.rollbackKey(), key), scope.owner(),
          "\"1\"", "恢复规则", false)).andExpect(status().isBadRequest())
          .andExpect(jsonPath("$.errorCode").value("INVALID_POLICY_RESULT_REFERENCE"));
    }
    mvc.perform(named(fixture.copyQuery(), scope.owner(), null, "复制规则", false)).andExpect(status().is(428));
    mvc.perform(named(fixture.rollbackQuery(), scope.owner(), null, "恢复规则", false)).andExpect(status().is(428));
    db.update("UPDATE tenant_members SET role='AUDITOR' WHERE tenant_id=? AND actor_key=?",
        scope.tenant(), ActorKeys.key(scope.owner()));
    mvc.perform(named(fixture.copyQuery(), scope.owner(), "\"0\"", "复制规则", false)).andExpect(status().isForbidden());
    mvc.perform(named(fixture.rollbackQuery(), scope.owner(), "\"1\"", "恢复规则", false)).andExpect(status().isForbidden());
    db.update("UPDATE tenant_members SET role='OWNER',revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",
        scope.tenant(), ActorKeys.key(scope.owner()));
    mvc.perform(named(fixture.copyQuery(), scope.owner(), "\"0\"", "复制规则", false)).andExpect(status().isForbidden());
    mvc.perform(named(fixture.rollbackQuery(), scope.owner(), "\"1\"", "恢复规则", false)).andExpect(status().isForbidden());
    assertThat(db.queryForObject("SELECT COUNT(*) FROM policy_drafts WHERE tenant_id=?", Integer.class, scope.tenant())).isEqualTo(2);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM policy_versions WHERE tenant_id=?", Integer.class, scope.tenant())).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=?", Integer.class,
        scope.tenant())).isEqualTo(journalCount);
  }

  @Test void expiredAndErasedBranchResultsStayTerminalWithoutRepeatingTheOriginalWriters() throws Exception {
    var fixture = branches();
    var scope = fixture.scope();
    long committed = Instant.now().minus(Duration.ofDays(100)).toEpochMilli();
    long expiry = committed + Duration.ofDays(90).toMillis();
    db.update("UPDATE idempotency_requests SET result_committed_at=?,result_expires_at=?,result_last_observed_at=?"
        + " WHERE scope_id=? AND operation='policy.template.copy'", committed, expiry, committed, scope.tenant());
    for (int attempt = 0; attempt < 2; attempt++) {
      mvc.perform(named(fixture.copyQuery(), scope.owner(), "\"0\"", "复制规则", false)).andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESULT_EXPIRED"));
    }
    assertThat(db.queryForObject("SELECT result_expired_at FROM idempotency_requests WHERE scope_id=? AND operation='policy.template.copy'",
        Long.class, scope.tenant())).isEqualTo(expiry);
    mvc.perform(named(fixture.copyWriter(), scope.owner(), "\"0\"", "复制规则", true)
        .header("Idempotency-Key", fixture.copyKey())).andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_EXPIRED"));
    db.update("UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL,actor_id='',operation='',request_hash=?,"
        + "expires_at=0,result_storage_state='REDACTED',result_redacted_at=? WHERE scope_id=? AND operation='policy.rollback-draft'",
        "0".repeat(64), Instant.now().toEpochMilli(), scope.tenant());
    for (String name : List.of("恢复规则", "换名也不能复活")) {
      mvc.perform(named(fixture.rollbackQuery(), scope.owner(), "\"1\"", name, false)).andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
      mvc.perform(named(fixture.rollbackWriter(), scope.owner(), "\"1\"", name, true)
          .header("Idempotency-Key", fixture.rollbackKey())).andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
    }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM policy_drafts WHERE tenant_id=?", Integer.class, scope.tenant())).isEqualTo(2);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM policy_versions WHERE tenant_id=?", Integer.class, scope.tenant())).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='POLICY_ROLLBACK_DRAFT_CREATED'",
        Integer.class, scope.tenant())).isEqualTo(1);
  }
}
