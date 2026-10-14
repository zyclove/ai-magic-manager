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

@SpringBootTest(properties = {"spring.datasource.url=jdbc:h2:mem:class_operation_recovery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password="})
@AutoConfigureMockMvc
class ClassOperationRecoveryTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  RequestPostProcessor actor(String name, boolean recent) {
    return jwt().jwt(t -> t.subject(name).claim("auth_time", recent ? Instant.now().getEpochSecond() : 1L)
        .claim("amr", recent ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  JsonNode mutate(String method, String path, String owner, String key, Integer version, Object body) throws Exception {
    var req = request(HttpMethod.valueOf(method), path).with(actor(owner, true)).contentType(MediaType.APPLICATION_JSON);
    if (key != null) req.header("Idempotency-Key", key);
    if (version != null) req.header("If-Match", "\"" + version + "\"");
    if (body != null) req.content(json.writeValueAsString(body));
    return json.readTree(mvc.perform(req).andExpect(status().is2xxSuccessful()).andReturn().getResponse().getContentAsString());
  }
  JsonNode query(String root, String owner, String key, Object input, int expected) throws Exception {
    var result = mvc.perform(post(root + "/operation-results/" + key + "/query").with(actor(owner, false))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(input))).andExpect(status().is(expected));
    if (expected == 200) result.andExpect(header().string("Cache-Control", "no-store"));
    return json.readTree(result.andReturn().getResponse().getContentAsString());
  }
  @Test void allSixOperationsRecoverExactOriginalAndLatestWithoutMfaOrDuplicateMutations() throws Exception {
    String owner = "class-recovery-" + UUID.randomUUID();
    String tenant = mutate("POST", "/api/v1/tenants", owner, null, null,
        Map.of("name", "Institution", "kind", "ORGANIZATION", "timeZone", "UTC")).get("id").asText();
    String root = "/api/v1/tenants/" + tenant + "/classes";
    String student = mutate("POST", "/api/v1/tenants/" + tenant + "/subjects", owner, null, null,
        Map.of("nickname", "Student", "ageBand", "AGE_7_12")).get("id").asText();
    String createKey = UUID.randomUUID().toString(), addKey = UUID.randomUUID().toString(), renameKey = UUID.randomUUID().toString();
    String transferKey = UUID.randomUUID().toString(), removeKey = UUID.randomUUID().toString(), archiveKey = UUID.randomUUID().toString();
    var created = mutate("POST", root, owner, createKey, null, Map.of("name", "Class A"));
    String a = created.get("id").asText();
    String b = mutate("POST", root, owner, UUID.randomUUID().toString(), null, Map.of("name", "Class B")).get("id").asText();
    var added = mutate("POST", root + "/" + a + "/students", owner, addKey, 0, Map.of("subjectId", student));
    var renamed = mutate("PATCH", root + "/" + a, owner, renameKey, 1, Map.of("name", "Class A1"));
    var transferred = mutate("POST", root + "/" + a + "/students/" + student + "/transfer", owner, transferKey, 2,
        Map.of("targetClassId", b, "targetVersion", 0));
    var removed = mutate("DELETE", root + "/" + b + "/students/" + student, owner, removeKey, 1, null);
    var archived = mutate("POST", root + "/" + a + "/archive", owner, archiveKey, 3, null);
    var descriptors = List.of(
        Map.of("operation", "CREATE", "name", "Class A"),
        Map.of("operation", "ADD", "classId", a, "version", 0, "subjectId", student),
        Map.of("operation", "RENAME", "classId", a, "version", 1, "name", "Class A1"),
        Map.of("operation", "TRANSFER", "classId", a, "version", 2, "subjectId", student, "targetClassId", b, "targetVersion", 0),
        Map.of("operation", "REMOVE", "classId", b, "version", 1, "subjectId", student),
        Map.of("operation", "ARCHIVE", "classId", a, "version", 3));
    var keys = List.of(createKey, addKey, renameKey, transferKey, removeKey, archiveKey);
    var originals = List.of(created, added, renamed, transferred.get("source"), removed, archived);
    for (int i = 0; i < descriptors.size(); i++) {
      var result = query(root, owner, keys.get(i), descriptors.get(i), 200);
      assertThat(result.get("committed").get(0)).isEqualTo(originals.get(i));
      assertThat(result.get("current").get(0)).isEqualTo(i == 4 ? removed : archived);
      if (i == 3) {
        assertThat(result.get("committed").get(1)).isEqualTo(transferred.get("target"));
        assertThat(result.get("current").get(1)).isEqualTo(removed);
      }
    }
    assertThat(mutate("POST", root + "/" + a + "/students/" + student + "/transfer", owner, transferKey, 2,
        Map.of("targetClassId", b, "targetVersion", 0))).isEqualTo(transferred);
    query(root, owner, createKey, Map.of("operation", "CREATE", "name", "Different"), 409);
    query(root, owner, transferKey, Map.of("operation", "TRANSFER", "classId", a, "version", 2,
        "subjectId", student, "targetClassId", b, "targetVersion", 1), 409);
    query(root, owner, createKey, Map.of("operation", "CREATE", "name", "Class A", "version", 0), 400);
    query(root, owner, UUID.randomUUID().toString(), descriptors.get(0), 404);
    query(root, "stranger", createKey, descriptors.get(0), 403);
    for (String role : List.of("ORG_ADMIN", "TEACHER", "AUDITOR", "CHILD")) {
      String member = owner + role;
      db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,?,?)",
          tenant, member, ActorKeys.key(member), role, role.equals("CHILD") ? student : null);
      query(root, member, createKey, descriptors.get(0), role.equals("ORG_ADMIN") ? 404 : 403);
    }
    mvc.perform(post(root + "/operation-results/" + createKey + "/query").contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(descriptors.get(0)))).andExpect(status().isUnauthorized());
    db.update("UPDATE idempotency_requests SET expires_at=1 WHERE scope_id=?", tenant);
    query(root, owner, createKey, descriptors.get(0), 200);
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?", tenant, ActorKeys.key(owner));
    query(root, owner, createKey, descriptors.get(0), 403);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM organization_class_students WHERE tenant_id=?", Long.class, tenant)).isZero();
    assertThat(db.queryForObject("SELECT version FROM organization_classes WHERE tenant_id=? AND id=?", Long.class, tenant, a)).isEqualTo(4);
  }
}
