package com.aimanager.support.internal;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.support.DiagnosticPackageMaintenance;
import com.fasterxml.jackson.databind.*;
import com.nimbusds.jose.*;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.ApplicationContext;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.*;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "spring.datasource.url=${SUPPORT_TEST_DATABASE_URL:jdbc:h2:mem:diagnostic_packages;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${SUPPORT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${SUPPORT_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false",
      "manager.report-jobs.worker.enabled=false",
      "manager.diagnostic-packages.worker.enabled=false"
    })
@AutoConfigureMockMvc(
    print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
class DiagnosticPackageJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper json;
  @Autowired ApplicationContext context;
  @org.springframework.boot.test.web.server.LocalServerPort int port;

  @org.springframework.test.context.bean.override.mockito.MockitoBean
  org.springframework.security.oauth2.jwt.JwtDecoder decoder;

  @org.springframework.test.context.bean.override.mockito.MockitoSpyBean java.time.Clock clock;

  @org.springframework.test.context.bean.override.mockito.MockitoSpyBean
  DiagnosticPackageCipher cipher;

  @org.springframework.test.context.bean.override.mockito.MockitoSpyBean
  com.aimanager.audit.AuditService audit;

  static Path keyFile;

  @DynamicPropertySource
  static void config(DynamicPropertyRegistry properties) throws Exception {
    var dir = Path.of(".local");
    Files.createDirectories(dir);
    keyFile = Files.createTempFile(dir, "diagnostic-key-", ".json");
    byte[] bytes = new byte[32];
    new java.security.SecureRandom().nextBytes(bytes);
    var key =
        new OctetSequenceKey.Builder(bytes)
            .keyID("fixture")
            .algorithm(JWEAlgorithm.DIR)
            .keyUse(KeyUse.ENCRYPTION)
            .build();
    Files.writeString(keyFile, new JWKSet(key).toString(false));
    properties.add(
        "manager.diagnostic-packages.key-file", () -> keyFile.toAbsolutePath().toString());
  }

  @AfterAll
  static void cleanup() throws Exception {
    if (keyFile != null) Files.deleteIfExists(keyFile);
  }

  String tenant,
      owner,
      recipient,
      subject,
      device,
      registration,
      adminRoot,
      receivedRoot = "/api/v1/support/diagnostic-packages";

  RequestPostProcessor actor(String id) {
    return actor(id, true, true);
  }

  RequestPostProcessor actor(String id, boolean strong, boolean adult) {
    return jwt()
        .jwt(
            j ->
                j.subject(id)
                    .issuedAt(clock.instant())
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", strong ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority(adult ? "SCOPE_tenant:create" : "SCOPE_openid"));
  }

  JsonNode body(ResultActions result) throws Exception {
    return json.readTree(result.andReturn().getResponse().getContentAsByteArray());
  }

  @BeforeEach
  void fixture() throws Exception {
    owner = "package-owner-" + UUID.randomUUID();
    recipient = "package-recipient-" + UUID.randomUUID();
    tenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            "{\"name\":\"Package"
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
            + " VALUES(?,?,'PRIVATE_CHILD','AGE_7_12',?)",
        tenant,
        subject,
        now);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at,last_heartbeat_at,agent_version)"
            + " VALUES(?,?,?,?,'PRIVATE_DEVICE','ANDROID','14','ACTIVE','PRIVATE_KEY','PRIVATE_THUMBPRINT',?,?,'1.2.3')",
        tenant,
        device,
        subject,
        registration,
        now,
        now);
    adminRoot = "/api/v1/tenants/" + tenant + "/diagnostic-packages";
  }

  JsonNode adminCreate(String key) throws Exception {
    return body(
        mvc.perform(
                post("/api/v1/tenants/" + tenant + "/devices/" + device + "/diagnostic-packages")
                    .with(actor(owner))
                    .header("If-Match", "\"0\"")
                    .header("Idempotency-Key", key)
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(json.writeValueAsBytes(Map.of("registrationId", registration))))
            .andExpect(status().isAccepted())
            .andExpect(header().string("Cache-Control", "no-store")));
  }

  String grant() throws Exception {
    var pair =
        body(
            mvc.perform(
                    post("/api/v1/support/pairing-requests")
                        .with(actor(recipient))
                        .header("Idempotency-Key", UUID.randomUUID().toString()))
                .andExpect(status().isCreated()));
    return body(mvc.perform(
                post("/api/v1/tenants/" + tenant + "/devices/" + device + "/support-grants")
                    .with(actor(owner))
                    .header("If-Match", "\"0\"")
                    .header("Idempotency-Key", UUID.randomUUID().toString())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(
                        json.writeValueAsBytes(
                            Map.of(
                                "registrationId",
                                registration,
                                "pairingCode",
                                pair.path("code").asText(),
                                "recipientActorId",
                                recipient,
                                "diagnosticTypes",
                                List.of("DEVICE_STATUS"),
                                "durationMinutes",
                                60))))
            .andExpect(status().isCreated()))
        .path("id")
        .asText();
  }

  void run() {
    context.getBean(DiagnosticPackageMaintenance.class).runBatch(25);
  }

  @Test
  @org.junit.jupiter.api.condition.EnabledIfSystemProperty(
      named = "device.dart.command",
      matches = ".+")
  void productionDartClientCompletesPackageLifecycleOverRealHttp() throws Exception {
    String grantId = grant();
    String ownerToken = UUID.randomUUID().toString(),
        recipientToken = UUID.randomUUID().toString(),
        weakToken = UUID.randomUUID().toString(),
        childToken = UUID.randomUUID().toString(),
        outsiderToken = UUID.randomUUID().toString();
    org.mockito.Mockito.when(decoder.decode(org.mockito.ArgumentMatchers.anyString()))
        .thenAnswer(
            call -> {
              String token = call.getArgument(0);
              if (!Set.of(ownerToken, recipientToken, weakToken, childToken, outsiderToken)
                  .contains(token))
                throw new org.springframework.security.oauth2.jwt.BadJwtException(
                    "Unknown package fixture");
              return org.springframework.security.oauth2.jwt.Jwt.withTokenValue(token)
                  .header("alg", "fixture")
                  .subject(
                      token.equals(ownerToken)
                          ? owner
                          : token.equals(outsiderToken) ? "package-http-outsider" : recipient)
                  .issuedAt(Instant.now())
                  .expiresAt(Instant.now().plusSeconds(180))
                  .claim("auth_time", Instant.now().getEpochSecond())
                  .claim("amr", token.equals(weakToken) ? List.of("pwd") : List.of("pwd", "otp"))
                  .claim("scope", token.equals(childToken) ? "openid" : "openid tenant:create")
                  .build();
            });
    var directory =
        Files.createTempDirectory(
            Files.createDirectories(Path.of(".local").toAbsolutePath()), "package-http-");
    var fixture = directory.resolve("fixture.json");
    var output = directory.resolve("journey.log");
    var values = new LinkedHashMap<String, Object>();
    values.put("testOnly", true);
    values.put("apiRoot", "http://127.0.0.1:" + port + "/api/v1");
    values.put("tenantId", tenant);
    values.put("deviceId", device);
    values.put("registrationId", registration);
    values.put("grantId", grantId);
    values.put("owner", owner);
    values.put("recipient", recipient);
    values.put("ownerToken", ownerToken);
    values.put("recipientToken", recipientToken);
    values.put("weakToken", weakToken);
    values.put("childToken", childToken);
    values.put("outsiderToken", outsiderToken);
    Process process = null;
    try {
      json.writeValue(fixture.toFile(), values);
      process =
          new ProcessBuilder(
                  System.getProperty("device.dart.command"),
                  "run",
                  "tool/verify_diagnostic_package_http.dart",
                  fixture.toString())
              .directory(
                  Path.of(System.getProperty("diagnostic.guardian.package", "../apps/guardian"))
                      .toAbsolutePath()
                      .toFile())
              .redirectErrorStream(true)
              .redirectOutput(output.toFile())
              .start();
      long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(45);
      while (process.isAlive() && System.nanoTime() < deadline) {
        run();
        process.waitFor(100, java.util.concurrent.TimeUnit.MILLISECONDS);
      }
      assertFalse(process.isAlive(), "Package HTTP client deadline exceeded");
      assertEquals(0, process.exitValue(), "Package HTTP diagnostics: " + output);
      assertTrue(Files.readString(output).contains("PASS diagnostic package HTTP lifecycle"));
    } finally {
      if (process != null && process.isAlive()) {
        process.destroyForcibly();
        process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS);
      }
      Files.deleteIfExists(fixture);
    }
  }

  @Test
  void adminPackagePublishesOnlyCompleteEncryptedArtifactAndCancelsIdempotently() throws Exception {
    String key = UUID.randomUUID().toString();
    var created = adminCreate(key);
    String id = created.path("id").asText();
    assertEquals("QUEUED", created.path("state").asText());
    assertEquals(created.path("expiresAt"), adminCreate(key).path("expiresAt"));
    mvc.perform(get(adminRoot + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isConflict());
    run();
    var ready =
        body(mvc.perform(get(adminRoot + "/" + id).with(actor(owner))).andExpect(status().isOk()));
    assertEquals("READY", ready.path("state").asText());
    byte[] bytes =
        mvc.perform(get(adminRoot + "/" + id + "/content").with(actor(owner)))
            .andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(header().exists("Content-Disposition"))
            .andReturn()
            .getResponse()
            .getContentAsByteArray();
    var content = json.readTree(bytes);
    assertEquals(id, content.path("jobId").asText());
    assertEquals(
        "1.2.3", content.path("diagnostic").path("versions").path("agent").path("value").asText());
    assertFalse(new String(bytes, java.nio.charset.StandardCharsets.UTF_8).contains("PRIVATE_"));
    String artifact =
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id);
    assertNotNull(artifact);
    assertFalse(artifact.contains("1.2.3"));
    String cancelKey = UUID.randomUUID().toString();
    for (int n = 0; n < 2; n++)
      mvc.perform(
              post(adminRoot + "/" + id + "/cancel")
                  .with(actor(owner))
                  .header("If-Match", "\"" + ready.path("version").asLong() + "\"")
                  .header("Idempotency-Key", cancelKey))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.state").value("CANCELLED"));
    assertNull(
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
    assertEquals("CANCELLED", adminCreate(key).path("state").asText());
  }

  @Test
  void supportPackageIsScopedToGrantAndRevocationPreventsDownload() throws Exception {
    String grant = grant();
    var job =
        body(
            mvc.perform(
                    post("/api/v1/support/grants/" + grant + "/diagnostic-packages")
                        .with(actor(recipient))
                        .header("Idempotency-Key", "support-package"))
                .andExpect(status().isAccepted()));
    String id = job.path("id").asText();
    run();
    var content =
        body(
            mvc.perform(get(receivedRoot + "/" + id + "/content").with(actor(recipient)))
                .andExpect(status().isOk()));
    assertTrue(content.path("diagnostic").path("capabilities").isNull());
    assertTrue(content.path("diagnostic").path("configurations").isNull());
    mvc.perform(get(receivedRoot + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isForbidden());
    mvc.perform(
            post("/api/v1/tenants/" + tenant + "/support-grants/" + grant + "/revoke")
                .with(actor(owner))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "revoke-package-grant"))
        .andExpect(status().isOk());
    mvc.perform(get(receivedRoot + "/" + id + "/content").with(actor(recipient)))
        .andExpect(status().isForbidden());
    mvc.perform(get(receivedRoot + "/" + id).with(actor(recipient)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("REVOKED"));
    assertNull(
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
  }

  @Test
  void rejectsWeakAuthenticationCrossActorAndChildRecipient() throws Exception {
    var job = adminCreate("isolation");
    String id = job.path("id").asText();
    mvc.perform(get(adminRoot + "/" + id).with(actor(owner, false, true)))
        .andExpect(status().isUnauthorized());
    mvc.perform(get(adminRoot + "/" + id).with(actor("outsider")))
        .andExpect(status().isForbidden());
    mvc.perform(get(receivedRoot + "/" + id).with(actor(owner))).andExpect(status().isForbidden());
    String grant = grant();
    mvc.perform(
            post("/api/v1/support/grants/" + grant + "/diagnostic-packages")
                .with(actor(recipient, true, false))
                .header("Idempotency-Key", "child"))
        .andExpect(status().isForbidden());
  }

  @Test
  void registrationChangeInvalidatesReadyPackageAndPurgesCiphertext() throws Exception {
    var job = adminCreate("registration");
    String id = job.path("id").asText();
    run();
    db.update(
        "UPDATE devices SET registration_id=? WHERE tenant_id=? AND id=?",
        UUID.randomUUID().toString(),
        tenant,
        device);
    mvc.perform(get(adminRoot + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isForbidden());
    mvc.perform(get(adminRoot + "/" + id).with(actor(owner)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("REVOKED"));
    assertNull(
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(strings = {"membership", "subject", "device"})
  void lifecycleChangeBeforeGenerationCannotPublish(String change) throws Exception {
    String id = adminCreate("lifecycle").path("id").asText();
    switch (change) {
      case "membership" ->
          db.update(
              "UPDATE tenant_members SET version=version+1 WHERE tenant_id=? AND actor_id=?",
              tenant,
              owner);
      case "subject" ->
          db.update(
              "UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?",
              System.currentTimeMillis(),
              tenant,
              subject);
      case "device" ->
          db.update(
              "UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?", tenant, device);
    }
    run();
    assertEquals(
        "REVOKED",
        db.queryForObject("SELECT state FROM diagnostic_packages WHERE id=?", String.class, id));
    assertNull(
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
  }

  @Test
  void terminalExpiryRemovesCiphertextAndDoesNotExtendReplay() throws Exception {
    var job = adminCreate("expires");
    String id = job.path("id").asText();
    run();
    advance(job.path("expiresAt").asLong() + 1);
    mvc.perform(get(adminRoot + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isGone());
    assertNull(
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
    var replay = adminCreate("expires");
    assertEquals("EXPIRED", replay.path("state").asText());
    assertEquals(job.path("expiresAt"), replay.path("expiresAt"));
  }

  void advance(long value) {
    org.mockito.Mockito.doReturn(value).when(clock).millis();
    org.mockito.Mockito.doReturn(Instant.ofEpochMilli(value)).when(clock).instant();
  }

  @Test
  void expirationDuringEncryptionNeverPublishes() throws Exception {
    var job = adminCreate("expiry-generation");
    String id = job.path("id").asText();
    org.mockito.Mockito.doAnswer(
            call -> {
              Object sealed = call.callRealMethod();
              if (id.equals(call.getArgument(1))) advance(job.path("expiresAt").asLong() + 1);
              return sealed;
            })
        .when(cipher)
        .seal(
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.eq(id),
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.any(byte[].class));
    run();
    assertEquals(
        "EXPIRED",
        db.queryForObject("SELECT state FROM diagnostic_packages WHERE id=?", String.class, id));
    assertNull(
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
  }

  @Test
  void expirationDuringDecryptionReturnsNoPartialDownload() throws Exception {
    var job = adminCreate("expiry-download");
    String id = job.path("id").asText();
    run();
    org.mockito.Mockito.doAnswer(
            call -> {
              Object bytes = call.callRealMethod();
              advance(job.path("expiresAt").asLong() + 1);
              return bytes;
            })
        .when(cipher)
        .open(
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.eq(id),
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.anyString());
    mvc.perform(get(adminRoot + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isGone());
    assertNull(
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
    assertEquals(
        0,
        db.queryForObject(
            "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                + " action='DIAGNOSTIC_PACKAGE_DOWNLOADED'",
            Integer.class,
            tenant));
  }

  @Test
  void boundedRetriesNeverLeakErrorTextOrPublishAfterExhaustion() throws Exception {
    String id = adminCreate("retry").path("id").asText();
    org.mockito.Mockito.doThrow(new IllegalStateException("PRIVATE_ERROR_FIXTURE"))
        .when(cipher)
        .seal(
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.eq(id),
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.any(byte[].class));
    for (int attempt = 1; attempt <= 3; attempt++) {
      run();
      assertEquals(
          attempt,
          db.queryForObject(
              "SELECT attempts FROM diagnostic_packages WHERE id=?", Integer.class, id));
      assertNull(
          db.queryForObject(
              "SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
      db.update("UPDATE diagnostic_packages SET next_attempt_at=0 WHERE id=?", id);
    }
    var result =
        body(mvc.perform(get(adminRoot + "/" + id).with(actor(owner))).andExpect(status().isOk()));
    assertEquals("FAILED", result.path("state").asText());
    assertEquals("DIAGNOSTIC_PACKAGE_ATTEMPTS_EXHAUSTED", result.path("failureCode").asText());
    assertFalse(result.toString().contains("PRIVATE_ERROR"));
    run();
    assertEquals(
        3,
        db.queryForObject(
            "SELECT attempts FROM diagnostic_packages WHERE id=?", Integer.class, id));
  }

  @Test
  void staleClaimCannotOverwriteRecoveredGeneration() throws Exception {
    String id = adminCreate("recover").path("id").asText();
    String stale = UUID.randomUUID().toString();
    db.update(
        "UPDATE diagnostic_packages SET state='RUNNING',claim_token=?,lease_until=?,attempts=1"
            + " WHERE id=?",
        UUID.randomUUID().toString(),
        clock.millis() + 60000,
        id);
    org.springframework.test.util.ReflectionTestUtils.invokeMethod(
        context.getBean(DiagnosticPackageWorker.class), "produce", id, stale);
    assertEquals(
        "RUNNING",
        db.queryForObject("SELECT state FROM diagnostic_packages WHERE id=?", String.class, id));
    assertNull(
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
    db.update("UPDATE diagnostic_packages SET lease_until=0 WHERE id=?", id);
    run();
    assertEquals(
        "READY",
        db.queryForObject("SELECT state FROM diagnostic_packages WHERE id=?", String.class, id));
    String artifact =
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id);
    org.springframework.test.util.ReflectionTestUtils.invokeMethod(
        context.getBean(DiagnosticPackageWorker.class), "produce", id, stale);
    assertEquals(
        artifact,
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
    assertEquals(
        2,
        db.queryForObject(
            "SELECT attempts FROM diagnostic_packages WHERE id=?", Integer.class, id));
  }

  @Test
  void concurrentWorkersPublishOnceAndDoNotExposeInProgressArtifact() throws Exception {
    String id = adminCreate("workers").path("id").asText();
    var entered = new java.util.concurrent.CountDownLatch(1);
    var release = new java.util.concurrent.CountDownLatch(1);
    org.mockito.Mockito.doAnswer(
            call -> {
              entered.countDown();
              assertTrue(release.await(5, java.util.concurrent.TimeUnit.SECONDS));
              return call.callRealMethod();
            })
        .when(cipher)
        .seal(
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.eq(id),
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.any(byte[].class));
    var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
    try {
      var first =
          pool.submit(
              () -> {
                run();
                return true;
              });
      assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS));
      assertNull(
          db.queryForObject(
              "SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
      var second =
          pool.submit(
              () -> {
                run();
                return true;
              });
      release.countDown();
      first.get(10, java.util.concurrent.TimeUnit.SECONDS);
      second.get(10, java.util.concurrent.TimeUnit.SECONDS);
    } finally {
      release.countDown();
      pool.shutdownNow();
    }
    assertEquals(
        "READY",
        db.queryForObject("SELECT state FROM diagnostic_packages WHERE id=?", String.class, id));
    assertEquals(
        1,
        db.queryForObject(
            "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                + " action='DIAGNOSTIC_PACKAGE_GENERATED'",
            Integer.class,
            tenant));
  }

  @Test
  void capacityDoesNotBlockSameKeyReplayOrAllowAnEleventhActiveJob() throws Exception {
    for (int n = 0; n < 10; n++) adminCreate("capacity-" + n);
    assertEquals("QUEUED", adminCreate("capacity-0").path("state").asText());
    mvc.perform(
            post("/api/v1/tenants/" + tenant + "/devices/" + device + "/diagnostic-packages")
                .with(actor(owner))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "capacity-over")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("registrationId", registration))))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("DIAGNOSTIC_PACKAGE_CAPACITY_REACHED"));
    assertEquals(
        10,
        db.queryForObject(
            "SELECT COUNT(*) FROM diagnostic_packages WHERE tenant_id=?", Integer.class, tenant));
  }

  @Test
  void auditFailureRollsBackCreationAndSameKeyCanRetry() throws Exception {
    com.aimanager.audit.AuditService target =
        org.springframework.test.util.AopTestUtils.getUltimateTargetObject(audit);
    org.mockito.Mockito.doThrow(new IllegalStateException("PRIVATE_AUDIT_FIXTURE"))
        .when(target)
        .record(
            org.mockito.ArgumentMatchers.eq(tenant),
            org.mockito.ArgumentMatchers.eq(owner),
            org.mockito.ArgumentMatchers.eq("DIAGNOSTIC_PACKAGE_REQUESTED"),
            org.mockito.ArgumentMatchers.anyString());
    mvc.perform(
            post("/api/v1/tenants/" + tenant + "/devices/" + device + "/diagnostic-packages")
                .with(actor(owner))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "audit-create")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("registrationId", registration))))
        .andExpect(status().is5xxServerError());
    assertEquals(
        0,
        db.queryForObject(
            "SELECT COUNT(*) FROM diagnostic_packages WHERE tenant_id=?", Integer.class, tenant));
    org.mockito.Mockito.reset(target);
    adminCreate("audit-create");
  }

  @Test
  void cleanupRechecksRevokedAuthorityAndClearsReadyArtifacts() throws Exception {
    String id = adminCreate("cleanup").path("id").asText();
    run();
    db.update(
        "UPDATE tenant_members SET revoked_at=? WHERE tenant_id=? AND actor_id=?",
        java.sql.Timestamp.from(clock.instant()),
        tenant,
        owner);
    db.update("UPDATE diagnostic_packages SET next_validation_at=0 WHERE id=?", id);
    context.getBean(DiagnosticPackageMaintenance.class).purge(100);
    assertEquals(
        "REVOKED",
        db.queryForObject("SELECT state FROM diagnostic_packages WHERE id=?", String.class, id));
    assertNull(
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id));
  }

  @Test
  void anotherCurrentAdministratorStillCannotDownloadSomeoneElsesPackage() throws Exception {
    String id = adminCreate("coadmin").path("id").asText();
    run();
    String other = "coadmin-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",
        tenant,
        other,
        com.aimanager.identity.ActorKeys.key(other));
    mvc.perform(get(adminRoot + "/" + id + "/content").with(actor(other)))
        .andExpect(status().isForbidden());
    assertEquals(
        "READY",
        db.queryForObject("SELECT state FROM diagnostic_packages WHERE id=?", String.class, id));
  }

  @Test
  void missingKeysRejectCreationWithoutPersistingJobsAndCanRecover() throws Exception {
    org.mockito.Mockito.doThrow(
            new com.aimanager.shared.DomainException(
                org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                "DIAGNOSTIC_PACKAGE_UNAVAILABLE"))
        .when(cipher)
        .requireAvailable();
    mvc.perform(
            post("/api/v1/tenants/" + tenant + "/devices/" + device + "/diagnostic-packages")
                .with(actor(owner))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "no-key")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("registrationId", registration))))
        .andExpect(status().isServiceUnavailable());
    assertEquals(
        0,
        db.queryForObject(
            "SELECT COUNT(*) FROM diagnostic_packages WHERE tenant_id=?", Integer.class, tenant));
    org.mockito.Mockito.reset(cipher);
    adminCreate("no-key");
  }

  @Test
  void tamperedCiphertextAndChangedPayloadBindingAreNeverDownloaded() throws Exception {
    String id = adminCreate("tamper").path("id").asText();
    run();
    String encrypted =
        db.queryForObject("SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id);
    db.update(
        "UPDATE diagnostic_packages SET artifact='invalid.ciphertext.fixture' WHERE id=?", id);
    mvc.perform(get(adminRoot + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isServiceUnavailable());
    db.update(
        "UPDATE diagnostic_packages SET artifact=?,artifact_sha256=? WHERE id=?",
        encrypted,
        "a".repeat(64),
        id);
    mvc.perform(get(adminRoot + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isServiceUnavailable());
    assertEquals(
        0,
        db.queryForObject(
            "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                + " action='DIAGNOSTIC_PACKAGE_DOWNLOADED'",
            Integer.class,
            tenant));
  }

  @Test
  void supportPackageDeadlineNeverExceedsShorterGrantLifetime() throws Exception {
    String grant = grant();
    long expiry = clock.millis() + 60000;
    db.update("UPDATE support_grants SET expires_at=? WHERE id=?", expiry, grant);
    var job =
        body(
            mvc.perform(
                    post("/api/v1/support/grants/" + grant + "/diagnostic-packages")
                        .with(actor(recipient))
                        .header("Idempotency-Key", "short-grant"))
                .andExpect(status().isAccepted()));
    assertEquals(expiry, job.path("expiresAt").asLong());
  }

  @Test
  void oneCleanupAuditFailureDoesNotStarveOtherRevokedArtifacts() throws Exception {
    String first = adminCreate("purge-one").path("id").asText(),
        second = adminCreate("purge-two").path("id").asText();
    run();
    db.update(
        "UPDATE tenant_members SET version=version+1 WHERE tenant_id=? AND actor_id=?",
        tenant,
        owner);
    db.update("UPDATE diagnostic_packages SET next_validation_at=0 WHERE tenant_id=?", tenant);
    com.aimanager.audit.AuditService target =
        org.springframework.test.util.AopTestUtils.getUltimateTargetObject(audit);
    org.mockito.Mockito.doThrow(new IllegalStateException("PRIVATE_CLEANUP_AUDIT_FIXTURE"))
        .when(target)
        .record(
            org.mockito.ArgumentMatchers.eq(tenant),
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.eq("DIAGNOSTIC_PACKAGE_REVOKED"),
            org.mockito.ArgumentMatchers.eq(first));
    assertDoesNotThrow(() -> context.getBean(DiagnosticPackageMaintenance.class).purge(100));
    assertEquals(
        "REVOKED",
        db.queryForObject(
            "SELECT state FROM diagnostic_packages WHERE id=?", String.class, second));
    assertNull(
        db.queryForObject(
            "SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, second));
    assertNotNull(
        db.queryForObject(
            "SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, first));
    org.mockito.Mockito.reset(target);
    context.getBean(DiagnosticPackageMaintenance.class).purge(100);
    assertNull(
        db.queryForObject(
            "SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, first));
  }

  @Test
  void oversizedCapabilitiesFailFullPackageButAreNotReadForStatusOnlyGrant() throws Exception {
    for (int n = 0; n < 65; n++)
      db.update(
          "INSERT INTO"
              + " device_capabilities(tenant_id,device_id,capability_key,reported_supported,grant_status,checked_at)"
              + " VALUES(?,?,?,true,'GRANTED',?)",
          tenant,
          device,
          "custom.capability." + n,
          clock.millis());
    String adminId = adminCreate("too-many-capabilities").path("id").asText(), grant = grant();
    String supportId =
        body(mvc.perform(
                    post("/api/v1/support/grants/" + grant + "/diagnostic-packages")
                        .with(actor(recipient))
                        .header("Idempotency-Key", "only-status"))
                .andExpect(status().isAccepted()))
            .path("id")
            .asText();
    run();
    assertEquals(
        "FAILED",
        db.queryForObject(
            "SELECT state FROM diagnostic_packages WHERE id=?", String.class, adminId));
    assertEquals(
        "DIAGNOSTIC_TOO_LARGE",
        db.queryForObject(
            "SELECT failure_code FROM diagnostic_packages WHERE id=?", String.class, adminId));
    assertNull(
        db.queryForObject(
            "SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, adminId));
    mvc.perform(get(receivedRoot + "/" + supportId + "/content").with(actor(recipient)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.diagnostic.capabilities").isEmpty());
  }
}
