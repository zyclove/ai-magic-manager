package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
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
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Real read-only HTTP/SQL checks; these results never establish network filtering. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:policy-domain-evaluation;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc
class PolicyDomainEvaluationJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate database;
  @MockitoBean JwtDecoder decoder;

  private RequestPostProcessor actor(String name) {
    return jwt().jwt(token -> token.subject(name)
        .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private Scope scope(String kind, List<?> rules) throws Exception {
    String owner = "domain-owner-" + UUID.randomUUID();
    var tenant = mapper.readTree(mvc.perform(post("/api/v1/tenants").with(actor(owner))
        .contentType(MediaType.APPLICATION_JSON)
        .content(mapper.writeValueAsString(Map.of("name", "域名检查", "kind", kind,
            "timeZone", "Asia/Shanghai"))))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    String tenantId = tenant.path("id").asText();
    var draft = mapper.readTree(mvc.perform(post("/api/v1/tenants/{tenant}/policies", tenantId)
        .with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content(mapper.writeValueAsString(Map.of("name", "域名配置", "kind", "POLICY", "rules", rules))))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    return new Scope(owner, tenantId, draft.path("id").asText());
  }

  private Map<String, Object> rule(String id, String effect, String domain) {
    return Map.of("id", id, "kind", "DOMAIN_ACCESS", "effect", effect,
        "required", true, "domain", domain);
  }

  private String target(Scope scope) {
    return "/api/v1/tenants/" + scope.tenant() + "/policies/" + scope.policy() + "/domain-evaluations";
  }

  private MockHttpServletRequestBuilder check(Scope scope, String who, String domain) throws Exception {
    return post(target(scope)).with(actor(who)).header("If-Match", "\"0\"")
        .contentType(MediaType.APPLICATION_JSON)
        .content(mapper.writeValueAsString(Map.of("domain", domain)));
  }

  private JsonNode result(Scope scope, String domain) throws Exception {
    return mapper.readTree(mvc.perform(check(scope, scope.owner(), domain))
        .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
        .andReturn().getResponse().getContentAsString());
  }

  private String member(Scope scope, String role) throws Exception {
    String who = role.toLowerCase(java.util.Locale.ROOT) + "-" + UUID.randomUUID();
    String subject = null;
    if ("CHILD".equals(role)) {
      subject = mapper.readTree(mvc.perform(post("/api/v1/tenants/{tenant}/subjects", scope.tenant())
          .with(actor(scope.owner())).contentType(MediaType.APPLICATION_JSON)
          .content("{\"nickname\":\"儿童\",\"ageBand\":\"AGE_7_12\"}"))
          .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString())
          .path("id").asText();
    }
    database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,?,?)",
        scope.tenant(), who, ActorKeys.key(who), role, subject);
    return who;
  }

  private Map<String, Long> writeCounts(Scope scope) {
    var counts = new LinkedHashMap<String, Long>();
    for (String table : List.of("policy_drafts", "policy_previews", "policy_versions",
        "policy_publications", "policy_outbox", "audit_events", "idempotency_requests")) {
      String ownerColumn = table.equals("idempotency_requests") ? "scope_id" : "tenant_id";
      counts.put(table, database.queryForObject("SELECT COUNT(*) FROM " + table + " WHERE " + ownerColumn + "=?",
          Long.class, scope.tenant()));
    }
    return counts;
  }

  @Test
  void exactConflictExplainsCurrentDraftWithoutWritingOrClaimingExecution() throws Exception {
    var scope = scope("FAMILY", List.of(rule("z-allow", "ALLOW", "example.invalid"),
        rule("a-deny", "DENY", "example.invalid"), rule("m-allow", "ALLOW", "example.invalid"),
        rule("other-domain", "DENY", "elsewhere.invalid")));
    var counts = writeCounts(scope);
    var draft = database.queryForMap("SELECT name,kind,revision,next_sequence,created_at,updated_at"
        + " FROM policy_drafts WHERE tenant_id=? AND id=?", scope.tenant(), scope.policy());
    var rules = database.queryForObject("SELECT rules_json FROM policy_drafts WHERE tenant_id=? AND id=?",
        String.class, scope.tenant(), scope.policy());

    var answer = result(scope, "  EXAMPLE.INVALID  ");
    var fields = new ArrayList<String>();
    answer.fieldNames().forEachRemaining(fields::add);
    assertThat(fields).containsExactlyInAnyOrder("policyId", "draftRevision", "canonicalDomain",
        "matchingRuleIds", "predictedEffect", "effectiveEffect", "matchMode", "executionStatus");
    assertThat(answer.path("policyId").asText()).isEqualTo(scope.policy());
    assertThat(answer.path("draftRevision").asLong()).isZero();
    assertThat(answer.path("canonicalDomain").asText()).isEqualTo("example.invalid");
    assertThat(answer.path("matchingRuleIds")).isEqualTo(mapper.valueToTree(List.of("a-deny", "m-allow", "z-allow")));
    assertThat(answer.path("predictedEffect").asText()).isEqualTo("DENY");
    assertThat(answer.get("effectiveEffect").isNull()).isTrue();
    assertThat(answer.path("matchMode").asText()).isEqualTo("EXACT_DOMAIN");
    assertThat(answer.path("executionStatus").asText()).isEqualTo("NOT_EVALUATED");
    result(scope, "example.invalid");
    assertThat(writeCounts(scope)).isEqualTo(counts);
    assertThat(database.queryForMap("SELECT name,kind,revision,next_sequence,created_at,updated_at"
        + " FROM policy_drafts WHERE tenant_id=? AND id=?", scope.tenant(), scope.policy())).isEqualTo(draft);
    assertThat(database.queryForObject("SELECT rules_json FROM policy_drafts WHERE tenant_id=? AND id=?",
        String.class, scope.tenant(), scope.policy())).isEqualTo(rules);
  }

  @Test
  void idnAndCaseAreNormalizedButSubdomainsAreNotImplicitlyAllowed() throws Exception {
    var scope = scope("FAMILY", List.of(rule("allow-host", "ALLOW", "example.invalid"),
        rule("deny-idn", "DENY", "xn--bcher-kva.example")));
    assertThat(result(scope, "EXAMPLE.INVALID").path("predictedEffect").asText()).isEqualTo("ALLOW");
    var idn = result(scope, " BÜCHER.Example ");
    assertThat(idn.path("canonicalDomain").asText()).isEqualTo("xn--bcher-kva.example");
    assertThat(idn.path("matchingRuleIds")).isEqualTo(mapper.valueToTree(List.of("deny-idn")));
    assertThat(idn.path("predictedEffect").asText()).isEqualTo("DENY");
    for (String host : List.of("sub.example.invalid", "unlisted.invalid")) {
      var answer = result(scope, host);
      assertThat(answer.path("matchingRuleIds").isEmpty()).isTrue();
      assertThat(answer.path("predictedEffect").asText()).isEqualTo("NO_MATCH");
      assertThat(answer.get("effectiveEffect").isNull()).isTrue();
      assertThat(answer.path("executionStatus").asText()).isEqualTo("NOT_EVALUATED");
    }
  }

  @Test
  void currentReadRolesAreAllowedButChildrenTeachersRevocationAndForeignTenantsAreDenied() throws Exception {
    var family = scope("FAMILY", List.of());
    for (String who : List.of(family.owner(), member(family, "GUARDIAN"), member(family, "AUDITOR"))) {
      mvc.perform(check(family, who, "example.invalid")).andExpect(status().isOk());
    }
    var organization = scope("ORGANIZATION", List.of());
    mvc.perform(check(organization, member(organization, "ORG_ADMIN"), "example.invalid"))
        .andExpect(status().isOk());
    mvc.perform(check(family, member(family, "CHILD"), "example.invalid")).andExpect(status().isForbidden());
    mvc.perform(check(organization, member(organization, "TEACHER"), "example.invalid"))
        .andExpect(status().isForbidden());
    String revoked = member(family, "AUDITOR");
    database.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",
        family.tenant(), ActorKeys.key(revoked));
    mvc.perform(check(family, revoked, "example.invalid")).andExpect(status().isForbidden());
    mvc.perform(check(organization, family.owner(), "example.invalid")).andExpect(status().isForbidden());
    var wrongPolicy = new Scope(family.owner(), family.tenant(), organization.policy());
    mvc.perform(check(wrongPolicy, family.owner(), "example.invalid")).andExpect(status().isForbidden());
  }

  @Test
  void checkingRequiresOneCurrentStrongDraftVersion() throws Exception {
    var scope = scope("FAMILY", List.of());
    String body = "{\"domain\":\"example.invalid\"}";
    mvc.perform(post(target(scope)).with(actor(scope.owner())).contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isPreconditionRequired()).andExpect(jsonPath("$.errorCode").value("VERSION_REQUIRED"));
    for (String invalid : List.of("*", "W/\"0\"", "\"0\",\"1\"")) {
      mvc.perform(post(target(scope)).with(actor(scope.owner())).header("If-Match", invalid)
          .contentType(MediaType.APPLICATION_JSON).content(body))
          .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("INVALID_VERSION"));
    }
    mvc.perform(post(target(scope)).with(actor(scope.owner())).header("If-Match", "\"1\"")
        .contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isPreconditionFailed())
        .andExpect(jsonPath("$.errorCode").value("RESOURCE_VERSION_CONFLICT"));
  }

  @Test
  void malformedDomainsAndExtraExecutionFieldsAreRejectedBeforeAnyWrite() throws Exception {
    var scope = scope("FAMILY", List.of());
    var counts = writeCounts(scope);
    for (String invalid : List.of("", "   ", "https://example.invalid/path", "127.0.0.1",
        "*.example.invalid", "example.invalid.", "example.invalid:443", "a".repeat(250) + ".com")) {
      mvc.perform(check(scope, scope.owner(), invalid)).andExpect(status().isBadRequest());
    }
    for (String body : List.of("{}", "{\"domain\":null}",
        "{\"domain\":\"example.invalid\",\"execute\":true}")) {
      mvc.perform(post(target(scope)).with(actor(scope.owner())).header("If-Match", "\"0\"")
          .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isBadRequest());
    }
    assertThat(writeCounts(scope)).isEqualTo(counts);
  }

  private record Scope(String owner, String tenant, String policy) {}
}
