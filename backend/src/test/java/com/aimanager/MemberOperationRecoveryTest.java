package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(properties = {"spring.datasource.url=jdbc:h2:mem:member_operation_recovery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password="})
@AutoConfigureMockMvc
class MemberOperationRecoveryTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  RequestPostProcessor actor(String name, boolean recent) {
    return jwt().jwt(t -> t.subject(name).claim("auth_time", recent ? Instant.now().getEpochSecond() : 1L)
        .claim("amr", recent ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  JsonNode mutate(String method, String path, String actor, String key, Integer version, Object body) throws Exception {
    var req = request(HttpMethod.valueOf(method), path).with(actor(actor, true)).contentType(MediaType.APPLICATION_JSON);
    if (body != null) req.content(json.writeValueAsString(body));
    if (key != null) req.header("Idempotency-Key", key);
    if (version != null) req.header("If-Match", "\"" + version + "\"");
    var value = mvc.perform(req).andExpect(status().is2xxSuccessful()).andReturn().getResponse().getContentAsString();
    return value.isEmpty() ? null : json.readTree(value);
  }
  JsonNode query(String root, String memberKey, String actor, String key, Object input, int expected) throws Exception {
    var response = mvc.perform(post(root + "/members/" + memberKey + "/access-results/" + key + "/query")
        .with(actor(actor, false)).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(input)))
        .andExpect(status().is(expected));
    if (expected == 200) response.andExpect(header().string("Cache-Control", "no-store"));
    return json.readTree(response.andReturn().getResponse().getContentAsString());
  }
  @Test void normalizedScopeHistoryAndRejoinedMembershipAreDistinctFromOriginalSuccess() throws Exception {
    String owner = "member-recovery-" + UUID.randomUUID(), teacher = owner + "-teacher", memberKey = ActorKeys.key(teacher);
    String tenant = mutate("POST", "/api/v1/tenants", owner, null, null,
        Map.of("name", "Institution", "kind", "ORGANIZATION", "timeZone", "UTC")).get("id").asText();
    String root = "/api/v1/tenants/" + tenant, path = root + "/members/" + memberKey + "/access";
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'AUDITOR')", tenant, teacher, memberKey);
    String a = mutate("POST", root + "/classes", owner, UUID.randomUUID().toString(), null, Map.of("name", "A")).get("id").asText();
    String b = mutate("POST", root + "/classes", owner, UUID.randomUUID().toString(), null, Map.of("name", "B")).get("id").asText();
    String updateKey = UUID.randomUUID().toString(), revokeKey = UUID.randomUUID().toString();
    var input = new LinkedHashMap<String, Object>(); input.put("role", "TEACHER"); input.put("subjectId", null); input.put("classIds", List.of(b, a));
    var changed = mutate("PATCH", path, owner, updateKey, 0, input);
    var descriptor = new LinkedHashMap<>(input); descriptor.put("operation", "UPDATE"); descriptor.put("version", 0);
    descriptor.put("classIds", List.of(a, b)); // Normalization matches the write's fingerprint.
    var original = query(root, memberKey, owner, updateKey, descriptor, 200);
    assertThat(original.get("committedAccess")).isEqualTo(changed);
    assertThat(original.get("currentState").asText()).isEqualTo("ACTIVE");
    assertThat(mutate("PATCH", path, owner, updateKey, 0, input)).isEqualTo(changed);
    mutate("DELETE", path, owner, revokeKey, 1, null);
    var revocation = Map.of("operation", "REVOKE", "version", 1);
    original = query(root, memberKey, owner, revokeKey, revocation, 200);
    assertThat(original.get("revocationCommitted").asBoolean()).isTrue();
    assertThat(original.get("committedAccess").isNull()).isTrue();
    assertThat(original.get("currentState").asText()).isEqualTo("REVOKED");
    assertThat(original.get("current").get("version").asLong()).isEqualTo(2);
    // Explicit rejoin fixture: original revocation must not be reported as current revocation.
    db.update("UPDATE tenant_members SET revoked_at=NULL,role='AUDITOR',subject_id=NULL,version=version+1 WHERE tenant_id=? AND actor_key=?", tenant, memberKey);
    db.update("DELETE FROM tenant_member_class_scopes WHERE tenant_id=? AND actor_key=?", tenant, memberKey);
    original = query(root, memberKey, owner, revokeKey, revocation, 200);
    assertThat(original.get("revocationCommitted").asBoolean()).isTrue();
    assertThat(original.get("currentState").asText()).isEqualTo("ACTIVE");
    assertThat(original.get("current").get("version").asLong()).isEqualTo(3);
    original = query(root, memberKey, owner, updateKey, descriptor, 200);
    assertThat(original.get("committedAccess")).isEqualTo(changed);
    assertThat(original.get("current").get("role").asText()).isEqualTo("AUDITOR");
    descriptor.put("version", 1); query(root, memberKey, owner, updateKey, descriptor, 409); descriptor.put("version", 0);
    query(root, memberKey, owner, revokeKey, Map.of("operation", "REVOKE", "version", 1, "role", "AUDITOR"), 400);
    query(root, memberKey, owner, UUID.randomUUID().toString(), descriptor, 404);
    for (String role : List.of("ORG_ADMIN", "TEACHER", "AUDITOR", "GUARDIAN")) {
      String member = owner + role;
      db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,?)", tenant, member, ActorKeys.key(member), role);
      query(root, memberKey, member, updateKey, descriptor, role.equals("ORG_ADMIN") ? 404 : 403);
    }
    query(root, memberKey, "other-tenant-owner", updateKey, descriptor, 403);
    mvc.perform(post(root + "/members/" + memberKey + "/access-results/" + updateKey + "/query")
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(descriptor))).andExpect(status().isUnauthorized());
    db.update("UPDATE idempotency_requests SET expires_at=1 WHERE scope_id=?", tenant);
    query(root, memberKey, owner, updateKey, descriptor, 200);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM membership_access_changes WHERE tenant_id=? AND member_key=?", Long.class, tenant, memberKey)).isEqualTo(2);
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?", tenant, ActorKeys.key(owner));
    query(root, memberKey, owner, updateKey, descriptor, 403);
  }
}
