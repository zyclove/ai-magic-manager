package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/**
 * Real opaque DeviceCredentials authentication, policy/subject/device services and request SQL
 * transactions. Adult MFA uses an external issuer double, and registration/credentials are seed
 * fixtures; these tests make no native enrollment claim. ERASED rows model the committed erasure
 * marker, rather than exercising the erasure worker.
 */
@SpringBootTest(
    properties = {
      "manager.approval.expiry-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false",
      "manager.quota.materialization-job.enabled=false",
      "manager.notifications.retention-job.enabled=false",
      "manager.erasure-previews.cleanup.enabled=false",
      "manager.emm.enrollment-cleanup.enabled=false",
      "manager.exports.worker.enabled=false",
      "manager.report-jobs.worker.enabled=false",
      "manager.diagnostic-packages.worker.enabled=false",
      "manager.messaging.kafka.enabled=false",
      "manager.messaging.artemis.enabled=false"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
@org.springframework.context.annotation.Import(com.aimanager.support.ControlledIdempotencyTimeConfiguration.class)
class DeviceApprovalIdempotencyAttributionJourneyTest {
  private static final String ROUTE = "/api/v1/device-api/access-submissions";
  private static final String CREATE = "access.device.request";
  private static final String CANCEL = "access.device.cancel";
  private static final String H2_URL =
      "jdbc:h2:mem:p0deviceapproval_"
          + UUID.randomUUID().toString().replace("-", "")
          + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE";

  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper mapper;
  @Autowired DeviceCredentials credentials;
  @MockitoBean Clock clock;
  @MockitoBean JwtDecoder decoder;

  @DynamicPropertySource
  static void isolatedDatabase(DynamicPropertyRegistry registry) {
    String external = System.getenv("P0_DEVICE_APPROVAL_TEST_DATABASE_URL");
    if (external == null || external.isBlank()) {
      registry.add("spring.datasource.url", () -> H2_URL);
      registry.add("spring.datasource.username", () -> "sa");
      registry.add("spring.datasource.password", () -> "");
      return;
    }
    // Validate before DataSource/Flyway can connect or initialize a schema.
    URI target;
    try {
      if (!external.startsWith("jdbc:mysql://")) throw new IllegalArgumentException();
      target = URI.create(external.substring("jdbc:".length()));
    } catch (IllegalArgumentException malformed) {
      throw new IllegalStateException("P0 device approval database must be an isolated local MySQL schema");
    }
    if (!"mysql".equals(target.getScheme())
        || !"127.0.0.1".equals(target.getHost())
        || target.getPort() != 3308
        || target.getUserInfo() != null
        || target.getFragment() != null
        || target.getRawPath() == null
        || !target.getRawPath().matches("/notification_it_[0-9a-f]{32}")) {
      throw new IllegalStateException("P0 device approval database must use 127.0.0.1:3308/notification_it_<32hex>");
    }
    String username = System.getenv("P0_DEVICE_APPROVAL_TEST_DATABASE_USERNAME");
    if (username == null || username.isBlank()) {
      throw new IllegalStateException("P0 device approval MySQL username is required");
    }
    String password = System.getenv("P0_DEVICE_APPROVAL_TEST_DATABASE_PASSWORD");
    registry.add("spring.datasource.url", () -> external);
    registry.add("spring.datasource.username", () -> username);
    registry.add("spring.datasource.password", () -> password == null ? "" : password);
  }

  @BeforeEach
  void deviceBearerIsNotAnAdultJwt() {
    // This journey compares complete business/ownership snapshots. Keep its
    // fixture time fixed so a later trusted-time observation is not mistaken
    // for a repeated mutation. Production database-clock checks stay intact.
    Instant instant=Instant.now();
    when(clock.instant()).thenReturn(instant);
    when(clock.millis()).thenReturn(instant.toEpochMilli());
    when(clock.getZone()).thenReturn(ZoneOffset.UTC);
    when(decoder.decode(anyString()))
        .thenThrow(new BadJwtException("Device credential is not an external issuer JWT"));
  }

  @Test
  void deviceWithoutChildMemberCreatesAndCancelsWithTheChildAsTheOnlyResponseOwner()
      throws Exception {
    var s = scope();
    assertThat(db.queryForObject(
            "SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND role='CHILD'",
            Integer.class, s.tenant()))
        .isZero();

    String id = submit(s, "create").get("id").asText();
    assertScoped(s, CREATE, "create");
    cancel(s, s.token(), id, "cancel", "\"0\"")
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("CANCELLED"));
    assertScoped(s, CANCEL, "cancel");
    assertThat(db.queryForObject(
            "SELECT requester_kind FROM access_requests WHERE tenant_id=? AND id=?",
            String.class, s.tenant(), id))
        .isEqualTo("DEVICE");
    assertThat(db.queryForObject(
            "SELECT COUNT(*) FROM access_requests WHERE tenant_id=?", Integer.class, s.tenant()))
        .isEqualTo(1);
  }

  @Test
  void exactCreateRetryPreservesTheOriginalOwnerAndDoesNotCreateAnotherRequest()
      throws Exception {
    var s = scope();
    String id = submit(s, "stable-create").get("id").asText();
    assertScoped(s, CREATE, "stable-create");
    var before = snapshot(s);

    createRequest(s, s.token(), "stable-create", input(s))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.id").value(id))
        .andExpect(header().string("ETag", "\"0\""));

    assertThat(snapshot(s)).isEqualTo(before);
    assertScoped(s, CREATE, "stable-create");
  }

  @Test
  void exactCancelRetryPreservesTheOriginalOwnerAndDoesNotRepeatTheTransition()
      throws Exception {
    var s = scope();
    String id = submit(s, "create").get("id").asText();
    cancel(s, s.token(), id, "stable-cancel", "\"0\"").andExpect(status().isOk());
    assertScoped(s, CANCEL, "stable-cancel");
    var before = snapshot(s);

    cancel(s, s.token(), id, "stable-cancel", "\"0\"")
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.id").value(id))
        .andExpect(jsonPath("$.state").value("CANCELLED"))
        .andExpect(header().string("ETag", "\"1\""));

    assertThat(snapshot(s)).isEqualTo(before);
    assertScoped(s, CANCEL, "stable-cancel");
  }

  @Test
  void activatedCredentialRotationReplaysBothKeysWithTheirOriginalChildOwnership()
      throws Exception {
    var s = scope();
    String id = submit(s, "create").get("id").asText();
    cancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isOk());
    assertScoped(s, CREATE, "create");
    assertScoped(s, CANCEL, "cancel");
    var next = credentials.rotate(
        new DeviceContext(s.tenant(), s.device(), s.registration(), s.credential()));
    mvc.perform(post("/api/v1/device-api/credentials/activate")
            .header("Authorization", "Bearer " + next.credential()))
        .andExpect(status().isNoContent());
    var before = snapshot(s);

    createRequest(s, next.credential(), "create", input(s))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.id").value(id))
        .andExpect(jsonPath("$.state").value("CANCELLED"));
    cancel(s, next.credential(), id, "cancel", "\"0\"")
        .andExpect(status().isOk())
        .andExpect(header().string("ETag", "\"1\""));
    createRequest(s, s.token(), "create", input(s)).andExpect(status().isUnauthorized());

    assertThat(snapshot(s)).isEqualTo(before);
    assertScoped(s, CREATE, "create");
    assertScoped(s, CANCEL, "cancel");
  }

  @Test
  void expiredCreateRecoveryReadsTheCurrentFactWithoutRenewingKeyOrRewritingOwner()
      throws Exception {
    var s = scope();
    String id = submit(s, "original").get("id").asText();
    cancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isOk());
    assertScoped(s, CREATE, "original");
    expire(s, CREATE, "original");
    var before = snapshot(s);

    recoverCreate(s, s.token(), "original", input(s))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.id").value(id))
        .andExpect(jsonPath("$.state").value("CANCELLED"))
        .andExpect(header().string("ETag", "\"1\""))
        .andExpect(header().string("Cache-Control", "no-store"));
    createRequest(s, s.token(), "original", input(s))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_EXPIRED"));

    assertThat(snapshot(s)).isEqualTo(before);
    assertScoped(s, CREATE, "original");
  }

  @Test
  void expiredCancelRecoveryUsesOriginalVersionWithoutRenewingKeyOrRewritingOwner()
      throws Exception {
    var s = scope();
    String id = submit(s, "create").get("id").asText();
    cancel(s, s.token(), id, "original", "\"0\"").andExpect(status().isOk());
    assertScoped(s, CANCEL, "original");
    expire(s, CANCEL, "original");
    var before = snapshot(s);

    recoverCancel(s, s.token(), id, "original", "\"0\"")
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.id").value(id))
        .andExpect(jsonPath("$.state").value("CANCELLED"))
        .andExpect(header().string("ETag", "\"1\""));
    cancel(s, s.token(), id, "original", "\"0\"")
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_EXPIRED"));

    assertThat(snapshot(s)).isEqualTo(before);
    assertScoped(s, CANCEL, "original");
  }

  @Test
  void missingRecoveryNeverCreatesAJournalOwnerRequestOrCancellation() throws Exception {
    var s = scope();
    var initial = snapshot(s);
    recoverCreate(s, s.token(), "never-created", input(s))
        .andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("ACCESS_RECOVERY_UNAVAILABLE"));
    assertThat(snapshot(s)).isEqualTo(initial);

    String id = submit(s, "create").get("id").asText();
    var pending = snapshot(s);
    recoverCancel(s, s.token(), id, "never-cancelled", "\"0\"")
        .andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("ACCESS_RECOVERY_UNAVAILABLE"));
    assertThat(snapshot(s)).isEqualTo(pending);
    assertScoped(s, CREATE, "create");
  }

  @Test
  void expiredRecoveryRejectsChangedOriginalInputWithoutChangingOwnersOrFacts()
      throws Exception {
    var s = scope();
    String id = submit(s, "create").get("id").asText();
    cancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isOk());
    assertScoped(s, CREATE, "create");
    assertScoped(s, CANCEL, "cancel");
    expire(s, CREATE, "create");
    expire(s, CANCEL, "cancel");
    var before = snapshot(s);
    var changed = new HashMap<>(input(s));
    changed.put("reason", "different original reason");

    recoverCreate(s, s.token(), "create", changed)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
    recoverCancel(s, s.token(), id, "cancel", "\"1\"")
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));

    assertThat(snapshot(s)).isEqualTo(before);
  }

  @Test
  void erasedCreateKeyReturnsGoneForReplayAndRecoveryEvenAfterExpiryOrChangedInput()
      throws Exception {
    var s = scope();
    submit(s, "erased-create");
    erase(s, CREATE, "erased-create");
    var before = snapshot(s);
    var changed = new HashMap<>(input(s));
    changed.put("reason", "a new reason cannot replace erased ownership");

    for (var body : List.of(input(s), changed)) {
      createRequest(s, s.token(), "erased-create", body)
          .andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
      recoverCreate(s, s.token(), "erased-create", body)
          .andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
    }
    assertThat(snapshot(s)).isEqualTo(before);
    assertErased(s, CREATE, "erased-create");
  }

  @Test
  void erasedCancelKeyReturnsGoneForReplayAndRecoveryWithoutRepeatingCancellation()
      throws Exception {
    var s = scope();
    String id = submit(s, "create").get("id").asText();
    cancel(s, s.token(), id, "erased-cancel", "\"0\"").andExpect(status().isOk());
    erase(s, CANCEL, "erased-cancel");
    var before = snapshot(s);

    for (String tag : List.of("\"0\"", "\"1\"")) {
      cancel(s, s.token(), id, "erased-cancel", tag)
          .andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
      recoverCancel(s, s.token(), id, "erased-cancel", tag)
          .andExpect(status().isGone())
          .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
    }
    assertThat(snapshot(s)).isEqualTo(before);
    assertErased(s, CANCEL, "erased-cancel");
  }

  @Test
  void expiredCredentialIsRejectedBeforeErasedCreateOrCancelCacheIsConsulted()
      throws Exception {
    var s = scope();
    String id = submit(s, "create").get("id").asText();
    cancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isOk());
    erase(s, CREATE, "create");
    erase(s, CANCEL, "cancel");
    db.update("UPDATE device_credentials SET expires_at=1 WHERE id=?", s.credential());
    var before = snapshot(s);

    createRequest(s, s.token(), "create", input(s)).andExpect(status().isUnauthorized());
    recoverCreate(s, s.token(), "create", input(s)).andExpect(status().isUnauthorized());
    cancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isUnauthorized());
    recoverCancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isUnauthorized());

    assertThat(snapshot(s)).isEqualTo(before);
  }

  @Test
  void inactiveSubjectAndDeviceAreRejectedBeforeErasedCacheIsConsulted() throws Exception {
    var s = scope();
    String id = submit(s, "create").get("id").asText();
    cancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isOk());
    erase(s, CREATE, "create");
    erase(s, CANCEL, "cancel");
    db.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?",
        clock.millis(), s.tenant(), s.subject());
    var archived = snapshot(s);
    assertAllDeviceOperationsDenied(s, id);
    assertThat(snapshot(s)).isEqualTo(archived);

    db.update("UPDATE subjects SET archived_at=NULL WHERE tenant_id=? AND id=?",
        s.tenant(), s.subject());
    db.update("UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?",
        s.tenant(), s.device());
    var revoked = snapshot(s);
    assertAllDeviceOperationsDenied(s, id);
    assertThat(snapshot(s)).isEqualTo(revoked);
  }

  @Test
  void reassignedDeviceCannotConsultAnErasedCancellationForItsPreviousSubject()
      throws Exception {
    var s = scope();
    String id = submit(s, "create").get("id").asText();
    cancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isOk());
    erase(s, CANCEL, "cancel");
    String otherSubject = create(
        "/api/v1/tenants/" + s.tenant() + "/subjects", s.owner(),
        Map.of("nickname", "另一个孩子", "ageBand", "AGE_7_12"));
    db.update("UPDATE devices SET subject_id=? WHERE tenant_id=? AND id=?",
        otherSubject, s.tenant(), s.device());
    var before = snapshot(s);

    cancel(s, s.token(), id, "cancel", "\"0\"")
        .andExpect(status().isForbidden())
        .andExpect(jsonPath("$.errorCode").value("SCOPE_DENIED"));
    recoverCancel(s, s.token(), id, "cancel", "\"0\"")
        .andExpect(status().isForbidden())
        .andExpect(jsonPath("$.errorCode").value("SCOPE_DENIED"));

    assertThat(snapshot(s)).isEqualTo(before);
    assertErased(s, CANCEL, "cancel");
    assertScoped(s, CREATE, "create");
  }

  private void assertAllDeviceOperationsDenied(Scope s, String id) throws Exception {
    createRequest(s, s.token(), "create", input(s)).andExpect(status().isForbidden());
    recoverCreate(s, s.token(), "create", input(s)).andExpect(status().isForbidden());
    cancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isForbidden());
    recoverCancel(s, s.token(), id, "cancel", "\"0\"").andExpect(status().isForbidden());
  }

  private void assertScoped(Scope s, String operation, String key) throws Exception {
    var journal = journal(s, operation, key);
    assertThat(journal.get("response_state")).as("response ownership classification")
        .isEqualTo("SCOPED");
    assertThat(journal.get("actor_id")).isEqualTo("device:" + s.registration());
    assertThat(journal.get("response_body")).isNotNull();
    var owners = owners(s, operation, key);
    assertThat(owners).containsExactly(new Owner(s.tenant(), subjectDigest(s.tenant(), s.subject())));
    for (String identity : List.of(
        s.owner(), "device:" + s.registration(), s.device(), s.registration(), s.credential())) {
      assertThat(owners).doesNotContain(new Owner(s.tenant(), subjectDigest(s.tenant(), identity)));
    }
  }

  private void assertErased(Scope s, String operation, String key) throws Exception {
    var journal = journal(s, operation, key);
    assertThat(journal.get("response_state")).isEqualTo("ERASED");
    assertThat(journal.get("response_body")).isNull();
    assertThat(journal.get("actor_id")).isEqualTo("");
    assertThat(journal.get("operation")).isEqualTo("");
    assertThat(journal.get("request_hash")).isEqualTo("0".repeat(64));
    assertThat(journal.get("scope_id")).isEqualTo(s.tenant());
    assertThat(journal.get("actor_key")).isEqualTo(sha256("device:" + s.registration()));
    assertThat(journal.get("operation_key")).isEqualTo(sha256(operation));
    assertThat(journal.get("key_hash")).isEqualTo(sha256(key));
    assertThat(((Number) journal.get("expires_at")).longValue()).isEqualTo(1);
    assertThat(owners(s, operation, key))
        .containsExactly(new Owner(s.tenant(), subjectDigest(s.tenant(), s.subject())));
  }

  private Map<String, Object> journal(Scope s, String operation, String key) throws Exception {
    return db.queryForMap(
        "SELECT * FROM idempotency_requests WHERE scope_id=? AND actor_key=?"
            + " AND operation_key=? AND key_hash=?",
        s.tenant(), sha256("device:" + s.registration()), sha256(operation), sha256(key));
  }

  private List<Owner> owners(Scope s, String operation, String key) throws Exception {
    return db.query(
        "SELECT tenant_id,subject_key FROM idempotency_subject_owners WHERE scope_id=? AND actor_key=?"
            + " AND operation_key=? AND key_hash=? ORDER BY tenant_id,subject_key",
        (row, index) -> new Owner(row.getString("tenant_id"), row.getString("subject_key")),
        s.tenant(), sha256("device:" + s.registration()), sha256(operation), sha256(key));
  }

  private void expire(Scope s, String operation, String key) throws Exception {
    assertThat(db.update(
            "UPDATE idempotency_requests SET expires_at=1 WHERE scope_id=? AND actor_key=?"
                + " AND operation_key=? AND key_hash=?",
            s.tenant(), sha256("device:" + s.registration()), sha256(operation), sha256(key)))
        .isEqualTo(1);
  }

  private void erase(Scope s, String operation, String key) throws Exception {
    assertScoped(s, operation, key);
    // Match the processor's retained-owner tombstone; expiry is forced only to test old keys.
    assertThat(db.update(
            "UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL,actor_id='',"
                + "operation='',request_hash=?,expires_at=1 WHERE scope_id=? AND actor_key=?"
                + " AND operation_key=? AND key_hash=? AND response_state='SCOPED'",
            "0".repeat(64), s.tenant(), sha256("device:" + s.registration()), sha256(operation), sha256(key)))
        .isEqualTo(1);
    assertErased(s, operation, key);
  }

  private Map<String, List<Map<String, Object>>> snapshot(Scope s) {
    var result = new LinkedHashMap<String, List<Map<String, Object>>>();
    result.put("requests", db.queryForList(
        "SELECT * FROM access_requests WHERE tenant_id=? ORDER BY id", s.tenant()));
    result.put("slots", db.queryForList(
        "SELECT * FROM access_request_slots WHERE tenant_id=? ORDER BY subject_id,registration_id,application_id",
        s.tenant()));
    result.put("decisions", db.queryForList(
        "SELECT * FROM access_request_decisions WHERE tenant_id=? ORDER BY request_id", s.tenant()));
    result.put("audit", db.queryForList(
        "SELECT * FROM audit_events WHERE tenant_id=? ORDER BY id", s.tenant()));
    result.put("notifications", db.queryForList(
        "SELECT * FROM notification_events WHERE tenant_id=? ORDER BY id", s.tenant()));
    result.put("journal", db.queryForList(
        "SELECT * FROM idempotency_requests WHERE scope_id=? ORDER BY id", s.tenant()));
    result.put("owners", db.queryForList(
        "SELECT * FROM idempotency_subject_owners WHERE scope_id=? ORDER BY id", s.tenant()));
    return result;
  }

  private String subjectDigest(String tenant, String subject) throws Exception {
    // Independent expectation; never call ResponseOwnership or production actor hashing helpers.
    return sha256("idempotency-subject-v1\n" + tenant + "\n" + subject);
  }

  private String sha256(String value) throws Exception {
    return HexFormat.of().formatHex(
        MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
  }

  private ResultActions createRequest(Scope s, String token, String key, Object body)
      throws Exception {
    return mvc.perform(post(ROUTE)
        .header("Authorization", "Bearer " + token)
        .header("Idempotency-Key", key)
        .contentType(MediaType.APPLICATION_JSON)
        .content(mapper.writeValueAsString(body)));
  }

  private JsonNode submit(Scope s, String key) throws Exception {
    var response = createRequest(s, s.token(), key, input(s))
        .andExpect(status().isCreated())
        .andExpect(header().string("ETag", "\"0\""))
        .andExpect(header().string("Cache-Control", "no-store"))
        .andReturn().getResponse();
    return mapper.readTree(response.getContentAsString());
  }

  private ResultActions cancel(Scope s, String token, String id, String key, String tag)
      throws Exception {
    return mvc.perform(post(ROUTE + "/" + id + "/cancel")
        .header("Authorization", "Bearer " + token)
        .header("Idempotency-Key", key)
        .header("If-Match", tag));
  }

  private ResultActions recoverCreate(Scope s, String token, String key, Object body)
      throws Exception {
    return mvc.perform(post(ROUTE + "/recovery")
        .header("Authorization", "Bearer " + token)
        .header("Idempotency-Key", key)
        .contentType(MediaType.APPLICATION_JSON)
        .content(mapper.writeValueAsString(body)));
  }

  private ResultActions recoverCancel(Scope s, String token, String id, String key, String tag)
      throws Exception {
    return mvc.perform(post(ROUTE + "/" + id + "/cancel-recovery")
        .header("Authorization", "Bearer " + token)
        .header("Idempotency-Key", key)
        .header("If-Match", tag));
  }

  private Map<String, Object> input(Scope s) {
    return Map.of(
        "policyId", s.policy(), "baseVersionId", s.version(), "applicationId", s.application(),
        "ruleIds", List.of("reading"), "requestedWindowSeconds", 600, "reason", "想继续阅读");
  }

  private RequestPostProcessor adult(String actor) {
    return jwt().jwt(token -> token.subject(actor)
            .claim("auth_time", clock.instant().getEpochSecond())
            .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private String create(String route, String actor, Object input) throws Exception {
    var response = mvc.perform(post(route).with(adult(actor))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(input)))
        .andExpect(status().isCreated()).andReturn().getResponse();
    return mapper.readTree(response.getContentAsString()).get("id").asText();
  }

  private Scope scope() throws Exception {
    String owner = "p0-device-approval-owner-" + UUID.randomUUID();
    String tenant = create("/api/v1/tenants", owner,
        Map.of("name", "设备审批归属家庭", "kind", "FAMILY", "timeZone", "UTC"));
    String prefix = "/api/v1/tenants/" + tenant;
    String subject = create(prefix + "/subjects", owner,
        Map.of("nickname", "孩子", "ageBand", "AGE_7_12"));
    String device = UUID.randomUUID().toString();
    String registration = UUID.randomUUID().toString();
    String credential = UUID.randomUUID().toString();
    String token = SecretMaterial.token();
    long now = clock.millis();
    db.update(
        "INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,"
            + "state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'设备','ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant, device, subject, registration, now);
    db.update(
        "INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active)"
            + " VALUES(?,?,?,true)", tenant, registration, device);
    db.update(
        "INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
            + " VALUES(?,?,?,?,?,true,?,?)",
        credential, tenant, device, registration, SecretMaterial.hash(token), now, now + 3600000);
    String application = create(prefix + "/applications", owner,
        Map.of("displayName", "阅读", "platform", "ANDROID", "packageName", "org.example.p0approval",
            "profile", "PRIMARY", "signingDigests", List.of("a".repeat(64))));
    String policy = create(prefix + "/policies", owner,
        Map.of("name", "阅读规则", "kind", "POLICY", "rules", List.of(
            Map.of("id", "reading", "kind", "APP_LAUNCH", "effect", "DENY",
                "applicationId", application, "required", true))));
    var partial = new Scope(owner, tenant, subject, device, registration, credential, token,
        application, policy, null);
    return new Scope(owner, tenant, subject, device, registration, credential, token,
        application, policy, publish(partial));
  }

  private String publish(Scope s) throws Exception {
    String route = "/api/v1/tenants/" + s.tenant() + "/policies/" + s.policy();
    var previewResponse = mvc.perform(post(route + "/previews").with(adult(s.owner()))
            .header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("deviceIds", List.of(s.device())))))
        .andExpect(status().isCreated()).andReturn().getResponse();
    var preview = mapper.readTree(previewResponse.getContentAsString());
    var response = mvc.perform(post(route + "/publications").with(adult(s.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", UUID.randomUUID())
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(
                Map.of("previewId", preview.get("id").asText(), "previewHash", preview.get("hash").asText(),
                    "mode", "CONFIGURE_ONLY"))))
        .andExpect(status().isCreated()).andReturn().getResponse();
    return mapper.readTree(response.getContentAsString()).get("versionId").asText();
  }

  private record Owner(String tenant, String subjectKey) {}

  private record Scope(
      String owner, String tenant, String subject, String device, String registration,
      String credential, String token, String application, String policy, String version) {}
}
