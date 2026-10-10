package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.signing.ConfigurationSigner;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/**
 * A single real Android -> Spring -> SQL journey. Only adult OIDC/MFA is a fixture. No fake device
 * rows, device credentials, enrollment proofs, HTTP responses, database opener or native encryption
 * keys. Requires an explicitly owned debug AVD; ordinary backend runs do not operate any device.
 */
@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "server.address=127.0.0.1",
      "spring.datasource.url=${ANDROID_CHILD_TEST_DATABASE_URL:jdbc:h2:mem:androidchild;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${ANDROID_CHILD_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${ANDROID_CHILD_TEST_DATABASE_PASSWORD:}",
      "manager.approval.expiry-job.enabled=false"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
@EnabledIfSystemProperty(named = "device.android.runner", matches = ".+")
class AndroidChildSubmissionJourneyTest {
  private static final Path SIGNING_DIRECTORY;
  private static final Path SIGNING_KEY;

  static {
    try {
      Path root = Path.of(".local").toAbsolutePath();
      Files.createDirectories(root);
      SIGNING_DIRECTORY = Files.createTempDirectory(root, "android-production-signing-");
      SIGNING_KEY = SIGNING_DIRECTORY.resolve("private.jwk");
      Files.writeString(
          SIGNING_KEY,
          new ECKeyGenerator(Curve.P_256).keyID("android-production").generate().toJSONString());
    } catch (Exception failure) {
      throw new IllegalStateException("Android acceptance signing initialization failed");
    }
  }

  @DynamicPropertySource
  static void signing(DynamicPropertyRegistry registry) {
    registry.add("manager.delivery.signing-key-file", () -> SIGNING_KEY.toString());
  }

  @AfterAll
  static void removeSigningFixture() throws Exception {
    Files.deleteIfExists(SIGNING_KEY);
    Files.deleteIfExists(SIGNING_DIRECTORY);
  }

  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper mapper;
  @Autowired Clock clock;
  @Autowired ConfigurationSigner signer;
  @LocalServerPort int port;
  @MockitoBean JwtDecoder decoder;

  private RequestPostProcessor adult(String owner) {
    return jwt()
        .jwt(
            j ->
                j.subject(owner)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private JsonNode create(String route, String owner, Object body) throws Exception {
    return mapper.readTree(
        mvc.perform(
                post(route)
                    .with(adult(owner))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(mapper.writeValueAsString(body)))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  @Test
  void realEnrollmentNativeCrashRecoveryAndRevocation() throws Exception {
    assertThat(System.getProperty("device.android.owned")).isEqualTo("true");
    when(decoder.decode(anyString())).thenThrow(new BadJwtException("Not an adult JWT"));
    String owner = "android-owner-" + UUID.randomUUID();
    String tenant =
        create(
                "/api/v1/tenants",
                owner,
                Map.of("name", "原生验收家庭", "kind", "FAMILY", "timeZone", "UTC"))
            .get("id")
            .asText();
    String prefix = "/api/v1/tenants/" + tenant;
    String subject =
        create(prefix + "/subjects", owner, Map.of("nickname", "合成儿童", "ageBand", "AGE_7_12"))
            .get("id")
            .asText();
    JsonNode ticket =
        create(
            prefix + "/enrollments",
            owner,
            Map.of("subjectId", subject, "platform", "ANDROID", "requestedMode", "BYOD"));
    Files.createDirectories(Path.of(".local"));
    Path directory =
        Files.createTempDirectory(Path.of(".local").toAbsolutePath(), "android-child-http-");
    Path fixtureFile = directory.resolve("fixture.json");
    var fixture = new HashMap<String, Object>();
    fixture.put("schemaVersion", 1);
    fixture.put("runId", UUID.randomUUID().toString());
    fixture.put("tenantId", tenant);
    fixture.put("subjectId", subject);
    fixture.put("apiRoot", "http://127.0.0.1:" + port + "/api/v1");
    // Same four-field copy contract as the guardian application's ticket encoder.
    fixture.put(
        "ticket",
        Map.of(
            "tenantId",
            tenant,
            "id",
            ticket.get("id").asText(),
            "token",
            ticket.get("token").asText(),
            "expiresAt",
            ticket.get("expiresAt").asLong()));
    String device = null;
    boolean cleaned = false;
    try {
      run(fixtureFile, fixture, directory, "enroll");
      fixture.remove("ticket");
      Files.deleteIfExists(fixtureFile);
      JsonNode handoff = mapper.readTree(directory.resolve("pairing.json").toFile());
      Files.delete(directory.resolve("pairing.json"));
      device = handoff.get("deviceId").asText();
      String registration = handoff.get("registrationId").asText();
      fixture.put("deviceId", device);
      fixture.put("registrationId", registration);
      assertThat(
              db.queryForObject(
                  "SELECT state FROM devices WHERE tenant_id=? AND id=?",
                  String.class,
                  tenant,
                  device))
          .isEqualTo("AWAITING_CONFIRMATION");
      assertThat(
              db.queryForObject(
                  "SELECT public_key_jwk FROM devices WHERE tenant_id=? AND id=?",
                  String.class,
                  tenant,
                  device))
          .contains("\"P-256\"")
          .doesNotContain("\"d\"");
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM device_credentials WHERE tenant_id=? AND device_id=?",
                  Integer.class,
                  tenant,
                  device))
          .isEqualTo(1);
      mvc.perform(
              post(prefix + "/enrollments/" + ticket.get("id").asText() + "/confirm")
                  .with(adult(owner))
                  .contentType(MediaType.APPLICATION_JSON)
                  .content(
                      mapper.writeValueAsString(
                          Map.of("pairingCode", handoff.get("pairingCode").asText()))))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.managementMode").value("BYOD"))
          .andExpect(jsonPath("$.controlLevel").value("LIMITED"));
      String firstApp = application(prefix, owner, "原生阅读", "org.example.native.reading");
      String secondApp = application(prefix, owner, "原生练习", "org.example.native.practice");
      String policy =
          create(
                  prefix + "/policies",
                  owner,
                  Map.of(
                      "name",
                      "原生阅读安排",
                      "kind",
                      "POLICY",
                      "rules",
                      List.of(
                          Map.of(
                              "id",
                              "reading",
                              "kind",
                              "APP_LAUNCH",
                              "effect",
                              "DENY",
                              "applicationId",
                              firstApp,
                              "required",
                              true),
                          Map.of(
                              "id",
                              "practice",
                              "kind",
                              "APP_LAUNCH",
                              "effect",
                              "DENY",
                              "applicationId",
                              secondApp,
                              "required",
                              true))))
              .get("id")
              .asText();
      String policyPath = prefix + "/policies/" + policy;
      JsonNode preview =
          mapper.readTree(
              mvc.perform(
                      post(policyPath + "/previews")
                          .with(adult(owner))
                          .header("If-Match", "\"0\"")
                          .contentType(MediaType.APPLICATION_JSON)
                          .content(mapper.writeValueAsString(Map.of("deviceIds", List.of(device)))))
                  .andExpect(status().isCreated())
                  .andReturn()
                  .getResponse()
                  .getContentAsString());
      mvc.perform(
              post(policyPath + "/publications")
                  .with(adult(owner))
                  .header("If-Match", "\"0\"")
                  .header("Idempotency-Key", UUID.randomUUID())
                  .contentType(MediaType.APPLICATION_JSON)
                  .content(
                      mapper.writeValueAsString(
                          Map.of(
                              "previewId",
                              preview.get("id").asText(),
                              "previewHash",
                              preview.get("hash").asText(),
                              "mode",
                              "CONFIGURE_ONLY"))))
          .andExpect(status().isCreated());

      // Public-only trust ring is immutable deployment input for the Android
      // production composition. The private signing key never leaves Spring.
      fixture.put("configurationIssuer", "ai-manager");
      fixture.put("configurationKeys", signer.publicKeys());
      run(fixtureFile, fixture, directory, "production");
      assertThat(
              db.queryForObject(
                  "SELECT heartbeat_sequence FROM devices WHERE tenant_id=? AND id=?",
                  Long.class,
                  tenant,
                  device))
          .isEqualTo(1);

      // Guardian cloud consent and Android special access are independent. The
      // native phase grants only the owned emulator's OS appop and restores it.
      observationSetting(prefix, owner, device, 0, true);
      run(fixtureFile, fixture, directory, "observation");
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM usage_observation_batches WHERE tenant_id=? AND"
                      + " device_id=?",
                  Integer.class,
                  tenant,
                  device))
          .isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT payload_json FROM usage_observation_batches WHERE tenant_id=? AND"
                      + " device_id=?",
                  String.class,
                  tenant,
                  device))
          .contains("ANDROID_USAGE_STATS");
      long reportTo = clock.millis();
      mvc.perform(
              get(prefix + "/usage-reports")
                  .with(adult(owner))
                  .param("deviceId", device)
                  .param("from", Long.toString(reportTo - 3_600_000))
                  .param("to", Long.toString(reportTo))
                  .param("timeZone", "UTC"))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.precision").value("OS_AGGREGATE"))
          .andExpect(jsonPath("$.evidenceStatus").value("AGENT_REPORTED_UNVERIFIED"))
          .andExpect(jsonPath("$.devices[0].status").value("OBSERVED"));
      observationSetting(prefix, owner, device, 1, false);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM usage_observation_batches WHERE tenant_id=? AND"
                      + " device_id=?",
                  Integer.class,
                  tenant,
                  device))
          .isZero();
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM usage_observation_heads WHERE tenant_id=? AND device_id=?",
                  Integer.class,
                  tenant,
                  device))
          .isZero();
      mvc.perform(
              get(prefix + "/usage-reports")
                  .with(adult(owner))
                  .param("deviceId", device)
                  .param("from", Long.toString(reportTo - 3_600_000))
                  .param("to", Long.toString(reportTo))
                  .param("timeZone", "UTC"))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.devices[0].status").value("NOT_AUTHORIZED"))
          .andExpect(jsonPath("$.devices[0].applications.length()").value(0));
      run(fixtureFile, fixture, directory, "observation-revoked");
      fixture.remove("configurationIssuer");
      fixture.remove("configurationKeys");

      run(fixtureFile, fixture, directory, "submit");
      assertThat(
              db.queryForObject(
                  "SELECT heartbeat_sequence FROM devices WHERE tenant_id=? AND id=?",
                  Long.class,
                  tenant,
                  device))
          .isEqualTo(2);
      String request =
          db.queryForObject(
              "SELECT id FROM access_requests WHERE tenant_id=?", String.class, tenant);
      fixture.put("requestId", request);
      JsonNode approved =
          mapper.readTree(
              mvc.perform(
                      post(prefix + "/access-requests/" + request + "/decisions")
                          .with(adult(owner))
                          .header("If-Match", "\"0\"")
                          .header("Idempotency-Key", UUID.randomUUID())
                          .contentType(MediaType.APPLICATION_JSON)
                          .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":60}"))
                  .andExpect(status().isOk())
                  .andReturn()
                  .getResponse()
                  .getContentAsString());
      fixture.put("absoluteNotAfter", approved.get("absoluteNotAfter").asLong());
      expire(tenant, "access.device.request");
      run(fixtureFile, fixture, directory, "recover");
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM access_requests WHERE tenant_id=?", Integer.class, tenant))
          .isEqualTo(1);
      run(fixtureFile, fixture, directory, "cancel");
      expire(tenant, "access.device.cancel");
      run(fixtureFile, fixture, directory, "cancel-recover");
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM access_requests WHERE tenant_id=?", Integer.class, tenant))
          .isEqualTo(2);
      assertThat(
              db.queryForObject(
                  "SELECT state FROM access_requests WHERE tenant_id=? AND application_id=?",
                  String.class,
                  tenant,
                  secondApp))
          .isEqualTo("CANCELLED");
      assertThat(
              db.queryForObject(
                  "SELECT version FROM access_requests WHERE tenant_id=? AND application_id=?",
                  Long.class,
                  tenant,
                  secondApp))
          .isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT absolute_not_after FROM access_requests WHERE tenant_id=? AND id=?",
                  Long.class,
                  tenant,
                  request))
          .isEqualTo(approved.get("absoluteNotAfter").asLong());
      // Await the real business deadline; never rewrite it or use a fake clock.
      long remaining = approved.get("absoluteNotAfter").asLong() - clock.millis();
      assertThat(remaining).isLessThanOrEqualTo(60_000);
      if (remaining >= 0) Thread.sleep(remaining + 100);
      run(fixtureFile, fixture, directory, "expired");
      assertThat(
              db.queryForObject(
                  "SELECT state FROM access_requests WHERE tenant_id=? AND id=?",
                  String.class,
                  tenant,
                  request))
          .isEqualTo("EXPIRED");
      run(fixtureFile, fixture, directory, "offline");
      mvc.perform(post(prefix + "/devices/" + device + "/revoke").with(adult(owner)))
          .andExpect(status().isNoContent());
      run(fixtureFile, fixture, directory, "revoked");
      run(fixtureFile, fixture, directory, "blocked");
      run(fixtureFile, fixture, directory, "cleanup");
      cleaned = true;
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM device_credentials WHERE tenant_id=? AND active=true",
                  Integer.class,
                  tenant))
          .isZero();
      assertThat(
              db.queryForObject(
                  "SELECT expires_at FROM idempotency_requests WHERE scope_id=? AND"
                      + " operation='access.device.cancel'",
                  Long.class,
                  tenant))
          .isEqualTo(1);
      assertInstallStable(directory);
      System.out.println(
          "Android real Spring registration/submission journey: PASS; native fixture removed");
    } finally {
      // Attempt scoped cleanup if there is a fully claimed identity. A failure
      // remains a failed acceptance; never clear data or overwrite diagnostics.
      if (!cleaned && !Files.exists(directory.resolve("native-cleanup"))) {
        try {
          run(fixtureFile, fixture, directory, "cleanup");
        } catch (Exception | AssertionError cleanupFailure) {
          System.err.println("Android scoped cleanup incomplete; preserve owned AVD for diagnosis");
        }
      }
      Files.deleteIfExists(fixtureFile);
      Files.deleteIfExists(directory.resolve("pairing.json"));
    }
  }

  private String application(String prefix, String owner, String name, String packageName)
      throws Exception {
    return create(
            prefix + "/applications",
            owner,
            Map.of(
                "displayName",
                name,
                "platform",
                "ANDROID",
                "packageName",
                packageName,
                "profile",
                "PRIMARY",
                "signingDigests",
                List.of("a".repeat(64))))
        .get("id")
        .asText();
  }

  private void observationSetting(
      String prefix, String owner, String device, int expected, boolean usage) throws Exception {
    mvc.perform(
            put(prefix + "/devices/" + device + "/observation-settings")
                .with(adult(owner))
                .header("If-Match", "\"" + expected + "\"")
                .header("Idempotency-Key", UUID.randomUUID())
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    mapper.writeValueAsString(
                        Map.of(
                            "inventoryEnabled",
                            false,
                            "usageEnabled",
                            usage,
                            "reason",
                            usage ? "监护人确认原生使用摘要验收" : "监护人撤回原生使用摘要验收"))))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(expected + 1))
        .andExpect(jsonPath("$.usageEnabled").value(usage));
  }

  private void expire(String tenant, String operation) {
    assertThat(
            db.update(
                "UPDATE idempotency_requests SET expires_at=1 WHERE scope_id=? AND operation=?",
                tenant,
                operation))
        .isEqualTo(1);
  }

  private void run(Path file, Map<String, Object> fixture, Path directory, String phase)
      throws Exception {
    mapper.writeValue(file.toFile(), fixture);
    var arguments =
        new ArrayList<>(
            List.of(
                System.getProperty("device.python.command"),
                System.getProperty("device.android.runner"),
                "--fixture",
                file.toString(),
                "--phase",
                phase,
                "--app",
                System.getProperty("device.child.package"),
                "--adb",
                System.getProperty("device.adb.command"),
                "--flutter",
                System.getProperty("device.flutter.command"),
                "--serial",
                System.getProperty("device.android.serial"),
                "--expected-avd",
                System.getProperty("device.android.avd"),
                "--allow-owned-debug-avd"));
    Path log = directory.resolve("host-" + phase + ".log");
    var process =
        new ProcessBuilder(arguments)
            .redirectErrorStream(true)
            .redirectOutput(log.toFile())
            .start();
    if (!process.waitFor(360, TimeUnit.SECONDS)) {
      var descendants = process.descendants().toList();
      for (int i = descendants.size() - 1; i >= 0; i--) descendants.get(i).destroyForcibly();
      process.destroyForcibly();
      process.waitFor(5, TimeUnit.SECONDS);
      throw new AssertionError("Owned Android phase deadline exceeded: " + phase);
    }
    assertThat(process.exitValue()).as("Android %s diagnostics: %s", phase, log).isZero();
    assertThat(Files.readString(log)).contains("Android real HTTP " + phase + ": PASS");
  }

  private void assertInstallStable(Path directory) throws Exception {
    JsonNode installation = null;
    var pids = new java.util.HashSet<Integer>();
    for (String phase :
        List.of(
            "enroll",
            "production",
            "observation",
            "observation-revoked",
            "submit",
            "recover",
            "cancel",
            "cancel-recover",
            "expired",
            "offline",
            "revoked",
            "blocked",
            "cleanup")) {
      JsonNode evidence =
          mapper.readTree(
              directory.resolve("native-" + phase).resolve("host-result.json").toFile());
      assertThat(evidence.get("nativePidVerified").asBoolean()).isTrue();
      assertThat(evidence.get("processStopped").asBoolean()).isTrue();
      assertThat(pids.add(evidence.get("pid").asInt())).isTrue();
      if (installation == null) installation = evidence.get("installation");
      else assertThat(evidence.get("installation")).isEqualTo(installation);
    }
  }
}
