package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.HexFormat;
import java.util.List;
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

/** Actual subject HTTP wiring; the external issuer is the only substituted boundary. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:subject-idempotency-attribution;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class SubjectIdempotencyAttributionJourneyTest {
  private static final String INPUT = "{\"nickname\":\"待清理档案\",\"ageBand\":\"AGE_7_12\"}";
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;

  @Test
  void createdProfileOwnsItsCachedResultAndRetryDoesNotCreateAnotherProfile() throws Exception {
    var owner = "attribution-" + UUID.randomUUID();
    var tenant = family(owner);
    var key = UUID.randomUUID().toString();
    var created = create(tenant, owner, key, INPUT);

    assertThat(db.queryForObject(
            "SELECT response_state FROM idempotency_requests WHERE scope_id=?", String.class, tenant))
        .isEqualTo("SCOPED");
    // Derive this independently of ResponseOwnership.subjectKey: it must name the generated ID.
    String expectedOwner = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
        .digest(("idempotency-subject-v1\n" + tenant + "\n" + created.get("id").asText())
            .getBytes(StandardCharsets.UTF_8)));
    assertThat(db.queryForList(
            "SELECT subject_key FROM idempotency_subject_owners WHERE tenant_id=?", String.class, tenant))
        .containsExactly(expectedOwner);
    assertThat(create(tenant, owner, key, INPUT)).isEqualTo(created);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=?", Integer.class, tenant))
        .isEqualTo(1);
  }

  @Test
  void erasedExpiredResultRejectsSameAndChangedRequestsWithoutRecreatingProfile() throws Exception {
    var owner = "erased-http-" + UUID.randomUUID();
    var tenant = family(owner);
    var key = UUID.randomUUID().toString();
    create(tenant, owner, key, INPUT);
    // Model the committed marker produced by the separately exercised internal erasure worker.
    db.update("UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL,"
        + "actor_id='',operation='',request_hash=?,expires_at=0 WHERE scope_id=?", "0".repeat(64), tenant);
    db.update("DELETE FROM subjects WHERE tenant_id=?", tenant);

    for (String body : List.of(INPUT, "{\"nickname\":\"改名重放\",\"ageBand\":\"AGE_13_17\"}")) {
      var response = mvc.perform(post("/api/v1/tenants/{tenant}/subjects", tenant)
              .with(actor(owner)).header("Idempotency-Key", key)
              .contentType(MediaType.APPLICATION_JSON).content(body))
          .andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"))
          .andReturn().getResponse().getContentAsString();
      assertThat(response).doesNotContain("待清理档案", "改名重放", "AGE_7_12", "AGE_13_17");
    }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=?", Integer.class, tenant))
        .isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=?", Integer.class, tenant))
        .isEqualTo(1);
  }

  @Test
  void revokedCallerIsDeniedBeforeReadingAnActiveOrErasedCachedResult() throws Exception {
    var owner = "revoked-http-" + UUID.randomUUID();
    var tenant = family(owner);
    var key = UUID.randomUUID().toString();
    create(tenant, owner, key, INPUT);
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_id=?", tenant, owner);
    for (boolean erased : List.of(false, true)) {
      if (erased) db.update("UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL,"
          + "actor_id='',operation='',request_hash=? WHERE scope_id=?", "0".repeat(64), tenant);
      mvc.perform(post("/api/v1/tenants/{tenant}/subjects", tenant).with(actor(owner))
              .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(INPUT))
          .andExpect(status().isForbidden()).andExpect(jsonPath("$.errorCode").value("SCOPE_DENIED"));
    }
  }

  private RequestPostProcessor actor(String id) {
    return jwt().jwt(token -> token.subject(id).claim("email", id + "@example.test")
            .claim("email_verified", true).claim("auth_time", Instant.now().getEpochSecond())
            .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private String family(String owner) throws Exception {
    var response = mvc.perform(post("/api/v1/tenants").with(actor(owner))
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"接口验证家庭\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse();
    return json.readTree(response.getContentAsString()).get("id").asText();
  }

  private JsonNode create(String tenant, String owner, String key, String body) throws Exception {
    var response = mvc.perform(post("/api/v1/tenants/{tenant}/subjects", tenant).with(actor(owner))
            .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isCreated()).andReturn().getResponse();
    return json.readTree(response.getContentAsString());
  }
}
