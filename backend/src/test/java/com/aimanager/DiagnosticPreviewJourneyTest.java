package com.aimanager;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
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
      "spring.datasource.url=${SUPPORT_TEST_DATABASE_URL:jdbc:h2:mem:diagnostic-preview;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${SUPPORT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${SUPPORT_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false",
      "manager.report-jobs.worker.enabled=false"
    })
@AutoConfigureMockMvc(
    print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
class DiagnosticPreviewJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @MockitoSpyBean ObjectMapper json;

  @org.springframework.test.context.bean.override.mockito.MockitoBean
  org.springframework.security.oauth2.jwt.JwtDecoder decoder;

  @org.springframework.boot.test.web.server.LocalServerPort int port;
  String owner, tenant, subject, device, registration, root;
  long now;

  RequestPostProcessor actor(boolean strong) {
    return jwt()
        .jwt(
            j ->
                j.subject(owner)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", strong ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  String tenant() throws Exception {
    var response =
        mvc.perform(
                post("/api/v1/tenants")
                    .with(actor(true))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(
                        "{\"name\":\"Diagnostic"
                            + " fixture\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse();
    return json.readTree(response.getContentAsString()).path("id").asText();
  }

  ResultActions preview() throws Exception {
    return mvc.perform(get(root).with(actor(true)));
  }

  @BeforeEach
  void setup() throws Exception {
    now = System.currentTimeMillis();
    owner = "diagnostic-owner-" + UUID.randomUUID();
    tenant = tenant();
    subject = UUID.randomUUID().toString();
    device = UUID.randomUUID().toString();
    registration = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'CHILD_PRIVATE_TEXT','AGE_7_12',?)",
        tenant,
        subject,
        now);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at,last_heartbeat_at,agent_version)"
            + " VALUES(?,?,?,?,'CHILD_DEVICE_NAME','ANDROID','14','ACTIVE','SECRET_PRIVATE_KEY','SECRET_THUMBPRINT',?,?,'1.2.3')",
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
    db.update(
        "INSERT INTO configuration_device_heads(tenant_id,registration_id,device_id,next_cursor)"
            + " VALUES(?,?,?,1)",
        tenant,
        registration,
        device);
    configuration();
    root = "/api/v1/tenants/" + tenant + "/devices/" + device + "/diagnostic-preview";
  }

  void configuration() {
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
  void adultPreviewIsAllowlistedAuditedAndNonCacheable() throws Exception {
    var response =
        mvc.perform(get(root).with(actor(true)).header("X-Correlation-Id", "SECRET_CALLER_URL"))
            .andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(
                header().stringValues("Vary", org.hamcrest.Matchers.hasItem("Authorization")))
            .andExpect(jsonPath("$.schemaVersion").value(1))
            .andExpect(jsonPath("$.scope.registrationId").value(registration))
            .andExpect(jsonPath("$.versions.agent.value").value("1.2.3"))
            .andExpect(jsonPath("$.configurations[0].policyHash").value("a".repeat(64)))
            .andExpect(jsonPath("$.configurations[0].configurationHash").value("b".repeat(64)))
            .andReturn()
            .getResponse();
    assertThat(response.getContentAsString())
        .doesNotContain(
            "SECRET", "CHILD_", "private.example", "publicKey", "documentJson", "compactJws");
    String correlation =
        json.readTree(response.getContentAsString()).path("correlationId").asText();
    assertThat(correlation).isEqualTo(response.getHeader("X-Correlation-Id"));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='DIAGNOSTIC_PREVIEWED' AND resource_id=? AND correlation_id=?",
                Integer.class,
                tenant,
                device,
                correlation))
        .isEqualTo(1);
  }

  @Test
  void weakAuthenticationCannotReadOrCreatePreviewAudit() throws Exception {
    mvc.perform(get(root).with(actor(false)))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='DIAGNOSTIC_PREVIEWED'",
                Integer.class,
                tenant))
        .isZero();
  }

  @Test
  void removedMembershipAndOtherTenantDeviceAreDenied() throws Exception {
    String other = tenant();
    mvc.perform(
            get("/api/v1/tenants/" + other + "/devices/" + device + "/diagnostic-preview")
                .with(actor(true)))
        .andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET revoked_at=? WHERE tenant_id=? AND actor_key=?",
        java.sql.Timestamp.from(Instant.ofEpochMilli(now)),
        tenant,
        ActorKeys.key(owner));
    preview().andExpect(status().isForbidden());
  }

  @Test
  void childTeacherAndAuditorDoNotGainDiagnosticScope() throws Exception {
    for (String role : List.of("CHILD", "TEACHER", "AUDITOR")) {
      db.update(
          "UPDATE tenant_members SET role=?,subject_id=? WHERE tenant_id=? AND actor_key=?",
          role,
          subject,
          tenant,
          ActorKeys.key(owner));
      preview().andExpect(status().isForbidden());
    }
  }

  @Test
  void archivedSubjectIsDeniedEvenWhenDeviceIsStillActive() throws Exception {
    db.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?", now, tenant, subject);
    preview().andExpect(status().isForbidden());
  }

  @Test
  void revokedDeviceMetadataDoesNotRestoreDeviceAccess() throws Exception {
    db.update("UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?", tenant, device);
    preview().andExpect(status().isOk()).andExpect(jsonPath("$.device.state").value("REVOKED"));
    assertThat(
            db.queryForObject(
                "SELECT state FROM devices WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                device))
        .isEqualTo("REVOKED");
  }

  @Test
  void newRegistrationCannotReadOldConfigurationMetadata() throws Exception {
    String newer = UUID.randomUUID().toString();
    db.update(
        "UPDATE devices SET registration_id=? WHERE tenant_id=? AND id=?", newer, tenant, device);
    preview()
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.scope.registrationId").value(newer))
        .andExpect(jsonPath("$.configurations").isEmpty());
  }

  @Test
  void excessiveCapabilitySourceIsRejectedBeforeSnapshotMaterialization() throws Exception {
    for (int i = 0; i < 64; i++)
      db.update(
          "INSERT INTO"
              + " device_capabilities(tenant_id,device_id,capability_key,reported_supported,grant_status,checked_at)"
              + " VALUES(?,?,?,false,'NOT_REQUESTED',?)",
          tenant,
          device,
          "unknown." + i,
          now);
    preview()
        .andExpect(status().isPayloadTooLarge())
        .andExpect(jsonPath("$.errorCode").value("DIAGNOSTIC_TOO_LARGE"));
  }

  @Test
  void excessiveCurrentConfigurationsAreRejectedWithoutAudit() throws Exception {
    for (int i = 0; i < 100; i++) configuration();
    preview()
        .andExpect(status().isPayloadTooLarge())
        .andExpect(jsonPath("$.errorCode").value("DIAGNOSTIC_TOO_LARGE"));
    noPreviewAudit();
  }

  @Test
  void mismatchedStreamPolicyFailsClosed() throws Exception {
    db.update(
        "UPDATE configuration_streams SET policy_id=? WHERE tenant_id=? AND registration_id=?",
        UUID.randomUUID().toString(),
        tenant,
        registration);
    preview()
        .andExpect(status().isBadGateway())
        .andExpect(jsonPath("$.errorCode").value("DIAGNOSTIC_SOURCE_INVALID"));
    noPreviewAudit();
  }

  @Test
  void mismatchedDeviceHeadFailsClosed() throws Exception {
    db.update(
        "UPDATE configuration_device_heads SET device_id=? WHERE tenant_id=? AND registration_id=?",
        UUID.randomUUID().toString(),
        tenant,
        registration);
    preview()
        .andExpect(status().isBadGateway())
        .andExpect(jsonPath("$.errorCode").value("DIAGNOSTIC_SOURCE_INVALID"));
    noPreviewAudit();
  }

  @Test
  void serializationFailureDoesNotCommitSuccessAuditOrEchoFailureText() throws Exception {
    doAnswer(
            invocation -> {
              if (invocation
                  .getArgument(0)
                  .getClass()
                  .getName()
                  .equals("com.aimanager.support.internal.DiagnosticProjection$Document"))
                throw new com.fasterxml.jackson.core.JsonProcessingException(
                    "SECRET_SERIALIZER_DETAIL") {};
              return invocation.callRealMethod();
            })
        .when(json)
        .writeValueAsBytes(any());
    var response =
        preview()
            .andExpect(status().isBadGateway())
            .andExpect(jsonPath("$.errorCode").value("DIAGNOSTIC_SERIALIZATION_FAILED"))
            .andReturn()
            .getResponse();
    assertThat(response.getContentAsString()).doesNotContain("SECRET_SERIALIZER_DETAIL");
    noPreviewAudit();
  }

  @Test
  void serializedCapacityIsCheckedBeforeAuditAndResponse() throws Exception {
    doAnswer(
            invocation -> {
              if (invocation
                  .getArgument(0)
                  .getClass()
                  .getName()
                  .equals("com.aimanager.support.internal.DiagnosticProjection$Document"))
                return new byte[512 * 1024 + 1];
              return invocation.callRealMethod();
            })
        .when(json)
        .writeValueAsBytes(any());
    preview()
        .andExpect(status().isPayloadTooLarge())
        .andExpect(jsonPath("$.errorCode").value("DIAGNOSTIC_TOO_LARGE"));
    noPreviewAudit();
  }

  void noPreviewAudit() {
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='DIAGNOSTIC_PREVIEWED'",
                Integer.class,
                tenant))
        .isZero();
  }

  @Test
  @org.junit.jupiter.api.condition.EnabledIfSystemProperty(
      named = "device.dart.command",
      matches = ".+")
  void productionDartClientReadsRealHttpAndRechecksCurrentAccess() throws Exception {
    String strong = UUID.randomUUID().toString(),
        weak = UUID.randomUUID().toString(),
        outsider = UUID.randomUUID().toString();
    org.mockito.Mockito.when(decoder.decode(org.mockito.ArgumentMatchers.anyString()))
        .thenAnswer(
            call -> {
              String token = call.getArgument(0);
              if (!Set.of(strong, weak, outsider).contains(token))
                throw new org.springframework.security.oauth2.jwt.BadJwtException(
                    "Unknown diagnostic fixture");
              return org.springframework.security.oauth2.jwt.Jwt.withTokenValue(token)
                  .header("alg", "fixture")
                  .subject(token.equals(outsider) ? "diagnostic-outsider" : owner)
                  .issuedAt(Instant.now())
                  .expiresAt(Instant.now().plusSeconds(300))
                  .claim("auth_time", Instant.now().getEpochSecond())
                  .claim("amr", token.equals(weak) ? List.of("pwd") : List.of("pwd", "otp"))
                  .build();
            });
    var directory =
        java.nio.file.Files.createTempDirectory(
            java.nio.file.Files.createDirectories(java.nio.file.Path.of(".local").toAbsolutePath()),
            "diagnostic-http-");
    var fixture = directory.resolve("fixture.json");
    var values = new LinkedHashMap<String, Object>();
    values.put("testOnly", true);
    values.put("apiRoot", "http://127.0.0.1:" + port + "/api/v1");
    values.put("tenantId", tenant);
    values.put("deviceId", device);
    values.put("registrationId", registration);
    values.put("strongToken", strong);
    values.put("weakToken", weak);
    values.put("outsiderToken", outsider);
    try {
      runDiagnosticClient(fixture, values, "initial");
      db.update("UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?", tenant, device);
      runDiagnosticClient(fixture, values, "revoked-device");
      String replacement = UUID.randomUUID().toString();
      db.update(
          "UPDATE devices SET state='ACTIVE',registration_id=? WHERE tenant_id=? AND id=?",
          replacement,
          tenant,
          device);
      runDiagnosticClient(fixture, values, "changed-registration");
      values.put("registrationId", replacement);
      runDiagnosticClient(fixture, values, "new-registration");
      db.update(
          "UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?", now, tenant, subject);
      runDiagnosticClient(fixture, values, "archived-subject");
      db.update("UPDATE subjects SET archived_at=NULL WHERE tenant_id=? AND id=?", tenant, subject);
      db.update(
          "UPDATE tenant_members SET revoked_at=? WHERE tenant_id=? AND actor_key=?",
          java.sql.Timestamp.from(Instant.now()),
          tenant,
          ActorKeys.key(owner));
      runDiagnosticClient(fixture, values, "revoked-member");
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                      + " action='DIAGNOSTIC_PREVIEWED'",
                  Integer.class,
                  tenant))
          .isEqualTo(5);
    } finally {
      java.nio.file.Files.deleteIfExists(fixture);
    }
  }

  private void runDiagnosticClient(
      java.nio.file.Path fixture, Map<String, Object> values, String phase) throws Exception {
    values.put("phase", phase);
    json.writeValue(fixture.toFile(), values);
    var output = fixture.getParent().resolve(phase + ".log");
    var process =
        new ProcessBuilder(
                System.getProperty("device.dart.command"),
                "run",
                "tool/verify_diagnostic_http.dart",
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
      throw new AssertionError("Diagnostic client deadline exceeded");
    }
    assertThat(process.exitValue()).as("Diagnostic client diagnostics: %s", output).isZero();
    assertThat(java.nio.file.Files.readString(output)).contains("PASS diagnostic HTTP " + phase);
  }

  @Test
  void subjectArchiveWaitsForPreviewSerialization() throws Exception {
    lockingBoundary("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?", subject);
  }

  @Test
  void memberRevocationWaitsForPreviewSerialization() throws Exception {
    lockingBoundary(
        "UPDATE tenant_members SET revoked_at=? WHERE tenant_id=? AND actor_key=?",
        ActorKeys.key(owner));
  }

  void lockingBoundary(String sql, String id) throws Exception {
    var copied = new CountDownLatch(1);
    var resume = new CountDownLatch(1);
    var changing = new CountDownLatch(1);
    doAnswer(
            invocation -> {
              var value = invocation.callRealMethod();
              if (invocation
                  .getArgument(0)
                  .getClass()
                  .getName()
                  .equals("com.aimanager.support.internal.DiagnosticProjection$Document")) {
                copied.countDown();
                assertThat(resume.await(5, TimeUnit.SECONDS)).isTrue();
              }
              return value;
            })
        .when(json)
        .writeValueAsBytes(any());
    var threads = Executors.newFixedThreadPool(2);
    try {
      var reading = threads.submit(() -> preview().andExpect(status().isOk()));
      assertThat(copied.await(5, TimeUnit.SECONDS)).isTrue();
      var mutation =
          threads.submit(
              () -> {
                changing.countDown();
                Object time =
                    sql.contains("tenant_members")
                        ? java.sql.Timestamp.from(Instant.ofEpochMilli(now))
                        : now;
                return db.update(sql, time, tenant, id);
              });
      assertThat(changing.await(2, TimeUnit.SECONDS)).isTrue();
      assertThatThrownBy(() -> mutation.get(150, TimeUnit.MILLISECONDS))
          .isInstanceOf(TimeoutException.class);
      resume.countDown();
      reading.get(8, TimeUnit.SECONDS);
      assertThat(mutation.get(8, TimeUnit.SECONDS)).isEqualTo(1);
      preview().andExpect(status().isForbidden());
    } finally {
      resume.countDown();
      threads.shutdownNow();
      threads.awaitTermination(5, TimeUnit.SECONDS);
    }
  }
}
