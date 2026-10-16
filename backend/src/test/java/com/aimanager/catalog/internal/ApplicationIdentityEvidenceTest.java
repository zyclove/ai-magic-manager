package com.aimanager.catalog.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.catalog.ApplicationIdentity;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
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
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.IllegalTransactionStateException;
import org.springframework.transaction.support.TransactionTemplate;

/** Real MVC and H2 transactions; no provider, device or deployment is contacted. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:application-identity-evidence;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password="
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ApplicationIdentityEvidenceTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @Autowired Clock clock;
  @MockitoBean JwtDecoder decoder;
  @Autowired ApplicationCatalog catalog;
  @Autowired PlatformTransactionManager transactions;

  @Test
  void creationRecordsServerIdentityTimeWithoutChangingPublicDeclaration() throws Exception {
    var f = fixture();
    long before = clock.millis();
    var application = create(f, UUID.randomUUID().toString());
    Long created = db.queryForObject(
        "SELECT created_at FROM application_definitions WHERE tenant_id=? AND id=?",
        Long.class, f.tenant(), application.get("id").asText());
    assertThat(created).as("identity time must be recorded by the server at declaration")
        .isNotNull().isBetween(before, clock.millis());
    assertThat(application.has("createdAt")).isFalse();
    assertThat(application.get("evidenceStatus").asText()).isEqualTo("ADMIN_DECLARED");
  }

  @Test
  void evidenceIdentityIsCanonicalImmutableAndContainsNoSharedInstallationClaim() throws Exception {
    var f = fixture();
    var app = create(f, UUID.randomUUID().toString());
    var identity = load(f, app);
    assertThat(identity.applicationId()).isEqualTo(app.get("id").asText());
    assertThat(identity.packageName()).isEqualTo("org.example.Reader");
    assertThat(identity.signingDigests()).containsExactly("a".repeat(64));
    assertThat(identity.revision()).isEqualTo(SecretMaterial.hash(json.writeValueAsString(
        List.of("ANDROID", "org.example.Reader", "PRIMARY", List.of("a".repeat(64))))));
    assertThat(identity.establishedAt().toEpochMilli()).isEqualTo(db.queryForObject(
        "SELECT created_at FROM application_definitions WHERE id=?", Long.class, app.get("id").asText()));
    assertThatThrownBy(() -> identity.signingDigests().add("b".repeat(64)))
        .isInstanceOf(UnsupportedOperationException.class);
    assertThat(identity.toString()).isEqualTo("ApplicationIdentity[REDACTED]");
    assertThat(json.valueToTree(identity).has("evidenceStatus")).isFalse();
  }

  @Test
  void idempotentReplayAndHistoricalRecoveryNeverResetIdentityTime() throws Exception {
    var f = fixture();
    String key = UUID.randomUUID().toString();
    var app = create(f, key);
    var identity = load(f, app);
    assertThat(create(f, key)).isEqualTo(app);
    assertThat(load(f, app)).isEqualTo(identity);
    db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=? AND operation='application.create'", f.tenant());
    mvc.perform(post(f.path() + "/creation-results/" + key + "/query").with(actor(f.actor()))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(definition())))
        .andExpect(status().isOk());
    assertThat(load(f, app)).isEqualTo(identity);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM application_definitions WHERE tenant_id=?", Integer.class, f.tenant())).isEqualTo(1);
  }

  @Test
  void signerOrderIsCanonicalAndSharedInstallationStatusIsNotIdentityEvidence() throws Exception {
    var f = fixture();
    var body = new java.util.HashMap<>(definition());
    body.put("signingDigests", List.of("b".repeat(64), "a".repeat(64)));
    var app = json.readTree(mvc.perform(post(f.path()).with(actor(f.actor()))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body)))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    var identity = load(f, app);
    assertThat(identity.signingDigests()).containsExactly("a".repeat(64), "b".repeat(64));
    var changed = (com.fasterxml.jackson.databind.node.ObjectNode) app.deepCopy();
    changed.put("displayName", "更改显示名称");
    changed.put("evidenceStatus", "INSTALLED_VERIFIED");
    changed.putArray("signingDigests").add("b".repeat(64)).add("a".repeat(64));
    db.update("UPDATE application_definitions SET definition_json=? WHERE id=?",
        json.writeValueAsString(changed), app.get("id").asText());
    assertThat(load(f, app)).isEqualTo(identity);
  }

  @Test
  void suppliedMetadataCannotOverrideServerTimestampOrDigest() throws Exception {
    var f = fixture();
    var body = new java.util.HashMap<>(definition());
    body.put("createdAt", 1);
    body.put("revision", "f".repeat(64));
    long before = clock.millis();
    mvc.perform(post(f.path()).with(actor(f.actor()))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body)))
        .andExpect(status().isBadRequest());
    assertThat(db.queryForObject("SELECT COUNT(*) FROM application_definitions WHERE tenant_id=?",
        Integer.class, f.tenant())).isZero();
    var identity = load(f, create(f, UUID.randomUUID().toString()));
    assertThat(identity.establishedAt().toEpochMilli()).isBetween(before, clock.millis());
    assertThat(identity.revision()).isNotEqualTo("f".repeat(64));
  }

  @ParameterizedTest
  @ValueSource(strings = {"NULL", "-1", "9223372036854775807"})
  void missingNegativeAndFutureIdentityTimeCannotBeUsedAsEvidence(String value) throws Exception {
    var f = fixture();
    var app = create(f, UUID.randomUUID().toString());
    db.update("UPDATE application_definitions SET created_at=? WHERE id=?",
        value.equals("NULL") ? null : Long.valueOf(value), app.get("id").asText());
    rejected(() -> load(f, app), "APPLICATION_IDENTITY_METADATA_UNAVAILABLE");
    assertThat(db.queryForObject("SELECT created_at FROM application_definitions WHERE id=?", Long.class,
        app.get("id").asText())).isEqualTo(value.equals("NULL") ? null : Long.valueOf(value));
  }

  @ParameterizedTest
  @ValueSource(strings = {"hash", "id", "packageName", "profile", "platform", "signer", "duplicate", "null", "malformed"})
  void inconsistentPersistedIdentityFailsClosedWithoutLeakingItsContents(String mutation) throws Exception {
    var f = fixture();
    var app = create(f, UUID.randomUUID().toString());
    String id = app.get("id").asText();
    var changed = app.deepCopy();
    var object = (com.fasterxml.jackson.databind.node.ObjectNode) changed;
    switch (mutation) {
      case "hash" -> db.update("UPDATE application_definitions SET identity_hash=? WHERE id=?", "b".repeat(64), id);
      case "id" -> object.put("id", UUID.randomUUID().toString());
      case "packageName" -> object.put("packageName", "org.example.Other");
      case "profile" -> object.put("profile", "WORK");
      case "platform" -> object.put("platform", "ANDROID_TV");
      case "signer" -> object.putArray("signingDigests").add("private-corrupt-certificate");
      case "duplicate" -> object.putArray("signingDigests").add("a".repeat(64)).add("a".repeat(64));
      case "null" -> object.putNull("signingDigests");
      case "malformed" -> { }
      default -> throw new AssertionError();
    }
    if (!mutation.equals("hash")) db.update("UPDATE application_definitions SET definition_json=? WHERE id=?",
        mutation.equals("malformed") ? "{private-corrupt-definition" : json.writeValueAsString(changed), id);
    rejected(() -> load(f, app), "APPLICATION_IDENTITY_METADATA_UNAVAILABLE");
  }

  @Test
  void declarationWithoutSigningTrustRemainsVisibleButCannotProvideEvidenceIdentity() throws Exception {
    var f = fixture();
    var body = new java.util.HashMap<>(definition());
    body.put("signingDigests", List.of());
    var app = json.readTree(mvc.perform(post(f.path()).with(actor(f.actor()))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body)))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    rejected(() -> load(f, app), "APPLICATION_SIGNING_IDENTITY_REQUIRED");
    assertThat(catalog.requireDeclared(f.tenant(), f.actor(), app.get("id").asText()).signingDigests()).isEmpty();
  }

  @ParameterizedTest
  @ValueSource(strings = {"OWNER", "ORG_ADMIN", "GUARDIAN"})
  void currentManagersCanReadEvidenceIdentity(String role) throws Exception {
    var f = fixture();
    var app = create(f, UUID.randomUUID().toString());
    db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
    assertThat(load(f, app).applicationId()).isEqualTo(app.get("id").asText());
  }

  @ParameterizedTest
  @ValueSource(strings = {"CHILD", "TEACHER", "AUDITOR", "REVOKED"})
  void currentMembershipMustAuthorizeEvidenceUse(String role) throws Exception {
    var f = fixture();
    var app = create(f, UUID.randomUUID().toString());
    if (role.equals("REVOKED")) db.update("UPDATE tenant_members SET revoked_at=? WHERE tenant_id=?",
        java.sql.Timestamp.from(clock.instant()), f.tenant());
    else db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
    assertThatThrownBy(() -> load(f, app)).isInstanceOfSatisfying(DomainException.class,
        error -> assertThat(error.status().value()).isEqualTo(403));
  }

  @Test
  void tenantScopeAndActiveTransactionAreRequired() throws Exception {
    var first = fixture();
    var other = fixture();
    var app = create(first, UUID.randomUUID().toString());
    assertThatThrownBy(() -> load(other, app)).isInstanceOfSatisfying(DomainException.class,
        error -> assertThat(error.status().value()).isEqualTo(403));
    assertThatThrownBy(() -> catalog.requireEvidenceIdentity(first.tenant(), first.actor(), app.get("id").asText()))
        .isInstanceOf(IllegalTransactionStateException.class);
  }

  private ApplicationIdentity load(Fixture f, JsonNode app) {
    return new TransactionTemplate(transactions).execute(tx ->
        catalog.requireEvidenceIdentity(f.tenant(), f.actor(), app.get("id").asText()));
  }

  private void rejected(org.assertj.core.api.ThrowableAssert.ThrowingCallable action, String code) {
    assertThatThrownBy(action).isInstanceOfSatisfying(DomainException.class,
        failure -> {
          assertThat(failure.errorCode()).isEqualTo(code);
          assertThat(failure.getMessage()).doesNotContain("private-corrupt");
          assertThat(failure.getCause()).isNull();
        });
  }

  private Fixture fixture() throws Exception {
    String actor = UUID.randomUUID().toString();
    var tenant = json.readTree(mvc.perform(post("/api/v1/tenants").with(actor(actor))
        .contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"应用身份验证\",\"kind\":\"ORGANIZATION\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    return new Fixture(actor, tenant.get("id").asText());
  }

  private JsonNode create(Fixture f, String key) throws Exception {
    return json.readTree(mvc.perform(post(f.path()).with(actor(f.actor()))
        .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(definition())))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
  }

  private Map<String, Object> definition() {
    return Map.of("displayName", "学习应用", "platform", "ANDROID", "profile", "PRIMARY",
        "packageName", "org.example.Reader", "signingDigests", List.of("a".repeat(64)));
  }

  private RequestPostProcessor actor(String id) {
    return jwt().jwt(token -> token.subject(id).claim("auth_time", Instant.now().getEpochSecond())
        .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private record Fixture(String actor, String tenant) {
    String path() { return "/api/v1/tenants/" + tenant + "/applications"; }
  }
}
