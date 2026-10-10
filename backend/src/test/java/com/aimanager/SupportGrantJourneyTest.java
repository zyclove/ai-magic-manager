package com.aimanager;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.fasterxml.jackson.databind.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "spring.datasource.url=${SUPPORT_TEST_DATABASE_URL:jdbc:h2:mem:support-grants;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${SUPPORT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${SUPPORT_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false",
      "manager.report-jobs.worker.enabled=false"
    })
@AutoConfigureMockMvc(
    print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
class SupportGrantJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @MockitoSpyBean ObjectMapper json;
  @MockitoSpyBean java.time.Clock clock;
  @MockitoSpyBean com.aimanager.audit.AuditService audit;

  @org.springframework.test.context.bean.override.mockito.MockitoBean
  org.springframework.security.oauth2.jwt.JwtDecoder decoder;

  @org.springframework.boot.test.web.server.LocalServerPort int port;
  String owner, recipient, tenant, subject, device, registration, root, code, pairingId;

  RequestPostProcessor actor(String who) {
    return actor(who, true, true);
  }

  RequestPostProcessor actor(String who, boolean strong, boolean adult) {
    return jwt()
        .jwt(
            j ->
                j.subject(who)
                    .issuedAt(Instant.now())
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", strong ? List.of("pwd", "otp") : List.of("pwd"))
                    .claim("name", "Support fixture"))
        .authorities(new SimpleGrantedAuthority(adult ? "SCOPE_tenant:create" : "SCOPE_openid"));
  }

  JsonNode body(ResultActions action) throws Exception {
    return json.readTree(action.andReturn().getResponse().getContentAsByteArray());
  }

  @BeforeEach
  void setup() throws Exception {
    owner = "grant-owner-" + UUID.randomUUID();
    recipient = "grant-recipient-" + UUID.randomUUID();
    tenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            "{\"name\":\"Support grant"
                                + " fixture\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated()))
            .path("id")
            .asText();
    subject = UUID.randomUUID().toString();
    device = UUID.randomUUID().toString();
    registration = UUID.randomUUID().toString();
    long now = System.currentTimeMillis();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'CHILD_PRIVATE_TEXT','AGE_7_12',?)",
        tenant,
        subject,
        now);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at,last_heartbeat_at,agent_version)"
            + " VALUES(?,?,?,?,'CHILD_DEVICE_NAME','ANDROID','14','ACTIVE','SECRET_KEY','SECRET_THUMBPRINT',?,?,'1.2.3')",
        tenant,
        device,
        subject,
        registration,
        now,
        now);
    db.update(
        "INSERT INTO"
            + " device_capabilities(tenant_id,device_id,capability_key,reported_supported,grant_status,checked_at)"
            + " VALUES(?,?,'usage.report',true,'GRANTED',?)",
        tenant,
        device,
        now);
    root = "/api/v1/tenants/" + tenant + "/devices/" + device + "/support-grants";
    newPairing();
  }

  void newPairing() throws Exception {
    var pair =
        body(
            mvc.perform(
                    post("/api/v1/support/pairing-requests")
                        .with(actor(recipient))
                        .header("Idempotency-Key", UUID.randomUUID().toString()))
                .andExpect(status().isCreated()));
    code = pair.path("code").asText();
    pairingId = pair.path("request").path("id").asText();
  }

  Map<String, Object> input(List<String> types) {
    return Map.of(
        "pairingCode",
        code,
        "recipientActorId",
        recipient,
        "registrationId",
        registration,
        "diagnosticTypes",
        types,
        "durationMinutes",
        60);
  }

  ResultActions create(String key, List<String> types) throws Exception {
    return mvc.perform(
        post(root)
            .with(actor(owner))
            .header("If-Match", "\"0\"")
            .header("Idempotency-Key", key)
            .contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsBytes(input(types))));
  }

  ResultActions read(String id, String who) throws Exception {
    return mvc.perform(
        get("/api/v1/support/grants/" + id + "/diagnostic-preview").with(actor(who)));
  }

  String grant(List<String> types) throws Exception {
    return body(create("grant-create", types).andExpect(status().isCreated())).path("id").asText();
  }

  @Test
  void explicitTypeScopedGrantConsumesPairingOnceWithoutGrantingTenantMembership()
      throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    var first =
        body(
            read(id, recipient)
                .andExpect(status().isOk())
                .andExpect(header().string("Cache-Control", "no-store")));
    assertThat(first.path("grantId").asText()).isEqualTo(id);
    assertThat(first.path("versions").path("agent").path("value").asText()).isEqualTo("1.2.3");
    assertThat(first.path("capabilities").isNull()).isTrue();
    assertThat(first.path("configurations").isNull()).isTrue();
    assertThat(first.toString())
        .doesNotContain(
            "CHILD_PRIVATE_TEXT", "CHILD_DEVICE_NAME", "SECRET_KEY", "SECRET_THUMBPRINT", code);
    assertThat(
            db.queryForObject(
                "SELECT state FROM support_pairing_requests WHERE id=?", String.class, pairingId))
        .isEqualTo("CONSUMED");
    create("another-key", List.of("DEVICE_STATUS")).andExpect(status().isNotFound());
    var replay =
        body(create("grant-create", List.of("DEVICE_STATUS")).andExpect(status().isCreated()));
    assertThat(replay.path("id").asText()).isEqualTo(id);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM tenant_members WHERE tenant_id=?", Integer.class, tenant))
        .isEqualTo(1);
    mvc.perform(get("/api/v1/tenants/" + tenant + "/devices").with(actor(recipient)))
        .andExpect(status().isForbidden());
    assertThat(
            db.queryForList(
                    "SELECT response_body FROM idempotency_requests WHERE actor_id=?", owner)
                .toString())
        .doesNotContain(code);
  }

  @Test
  void capabilitiesOnlyNeverIncludesVersionsOrConfigurationMetadata() throws Exception {
    String id = grant(List.of("CAPABILITIES"));
    var result = body(read(id, recipient).andExpect(status().isOk()));
    assertThat(result.path("device").isNull()).isTrue();
    assertThat(result.path("versions").isNull()).isTrue();
    assertThat(result.path("configurations").isNull()).isTrue();
    assertThat(result.path("capabilities").size()).isPositive();
  }

  @Test
  void unselectedCapabilitiesAreNotReadOrValidated() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    for (int i = 0; i < 64; i++)
      db.update(
          "INSERT INTO"
              + " device_capabilities(tenant_id,device_id,capability_key,reported_supported,grant_status,checked_at)"
              + " VALUES(?,?,?,false,'NOT_REQUESTED',1)",
          tenant,
          device,
          "unknown." + i);
    read(id, recipient).andExpect(status().isOk());
    mvc.perform(
            get("/api/v1/tenants/" + tenant + "/devices/" + device + "/diagnostic-preview")
                .with(actor(owner)))
        .andExpect(status().isPayloadTooLarge());
  }

  @Test
  void wrongRecipientWeakAuthenticationAndChildEligibilityAreDenied() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    read(id, owner).andExpect(status().isForbidden());
    for (boolean[] state : List.of(new boolean[] {false, true}, new boolean[] {true, false}))
      mvc.perform(
              get("/api/v1/support/grants/" + id + "/diagnostic-preview")
                  .with(actor(recipient, state[0], state[1])))
          .andExpect(status().is(state[0] ? 403 : 401));
    mvc.perform(get("/api/v1/support/grants").with(actor(owner)))
        .andExpect(jsonPath("$.items").isEmpty());
    mvc.perform(get("/api/v1/support/grants").with(actor(recipient)))
        .andExpect(jsonPath("$.items.length()").value(1));
  }

  @Test
  void revokeRequiresVersionAndOldCreateReplayDoesNotRestoreAccess() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    String route = "/api/v1/tenants/" + tenant + "/support-grants/" + id + "/revoke";
    mvc.perform(
            post(route)
                .with(actor(owner))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", "bad-version"))
        .andExpect(status().isPreconditionFailed());
    for (int i = 0; i < 2; i++)
      mvc.perform(
              post(route)
                  .with(actor(owner))
                  .header("If-Match", "\"0\"")
                  .header("Idempotency-Key", "revoke"))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.state").value("REVOKED"));
    read(id, recipient).andExpect(status().isForbidden());
    create("grant-create", List.of("DEVICE_STATUS"))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.state").value("REVOKED"));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='SUPPORT_GRANT_REVOKED'",
                Integer.class,
                tenant))
        .isEqualTo(1);
  }

  @Test
  void expirationDoesNotExtendThroughRetry() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    long expired = System.currentTimeMillis() - 1;
    db.update("UPDATE support_grants SET expires_at=? WHERE id=?", expired, id);
    read(id, recipient).andExpect(status().isForbidden());
    create("grant-create", List.of("DEVICE_STATUS"))
        .andExpect(jsonPath("$.state").value("EXPIRED"))
        .andExpect(jsonPath("$.expiresAt").value(expired));
  }

  @Test
  void registrationChangeDeviceRevocationAndArchivedSubjectInvalidateReads() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    db.update(
        "UPDATE devices SET registration_id=? WHERE tenant_id=? AND id=?",
        UUID.randomUUID().toString(),
        tenant,
        device);
    read(id, recipient).andExpect(status().isForbidden());
    db.update(
        "UPDATE devices SET registration_id=?,state='REVOKED' WHERE tenant_id=? AND id=?",
        registration,
        tenant,
        device);
    read(id, recipient).andExpect(status().isForbidden());
    db.update("UPDATE devices SET state='ACTIVE' WHERE tenant_id=? AND id=?", tenant, device);
    db.update(
        "UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?",
        System.currentTimeMillis(),
        tenant,
        subject);
    read(id, recipient).andExpect(status().isForbidden());
  }

  @Test
  void grantingMemberVersionChangesInvalidateExistingAuthority() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    db.update("UPDATE tenant_members SET version=version+1 WHERE tenant_id=?", tenant);
    read(id, recipient).andExpect(status().isForbidden());
  }

  @Test
  void recipientConfirmationDeviceVersionAndTypesMustMatchBeforeConsumingPairing()
      throws Exception {
    var wrong = new LinkedHashMap<String, Object>(input(List.of("DEVICE_STATUS")));
    wrong.put("recipientActorId", owner);
    mvc.perform(
            post(root)
                .with(actor(owner))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "wrong-recipient")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(wrong)))
        .andExpect(status().isConflict());
    create("wrong-types", List.of("RAW_LOGS")).andExpect(status().isBadRequest());
    mvc.perform(
            post(root)
                .with(actor(owner))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", "wrong-device")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(input(List.of("DEVICE_STATUS")))))
        .andExpect(status().isPreconditionFailed());
    assertThat(
            db.queryForObject(
                "SELECT state FROM support_pairing_requests WHERE id=?", String.class, pairingId))
        .isEqualTo("PENDING");
  }

  @Test
  void expiredOrRevokedGrantIsDeniedBeforeReadingOversizedCapabilities() throws Exception {
    String id = grant(List.of("CAPABILITIES"));
    for (int i = 0; i < 64; i++)
      db.update(
          "INSERT INTO"
              + " device_capabilities(tenant_id,device_id,capability_key,reported_supported,grant_status,checked_at)"
              + " VALUES(?,?,?,false,'NOT_REQUESTED',1)",
          tenant,
          device,
          "unknown." + i);
    db.update("UPDATE support_grants SET expires_at=1 WHERE id=?", id);
    read(id, recipient).andExpect(status().isForbidden());
    db.update(
        "UPDATE support_grants SET state='REVOKED',expires_at=? WHERE id=?",
        System.currentTimeMillis() + 60000,
        id);
    read(id, recipient).andExpect(status().isForbidden());
    noReadAudit();
  }

  @Test
  void validationMissingHeadersAndCurrentCustomerAuthorityDoNotConsumePairing() throws Exception {
    for (Object types :
        List.of(List.of(), List.of("DEVICE_STATUS", "DEVICE_STATUS"), List.of("RAW_LOGS"))) {
      var invalid = new LinkedHashMap<>(input(List.of("DEVICE_STATUS")));
      invalid.put("diagnosticTypes", types);
      submit(invalid, owner, "\"0\"", UUID.randomUUID().toString())
          .andExpect(status().isBadRequest());
    }
    for (int minutes : List.of(0, 4, 1441)) {
      var invalid = new LinkedHashMap<>(input(List.of("DEVICE_STATUS")));
      invalid.put("durationMinutes", minutes);
      submit(invalid, owner, "\"0\"", UUID.randomUUID().toString())
          .andExpect(status().isBadRequest());
    }
    submit(input(List.of("DEVICE_STATUS")), owner, null, "missing-version")
        .andExpect(status().is(428));
    submit(input(List.of("DEVICE_STATUS")), owner, "\"0\"", null)
        .andExpect(status().isBadRequest());
    submit(input(List.of("DEVICE_STATUS")), recipient, "\"0\"", "outsider")
        .andExpect(status().isForbidden());
    db.update("UPDATE tenant_members SET role='AUDITOR' WHERE tenant_id=?", tenant);
    create("auditor", List.of("DEVICE_STATUS")).andExpect(status().isForbidden());
    assertThat(
            db.queryForObject(
                "SELECT state FROM support_pairing_requests WHERE id=?", String.class, pairingId))
        .isEqualTo("PENDING");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM support_grants WHERE tenant_id=?", Integer.class, tenant))
        .isZero();
  }

  ResultActions submit(Map<String, Object> input, String who, String etag, String key)
      throws Exception {
    var request =
        post(root)
            .with(actor(who))
            .contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsBytes(input));
    if (etag != null) request.header("If-Match", etag);
    if (key != null) request.header("Idempotency-Key", key);
    return mvc.perform(request);
  }

  @RepeatedTest(3)
  void simultaneousSameKeyReplaysOneGrantAndDifferentKeysConsumeOnlyOnce() throws Exception {
    var threads = Executors.newFixedThreadPool(3);
    try {
      var start = new CountDownLatch(1);
      var pending = new ArrayList<Future<String>>();
      for (int i = 0; i < 3; i++)
        pending.add(
            threads.submit(
                () -> {
                  assertThat(start.await(5, TimeUnit.SECONDS)).isTrue();
                  return body(create("same-key", List.of("DEVICE_STATUS"))
                          .andExpect(status().isCreated()))
                      .path("id")
                      .asText();
                }));
      start.countDown();
      var ids = new HashSet<String>();
      for (var response : pending) ids.add(response.get(15, TimeUnit.SECONDS));
      assertThat(ids).hasSize(1);
      newPairing();
      var race = new CountDownLatch(1);
      var outcomes = new ArrayList<Future<Integer>>();
      for (int i = 0; i < 3; i++) {
        String key = "different-key-" + i;
        outcomes.add(
            threads.submit(
                () -> {
                  assertThat(race.await(5, TimeUnit.SECONDS)).isTrue();
                  return create(key, List.of("CAPABILITIES")).andReturn().getResponse().getStatus();
                }));
      }
      race.countDown();
      var statuses = new ArrayList<Integer>();
      for (var response : outcomes) statuses.add(response.get(15, TimeUnit.SECONDS));
      assertThat(statuses).containsExactlyInAnyOrder(201, 404, 404);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM support_grants WHERE tenant_id=?", Integer.class, tenant))
          .isEqualTo(2);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM support_pairing_events WHERE request_id=? AND"
                      + " action='CONSUMED'",
                  Integer.class,
                  pairingId))
          .isEqualTo(1);
    } finally {
      threads.shutdownNow();
      threads.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  @Test
  void exactRecipientAndRevokedCustomerCannotReuseExistingAuthorization() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    read(id, recipient.toUpperCase(Locale.ROOT)).andExpect(status().isForbidden());
    mvc.perform(get("/api/v1/support/grants/" + id).with(actor(owner)))
        .andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP,version=version+1 WHERE"
            + " tenant_id=?",
        tenant);
    read(id, recipient).andExpect(status().isForbidden());
    create("grant-create", List.of("DEVICE_STATUS")).andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET revoked_at=NULL,version=version+1 WHERE tenant_id=?", tenant);
    read(id, recipient).andExpect(status().isForbidden());
    noReadAudit();
  }

  @Test
  void serializationFailuresAndSizeLimitNeverCommitReadSuccess() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    doAnswer(
            call -> {
              if (isPreview(call.getArgument(0)))
                throw new com.fasterxml.jackson.core.JsonProcessingException(
                    "PRIVATE_SERIALIZER_DETAIL") {};
              return call.callRealMethod();
            })
        .when(json)
        .writeValueAsBytes(any());
    var failed =
        read(id, recipient)
            .andExpect(status().isBadGateway())
            .andReturn()
            .getResponse()
            .getContentAsString();
    assertThat(failed).doesNotContain("PRIVATE_SERIALIZER_DETAIL");
    doAnswer(
            call ->
                isPreview(call.getArgument(0)) ? new byte[512 * 1024 + 1] : call.callRealMethod())
        .when(json)
        .writeValueAsBytes(any());
    read(id, recipient).andExpect(status().isPayloadTooLarge());
    noReadAudit();
  }

  @Test
  void expirationDuringSerializationDiscardsBytesAndReadAudit() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    long expires =
        db.queryForObject("SELECT expires_at FROM support_grants WHERE id=?", Long.class, id);
    doAnswer(
            call -> {
              Object bytes = call.callRealMethod();
              if (isPreview(call.getArgument(0))) doReturn(expires).when(clock).millis();
              return bytes;
            })
        .when(json)
        .writeValueAsBytes(any());
    read(id, recipient).andExpect(status().isForbidden());
    noReadAudit();
  }

  @Test
  void concurrentRevocationWaitsForAuthorizedSerializationThenBlocksNextRead() throws Exception {
    String id = grant(List.of("DEVICE_STATUS"));
    var copied = new CountDownLatch(1);
    var release = new CountDownLatch(1);
    var revoking = new CountDownLatch(1);
    doAnswer(
            call -> {
              Object bytes = call.callRealMethod();
              if (isPreview(call.getArgument(0))) {
                copied.countDown();
                assertThat(release.await(5, TimeUnit.SECONDS)).isTrue();
              }
              return bytes;
            })
        .when(json)
        .writeValueAsBytes(any());
    var threads = Executors.newFixedThreadPool(2);
    try {
      var reading = threads.submit(() -> read(id, recipient).andExpect(status().isOk()));
      assertThat(copied.await(5, TimeUnit.SECONDS)).isTrue();
      var revoke =
          threads.submit(
              () -> {
                revoking.countDown();
                return mvc.perform(
                        post("/api/v1/tenants/" + tenant + "/support-grants/" + id + "/revoke")
                            .with(actor(owner))
                            .header("If-Match", "\"0\"")
                            .header("Idempotency-Key", "concurrent-revoke"))
                    .andExpect(status().isOk());
              });
      assertThat(revoking.await(2, TimeUnit.SECONDS)).isTrue();
      assertThatThrownBy(() -> revoke.get(150, TimeUnit.MILLISECONDS))
          .isInstanceOf(TimeoutException.class);
      release.countDown();
      reading.get(8, TimeUnit.SECONDS);
      revoke.get(8, TimeUnit.SECONDS);
      read(id, recipient).andExpect(status().isForbidden());
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                      + " action='SUPPORT_DIAGNOSTIC_PREVIEWED'",
                  Integer.class,
                  tenant))
          .isEqualTo(1);
    } finally {
      release.countDown();
      threads.shutdownNow();
      threads.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  boolean isPreview(Object value) {
    return value
        .getClass()
        .getName()
        .equals("com.aimanager.support.internal.SupportDiagnosticReader$Preview");
  }

  void noReadAudit() {
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='SUPPORT_DIAGNOSTIC_PREVIEWED'",
                Integer.class,
                tenant))
        .isZero();
  }

  @Test
  @org.junit.jupiter.api.condition.EnabledIfSystemProperty(
      named = "device.dart.command",
      matches = ".+")
  void productionDartSupportClientCompletesRealHttpGrantLifecycle() throws Exception {
    configuration();
    String customerToken = UUID.randomUUID().toString(),
        recipientToken = UUID.randomUUID().toString(),
        weakToken = UUID.randomUUID().toString(),
        childToken = UUID.randomUUID().toString(),
        outsiderToken = UUID.randomUUID().toString();
    when(decoder.decode(org.mockito.ArgumentMatchers.anyString()))
        .thenAnswer(
            call -> {
              String token = call.getArgument(0);
              if (!Set.of(customerToken, recipientToken, weakToken, childToken, outsiderToken)
                  .contains(token))
                throw new org.springframework.security.oauth2.jwt.BadJwtException(
                    "Unknown support fixture");
              return org.springframework.security.oauth2.jwt.Jwt.withTokenValue(token)
                  .header("alg", "fixture")
                  .subject(
                      token.equals(customerToken)
                          ? owner
                          : token.equals(outsiderToken) ? "support-http-outsider" : recipient)
                  .issuedAt(Instant.now())
                  .expiresAt(Instant.now().plusSeconds(300))
                  .claim("auth_time", Instant.now().getEpochSecond())
                  .claim("amr", token.equals(weakToken) ? List.of("pwd") : List.of("pwd", "otp"))
                  .claim("scope", token.equals(childToken) ? "openid" : "openid tenant:create")
                  .claim("name", "Support HTTP fixture")
                  .build();
            });
    var directory =
        java.nio.file.Files.createTempDirectory(
            java.nio.file.Files.createDirectories(java.nio.file.Path.of(".local").toAbsolutePath()),
            "support-grant-http-");
    var fixture = directory.resolve("fixture.json");
    var output = directory.resolve("journey.log");
    var values = new LinkedHashMap<String, Object>();
    values.put("testOnly", true);
    values.put("apiRoot", "http://127.0.0.1:" + port + "/api/v1");
    values.put("tenantId", tenant);
    values.put("deviceId", device);
    values.put("registrationId", registration);
    values.put("owner", owner);
    values.put("recipient", recipient);
    values.put("ownerToken", customerToken);
    values.put("recipientToken", recipientToken);
    values.put("weakToken", weakToken);
    values.put("childToken", childToken);
    values.put("outsiderToken", outsiderToken);
    try {
      json.writeValue(fixture.toFile(), values);
      var process =
          new ProcessBuilder(
                  System.getProperty("device.dart.command"),
                  "run",
                  "tool/verify_support_http.dart",
                  fixture.toString())
              .directory(
                  java.nio.file.Path.of(
                          System.getProperty("diagnostic.guardian.package", "../apps/guardian"))
                      .toAbsolutePath()
                      .toFile())
              .redirectErrorStream(true)
              .redirectOutput(output.toFile())
              .start();
      if (!process.waitFor(45, TimeUnit.SECONDS)) {
        process.destroyForcibly();
        process.waitFor(5, TimeUnit.SECONDS);
        throw new AssertionError("Support HTTP client deadline exceeded");
      }
      assertThat(process.exitValue()).as("Support HTTP diagnostics: %s", output).isZero();
      assertThat(java.nio.file.Files.readString(output))
          .contains("PASS support HTTP grant-lifecycle");
      for (String action :
          List.of("SUPPORT_GRANT_CREATED", "SUPPORT_GRANT_REVOKED", "SUPPORT_DIAGNOSTIC_PREVIEWED"))
        assertThat(
                db.queryForObject(
                    "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action=?",
                    Integer.class,
                    tenant,
                    action))
            .isEqualTo(1);
    } finally {
      java.nio.file.Files.deleteIfExists(fixture);
    }
  }

  @Test
  void deviceCapacityRollbackPreservesPairingAndExpiredGrantsReleaseCapacity() throws Exception {
    String prototype = grant(List.of("DEVICE_STATUS"));
    for (int i = 0; i < 19; i++) seedGrant(prototype, device, registration);
    newPairing();
    create("at-capacity", List.of("DEVICE_STATUS"))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("SUPPORT_GRANT_CAPACITY_REACHED"));
    assertThat(
            db.queryForObject(
                "SELECT state FROM support_pairing_requests WHERE id=?", String.class, pairingId))
        .isEqualTo("PENDING");
    db.update("UPDATE support_grants SET expires_at=1 WHERE tenant_id=?", tenant);
    create("at-capacity", List.of("DEVICE_STATUS")).andExpect(status().isCreated());
  }

  @Test
  void tenantCapacityIsEnforcedEvenWhenSelectedDeviceHasRoom() throws Exception {
    String prototype = grant(List.of("DEVICE_STATUS"));
    String another = UUID.randomUUID().toString(), nextRegistration = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'Other fixture','ANDROID','14','ACTIVE','fixture','fixture',1)",
        tenant,
        another,
        subject,
        nextRegistration);
    for (int i = 0; i < 199; i++) seedGrant(prototype, another, nextRegistration);
    newPairing();
    create("tenant-at-capacity", List.of("DEVICE_STATUS"))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("SUPPORT_GRANT_CAPACITY_REACHED"));
    assertThat(
            db.queryForObject(
                "SELECT state FROM support_pairing_requests WHERE id=?", String.class, pairingId))
        .isEqualTo("PENDING");
  }

  void seedGrant(String prototype, String targetDevice, String targetRegistration) {
    String pair = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " support_pairing_requests(id,recipient_actor_id,recipient_key,code_hash,state,created_at,expires_at,updated_at)"
            + " SELECT"
            + " ?,recipient_actor_id,recipient_key,?,'CONSUMED',created_at,expires_at,updated_at"
            + " FROM support_pairing_requests WHERE id=?",
        pair,
        pair.replace("-", "").repeat(2),
        pairingId);
    db.update(
        "INSERT INTO"
            + " support_grants(id,tenant_id,device_id,subject_id,registration_id,creator_actor_id,creator_key,creator_member_version,recipient_actor_id,recipient_key,pairing_id,type_mask,state,created_at,expires_at,updated_at)"
            + " SELECT"
            + " ?,tenant_id,?,subject_id,?,creator_actor_id,creator_key,creator_member_version,recipient_actor_id,recipient_key,?,type_mask,state,created_at,expires_at,updated_at"
            + " FROM support_grants WHERE id=?",
        UUID.randomUUID().toString(),
        targetDevice,
        targetRegistration,
        pair,
        prototype);
  }

  @Test
  void auditFailureRollsBackGrantPairingConsumptionAndIdempotencyTogether() throws Exception {
    com.aimanager.audit.AuditService target =
        org.springframework.test.util.AopTestUtils.getUltimateTargetObject(audit);
    doThrow(
            new com.aimanager.shared.DomainException(
                org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                "FIXTURE_AUDIT_UNAVAILABLE"))
        .when(target)
        .record(
            org.mockito.ArgumentMatchers.eq(tenant),
            org.mockito.ArgumentMatchers.eq(owner),
            org.mockito.ArgumentMatchers.eq("SUPPORT_GRANT_CREATED"),
            any());
    create("atomic-create", List.of("DEVICE_STATUS")).andExpect(status().isServiceUnavailable());
    assertThat(
            db.queryForObject(
                "SELECT state FROM support_pairing_requests WHERE id=?", String.class, pairingId))
        .isEqualTo("PENDING");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM support_pairing_events WHERE request_id=? AND"
                    + " action='CONSUMED'",
                Integer.class,
                pairingId))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM support_grants WHERE tenant_id=?", Integer.class, tenant))
        .isZero();
    reset(target);
    create("atomic-create", List.of("DEVICE_STATUS")).andExpect(status().isCreated());
  }

  @RepeatedTest(3)
  void differentCustomersCannotConsumeOnePairingAcrossTenants() throws Exception {
    String anotherOwner = "another-owner-" + UUID.randomUUID();
    String anotherTenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(anotherOwner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            "{\"name\":\"Another"
                                + " customer\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated()))
            .path("id")
            .asText();
    String anotherSubject = UUID.randomUUID().toString(),
        anotherDevice = UUID.randomUUID().toString(),
        anotherRegistration = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'Private other"
            + " child','AGE_7_12',1)",
        anotherTenant,
        anotherSubject);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'Other fixture','ANDROID','14','ACTIVE','fixture','fixture',1)",
        anotherTenant,
        anotherDevice,
        anotherSubject,
        anotherRegistration);
    var secondInput = new LinkedHashMap<>(input(List.of("DEVICE_STATUS")));
    secondInput.put("registrationId", anotherRegistration);
    var start = new CountDownLatch(1);
    var threads = Executors.newFixedThreadPool(2);
    try {
      var first =
          threads.submit(
              () -> {
                assertThat(start.await(5, TimeUnit.SECONDS)).isTrue();
                return create("cross-tenant", List.of("DEVICE_STATUS")).andReturn().getResponse();
              });
      var second =
          threads.submit(
              () -> {
                assertThat(start.await(5, TimeUnit.SECONDS)).isTrue();
                return mvc.perform(
                        post("/api/v1/tenants/"
                                + anotherTenant
                                + "/devices/"
                                + anotherDevice
                                + "/support-grants")
                            .with(actor(anotherOwner))
                            .header("If-Match", "\"0\"")
                            .header("Idempotency-Key", "cross-tenant")
                            .contentType(MediaType.APPLICATION_JSON)
                            .content(json.writeValueAsBytes(secondInput)))
                    .andReturn()
                    .getResponse();
              });
      start.countDown();
      var firstResponse = first.get(15, TimeUnit.SECONDS);
      var secondResponse = second.get(15, TimeUnit.SECONDS);
      assertThat(List.of(firstResponse.getStatus(), secondResponse.getStatus()))
          .containsExactlyInAnyOrder(201, 404);
      String id =
          json.readTree(
                  (firstResponse.getStatus() == 201 ? firstResponse : secondResponse)
                      .getContentAsByteArray())
              .path("id")
              .asText();
      String losingTenant = firstResponse.getStatus() == 201 ? anotherTenant : tenant;
      String losingOwner = firstResponse.getStatus() == 201 ? anotherOwner : owner;
      mvc.perform(
              get("/api/v1/tenants/" + losingTenant + "/support-grants/" + id)
                  .with(actor(losingOwner)))
          .andExpect(status().isForbidden());
      read(id, recipient).andExpect(status().isOk());
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM support_grants WHERE pairing_id=?",
                  Integer.class,
                  pairingId))
          .isEqualTo(1);
    } finally {
      start.countDown();
      threads.shutdownNow();
      threads.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  @RepeatedTest(3)
  void pairingCancellationAndGrantConsumptionAreAtomic() throws Exception {
    var start = new CountDownLatch(1);
    var threads = Executors.newFixedThreadPool(2);
    try {
      var creating =
          threads.submit(
              () -> {
                assertThat(start.await(5, TimeUnit.SECONDS)).isTrue();
                return create("cancel-race", List.of("DEVICE_STATUS"))
                    .andReturn()
                    .getResponse()
                    .getStatus();
              });
      var cancelling =
          threads.submit(
              () -> {
                assertThat(start.await(5, TimeUnit.SECONDS)).isTrue();
                return mvc.perform(
                        post("/api/v1/support/pairing-requests/" + pairingId + "/cancel")
                            .with(actor(recipient))
                            .header("If-Match", "\"0\"")
                            .header("Idempotency-Key", "cancel-race"))
                    .andReturn()
                    .getResponse()
                    .getStatus();
              });
      start.countDown();
      int created = creating.get(15, TimeUnit.SECONDS),
          cancelled = cancelling.get(15, TimeUnit.SECONDS);
      if (created == 201) {
        assertThat(cancelled).isEqualTo(412);
        assertThat(
                db.queryForObject(
                    "SELECT state FROM support_pairing_requests WHERE id=?",
                    String.class,
                    pairingId))
            .isEqualTo("CONSUMED");
      } else {
        assertThat(created).isEqualTo(404);
        assertThat(cancelled).isEqualTo(200);
        assertThat(
                db.queryForObject(
                    "SELECT COUNT(*) FROM support_grants WHERE pairing_id=?",
                    Integer.class,
                    pairingId))
            .isZero();
      }
    } finally {
      start.countDown();
      threads.shutdownNow();
      threads.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  void configuration() {
    long now = System.currentTimeMillis();
    db.update(
        "INSERT INTO configuration_device_heads(tenant_id,registration_id,device_id,next_cursor)"
            + " VALUES(?,?,?,1)",
        tenant,
        registration,
        device);
    String policy = UUID.randomUUID().toString(),
        version = UUID.randomUUID().toString(),
        review = UUID.randomUUID().toString(),
        publication = UUID.randomUUID().toString(),
        delivery = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'CHILD_POLICY_NAME','CONFIGURATION','[]',?,?)",
        tenant,
        policy,
        now,
        now);
    db.update(
        "INSERT INTO"
            + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at)"
            + " VALUES(?,?,?,0,?,'SECRET_SNAPSHOT',?,?)",
        tenant,
        review,
        policy,
        "a".repeat(64),
        now,
        now + 60000);
    db.update(
        "INSERT INTO"
            + " policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at)"
            + " VALUES(?,?,?,0,1,?,?,'CONFIGURE_ONLY','SECRET_SNAPSHOT',?)",
        tenant,
        version,
        policy,
        review,
        "a".repeat(64),
        now);
    db.update(
        "INSERT INTO policy_publications(tenant_id,id,version_id,state,created_at)"
            + " VALUES(?,?,?,'CONFIGURATION_RECORDED',?)",
        tenant,
        publication,
        version,
        now);
    db.update(
        "INSERT INTO"
            + " configuration_deliveries(tenant_id,id,publication_id,version_id,policy_id,registration_id,device_id,source_sequence,device_cursor,action,document_json,issued_at,delivery_expires_at,state,compact_jws,envelope_hash,stored_reported_at)"
            + " VALUES(?,?,?,?,?,?,?,1,1,'UPSERT_CONFIGURATION','https://private.example/SECRET?child=CHILD_PRIVATE_TEXT',?,?,'DEVICE_REPORTED_STORED','SECRET_JWS',?,?)",
        tenant,
        delivery,
        publication,
        version,
        policy,
        registration,
        device,
        now - 1000,
        now + 60000,
        "b".repeat(64),
        now);
    db.update(
        "INSERT INTO configuration_streams(tenant_id,registration_id,policy_id,delivery_id)"
            + " VALUES(?,?,?,?)",
        tenant,
        registration,
        policy,
        delivery);
  }

  @Test
  void configurationOnlyIncludesHashesWithoutPrivateBodiesOrOtherTypes() throws Exception {
    configuration();
    String id = grant(List.of("CONFIGURATION_METADATA"));
    var result = body(read(id, recipient).andExpect(status().isOk()));
    assertThat(result.path("device").isNull()).isTrue();
    assertThat(result.path("versions").isNull()).isTrue();
    assertThat(result.path("capabilities").isNull()).isTrue();
    assertThat(result.path("configurations").size()).isEqualTo(1);
    assertThat(result.path("configurations").get(0).path("policyHash").asText())
        .isEqualTo("a".repeat(64));
    assertThat(result.path("configurations").get(0).path("configurationHash").asText())
        .isEqualTo("b".repeat(64));
    assertThat(result.toString())
        .doesNotContain("SECRET", "CHILD_PRIVATE_TEXT", "CHILD_POLICY_NAME", "private.example");
  }
}
