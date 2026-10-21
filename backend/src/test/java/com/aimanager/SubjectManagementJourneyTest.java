package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
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
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** 真实 MVC、数据库事务、权限及原结果恢复；外部身份由明确夹具替代。 */
@SpringBootTest(properties = {"spring.datasource.url=jdbc:h2:mem:subject-management;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class SubjectManagementJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  private static final String CREATE = "{\"operation\":\"CREATE\",\"nickname\":\"小星\",\"ageBand\":\"AGE_7_12\"}";
  private record Scope(String tenant, String owner) {
    String root() { return "/api/v1/tenants/" + tenant + "/subjects"; }
  }
  private RequestPostProcessor actor(String id, boolean mfa) {
    return jwt().jwt(t -> t.subject(id).claim("email", id + "@example.test").claim("email_verified", true)
        .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", mfa ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  private Scope fixture() throws Exception {
    String owner = UUID.randomUUID().toString();
    var result = mvc.perform(post("/api/v1/tenants").with(actor(owner, true)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"档案验证\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse();
    return new Scope(json.readTree(result.getContentAsString()).get("id").asText(), owner);
  }
  private JsonNode change(Scope s, String body, String key) throws Exception {
    return json.readTree(mvc.perform(post(s.root() + "/changes").with(actor(s.owner(), true))
        .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
        .andReturn().getResponse().getContentAsString());
  }
  private String edit(String id, int version) throws Exception {
    return json.writeValueAsString(Map.of("operation", "UPDATE", "subjectId", id, "version", version,
        "nickname", "星星", "ageBand", "AGE_13_17"));
  }
  @Test void completeLifecycleKeepsHistorySeparateAndArchivesOutOfActiveLists() throws Exception {
    var s = fixture(); String key = UUID.randomUUID().toString();
    String id = change(s, CREATE, key).get("id").asText();
    assertThat(change(s, CREATE, key).get("id").asText()).isEqualTo(id);
    change(s, edit(id, 0), UUID.randomUUID().toString());
    change(s, json.writeValueAsString(Map.of("operation", "ARCHIVE", "subjectId", id, "version", 1)), UUID.randomUUID().toString());
    db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=?", s.tenant());
    for (int i = 0; i < 2; i++) {
      mvc.perform(post(s.root() + "/operation-results/" + key + "/query").with(actor(s.owner(), false))
          .contentType(MediaType.APPLICATION_JSON).content(CREATE)).andExpect(status().isOk())
          .andExpect(jsonPath("$.committed.nickname").value("小星"))
          .andExpect(jsonPath("$.committed.version").value(0))
          .andExpect(jsonPath("$.current.nickname").value("星星"))
          .andExpect(jsonPath("$.current.state").value("ARCHIVED"))
          .andExpect(jsonPath("$.current.version").value(2));
    }
    mvc.perform(get(s.root() + "/management").with(actor(s.owner(), false))).andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(0));
    mvc.perform(get(s.root() + "/management?includeArchived=true").with(actor(s.owner(), false))).andExpect(status().isOk()).andExpect(jsonPath("$.items[0].state").value("ARCHIVED"));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_subject_owners WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(3);
    assertThat(db.queryForObject("SELECT MAX(expires_at) FROM idempotency_requests WHERE scope_id=?", Long.class, s.tenant())).isZero();
  }
  @Test void originalActorFingerprintAndCurrentRoleAreRequired() throws Exception {
    var s = fixture(); String key = UUID.randomUUID().toString(); change(s, CREATE, key);
    String path = s.root() + "/operation-results/" + key + "/query";
    mvc.perform(post(path).with(actor(s.owner(), true)).contentType(MediaType.APPLICATION_JSON).content(CREATE.replace("小星", "别名")))
        .andExpect(status().isConflict());
    String other = UUID.randomUUID().toString();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')", s.tenant(), other, ActorKeys.key(other));
    mvc.perform(post(path).with(actor(other, true)).contentType(MediaType.APPLICATION_JSON).content(CREATE)).andExpect(status().isNotFound());
    db.update("UPDATE tenant_members SET role='AUDITOR' WHERE tenant_id=? AND actor_key=?", s.tenant(), ActorKeys.key(s.owner()));
    mvc.perform(post(path).with(actor(s.owner(), true)).contentType(MediaType.APPLICATION_JSON).content(CREATE)).andExpect(status().isForbidden());
    mvc.perform(get(s.root() + "/management").with(actor(s.owner(), true))).andExpect(status().isForbidden());
  }
  @Test void familyRoutineCreateUsesCurrentAdultButArchiveVersionAndForeignTargetsRemainProtected() throws Exception {
    var s = fixture();
    var created=mvc.perform(post(s.root() + "/changes").with(actor(s.owner(), false)).header("Idempotency-Key", UUID.randomUUID())
        .contentType(MediaType.APPLICATION_JSON).content(CREATE)).andExpect(status().isOk()).andReturn();
    String id=json.readTree(created.getResponse().getContentAsString()).get("id").asText();
    mvc.perform(post(s.root()+"/changes").with(actor(s.owner(),false)).header("Idempotency-Key",UUID.randomUUID())
        .contentType(MediaType.APPLICATION_JSON).content("{\"operation\":\"ARCHIVE\",\"subjectId\":\""+id+"\",\"version\":0}"))
        .andExpect(status().isUnauthorized());
    mvc.perform(post(s.root() + "/changes").with(actor(s.owner(), true)).header("Idempotency-Key", UUID.randomUUID())
        .contentType(MediaType.APPLICATION_JSON).content(edit(id, 1))).andExpect(status().isPreconditionFailed());
    var other = fixture();
    mvc.perform(post(other.root() + "/changes").with(actor(other.owner(), true)).header("Idempotency-Key", UUID.randomUUID())
        .contentType(MediaType.APPLICATION_JSON).content(edit(id, 0))).andExpect(status().isForbidden());
    assertThat(db.queryForObject("SELECT version FROM subjects WHERE tenant_id=?", Long.class, s.tenant())).isZero();
  }
  @Test void erasedJournalCannotBeQueriedOrRecreated() throws Exception {
    var s = fixture(); String key = UUID.randomUUID().toString(); change(s, CREATE, key);
    // Match the shared erasure tombstone; this is a fixture, not an erasure workflow test.
    db.update("UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL,actor_id='',operation='',request_hash=?,expires_at=0 WHERE scope_id=?", "0".repeat(64), s.tenant());
    for (String path : List.of("/changes", "/operation-results/" + key + "/query")) {
      mvc.perform(post(s.root() + path).with(actor(s.owner(), true)).header("Idempotency-Key", key)
          .contentType(MediaType.APPLICATION_JSON).content(CREATE)).andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
    }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(1);
  }
  @Test void invalidInputsAndMissingResultsDoNotCreateRows() throws Exception {
    var s = fixture();
    for (String body : List.of(CREATE.replace("小星", " "), CREATE.replace("AGE_7_12", "UNKNOWN"),
        "{\"operation\":\"ARCHIVE\",\"subjectId\":\"bad\",\"version\":0}",
        "{\"operation\":\"CREATE\",\"subjectId\":\"bad\",\"nickname\":\"孩子\",\"ageBand\":\"UNDER_7\"}")) {
      mvc.perform(post(s.root() + "/changes").with(actor(s.owner(), true)).header("Idempotency-Key", UUID.randomUUID())
          .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isBadRequest());
    }
    mvc.perform(post(s.root() + "/operation-results/" + UUID.randomUUID() + "/query").with(actor(s.owner(), true))
        .contentType(MediaType.APPLICATION_JSON).content(CREATE)).andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("SUBJECT_RESULT_UNAVAILABLE"));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=?", Integer.class, s.tenant())).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=?", Integer.class, s.tenant())).isZero();
  }
}
