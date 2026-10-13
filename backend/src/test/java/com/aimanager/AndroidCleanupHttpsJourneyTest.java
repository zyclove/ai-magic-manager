package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Clock;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
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
 * Real AndroidKeyStore enrollment and cleanup proofs, Spring HTTPS and SQL receipts on a dedicated
 * debug AVD. Adult OIDC/MFA and the temporary TLS trust certificate are explicit test fixtures. This
 * test never bootstraps device registrations or credentials through SQL and never operates an AVD
 * unless the dedicated runner and ownership properties are supplied.
 */
@EnabledIfSystemProperty(named = "device.cleanup.android.runner", matches = ".+")
@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "server.address=127.0.0.1",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "manager.approval.expiry-job.enabled=false",
      "manager.quota.materialization-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class AndroidCleanupHttpsJourneyTest {
  private static final List<String> PHASES =
      List.of("negative", "enroll", "active", "cleanup", "verify");
  private static final String DATABASE_ID = UUID.randomUUID().toString().replace("-", "");
  private static final String TLS_FIXTURE_PASSWORD = "CleanupHttpsFixture123";
  private static Path signingDirectory;
  private static Path signingKey;
  private static byte[] serverCertificate;
  private static String keyStoreUri;
  private static String keyStoreAlias;

  @DynamicPropertySource
  static void isolatedConfiguration(DynamicPropertyRegistry registry) {
    initializeKeyFixtures();
    registry.add(
        "spring.datasource.url",
        () ->
            "jdbc:h2:mem:cleanuphttps"
                + DATABASE_ID
                + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE");
    registry.add("manager.delivery.signing-key-file", () -> signingKey.toString());
    registry.add("server.ssl.enabled", () -> true);
    registry.add("server.ssl.key-store", () -> keyStoreUri);
    registry.add("server.ssl.key-store-type", () -> "PKCS12");
    registry.add("server.ssl.key-store-password", AndroidCleanupHttpsJourneyTest::tlsPassword);
    registry.add("server.ssl.key-alias", () -> keyStoreAlias);
    registry.add("server.ssl.enabled-protocols", () -> "TLSv1.2,TLSv1.3");
  }

  private static synchronized void initializeKeyFixtures() {
    if (signingKey != null) return;
    try {
      if (!"true".equals(System.getProperty("device.cleanup.android.owned"))) {
        throw new IllegalArgumentException();
      }
      Path keyStore = Path.of(requiredProperty("device.cleanup.tls.keystore")).toAbsolutePath();
      Path certificate =
          Path.of(requiredProperty("device.cleanup.tls.certificate")).toAbsolutePath();
      if (!Files.isRegularFile(keyStore)
          || !Files.isRegularFile(certificate)
          || Files.size(certificate) > 16384) {
        throw new IllegalArgumentException();
      }
      byte[] publicDer = Files.readAllBytes(certificate);
      var publicCertificate =
          (X509Certificate)
              CertificateFactory.getInstance("X.509")
                  .generateCertificate(new ByteArrayInputStream(publicDer));
      publicCertificate.checkValidity();
      if (!MessageDigest.isEqual(publicDer, publicCertificate.getEncoded())) {
        throw new IllegalArgumentException();
      }
      var names = publicCertificate.getSubjectAlternativeNames();
      if (names == null
          || names.stream()
              .noneMatch(
                  name ->
                      Integer.valueOf(7).equals(name.get(0))
                          && "127.0.0.1".equals(name.get(1)))) {
        throw new IllegalArgumentException();
      }
      var store = KeyStore.getInstance("PKCS12");
      try (var input = Files.newInputStream(keyStore)) {
        store.load(input, tlsPassword().toCharArray());
      }
      var aliases = new ArrayList<String>();
      for (var entries = store.aliases(); entries.hasMoreElements(); ) {
        String alias = entries.nextElement();
        if (store.isKeyEntry(alias)) aliases.add(alias);
      }
      if (aliases.size() != 1
          || !MessageDigest.isEqual(
              publicCertificate.getEncoded(), store.getCertificate(aliases.get(0)).getEncoded())) {
        throw new IllegalArgumentException();
      }
      Path root = Path.of(".local").toAbsolutePath();
      Files.createDirectories(root);
      signingDirectory = Files.createTempDirectory(root, "android-cleanup-https-signing-");
      Path candidate = signingDirectory.resolve("private.jwk");
      Files.writeString(
          candidate,
          new ECKeyGenerator(Curve.P_256).keyID("cleanup-https-test").generate().toJSONString());
      serverCertificate = publicDer;
      keyStoreUri = keyStore.toUri().toString();
      keyStoreAlias = aliases.get(0);
      signingKey = candidate;
    } catch (Exception failure) {
      // Provider and parser exceptions may contain key material or passwords.
      throw new IllegalStateException("Isolated cleanup HTTPS key fixtures unavailable");
    }
  }

  private static String tlsPassword() {
    return System.getProperty("device.cleanup.tls.password", TLS_FIXTURE_PASSWORD);
  }

  private static String requiredProperty(String name) {
    String value = System.getProperty(name);
    if (value == null || value.isBlank()) {
      throw new IllegalArgumentException("Required cleanup HTTPS test setting unavailable: " + name);
    }
    return value;
  }

  @AfterAll
  static void removePrivateSigningFixture() throws Exception {
    if (signingKey != null) Files.deleteIfExists(signingKey);
    if (signingDirectory != null) Files.deleteIfExists(signingDirectory);
  }

  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate database;
  @Autowired ObjectMapper mapper;
  @Autowired Clock clock;
  @LocalServerPort int port;
  @MockitoBean JwtDecoder decoder;

  private RequestPostProcessor adult(String owner) {
    return jwt()
        .jwt(
            token ->
                token
                    .subject(owner)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private JsonNode create(String route, String owner, Object input) throws Exception {
    return mapper.readTree(
        mvc.perform(
                post(route)
                    .with(adult(owner))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(mapper.writeValueAsString(input)))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  @Test
  void nativeOriginalKeyExecutesRealHttpsCleanupAndRetainsAcknowledgedJournal() throws Exception {
    assertThat(System.getProperty("device.cleanup.android.owned")).isEqualTo("true");
    when(decoder.decode(anyString())).thenThrow(new BadJwtException("Not an adult fixture JWT"));
    String owner = "cleanup-https-owner-" + UUID.randomUUID();
    String tenant =
        uuid(
            create(
                "/api/v1/tenants",
                owner,
                Map.of("name", "HTTPS 退出验收家庭", "kind", "FAMILY", "timeZone", "UTC")),
            "id");
    String root = "/api/v1/tenants/" + tenant;
    String subject =
        uuid(
            create(root + "/subjects", owner, Map.of("nickname", "合成儿童", "ageBand", "AGE_7_12")),
            "id");
    JsonNode ticket =
        create(
            root + "/enrollments",
            owner,
            Map.of("subjectId", subject, "platform", "ANDROID", "requestedMode", "BYOD"));
    String enrollment = uuid(ticket, "id");
    Path directory =
        Files.createTempDirectory(Path.of(".local").toAbsolutePath(), "android-cleanup-https-");
    Path fixtureFile = directory.resolve("fixture.json");
    Path pairingFile = directory.resolve("pairing.json");
    var fixture = new HashMap<String, Object>();
    fixture.put("schemaVersion", 1);
    fixture.put("runId", UUID.randomUUID().toString());
    fixture.put("tenantId", tenant);
    fixture.put("subjectId", subject);
    fixture.put("apiRoot", "https://127.0.0.1:" + port + "/api/v1");
    fixture.put("serverCertificateDerBase64", Base64.getEncoder().encodeToString(serverCertificate));
    try {
      run(fixtureFile, fixture, directory, "negative");
      assertTenantHasNoDeviceOrReceipts(tenant);
      fixture.put(
          "ticket",
          Map.of(
              "tenantId", tenant,
              "id", enrollment,
              "token", ticket.get("token").asText(),
              "expiresAt", ticket.get("expiresAt").asLong()));
      try {
        run(fixtureFile, fixture, directory, "enroll");
      } finally {
        fixture.remove("ticket");
        Files.deleteIfExists(fixtureFile);
      }
      JsonNode pairing;
      try {
        pairing = mapper.readTree(pairingFile.toFile());
      } finally {
        Files.deleteIfExists(pairingFile);
      }
      String device = uuid(pairing, "deviceId");
      String registration = uuid(pairing, "registrationId");
      assertThat(pairing.path("pairingCode").isTextual()).isTrue();
      assertThat(pairing.path("pairingCode").asText().matches("[A-Z0-9]{8}")).isTrue();
      fixture.put("deviceId", device);
      fixture.put("registrationId", registration);
      assertRegistration(tenant, device, registration, "AWAITING_CONFIRMATION");
      JsonNode storedPublicKey =
          mapper.readTree(
              database.queryForObject(
                  "SELECT public_key_jwk FROM devices WHERE tenant_id=? AND id=?",
                  String.class,
                  tenant,
                  device));
      assertThat("EC".equals(storedPublicKey.path("kty").asText())).isTrue();
      assertThat("P-256".equals(storedPublicKey.path("crv").asText())).isTrue();
      assertThat(storedPublicKey.has("d")).isFalse();
      assertThat(
              database.queryForObject(
                  "SELECT COUNT(*) FROM device_credentials WHERE tenant_id=? AND device_id=?"
                      + " AND registration_id=?",
                  Integer.class,
                  tenant,
                  device,
                  registration))
          .isEqualTo(1);
      mvc.perform(
              post(root + "/enrollments/" + enrollment + "/confirm")
                  .with(adult(owner))
                  .contentType(MediaType.APPLICATION_JSON)
                  .content(
                      mapper.writeValueAsString(
                          Map.of("pairingCode", pairing.get("pairingCode").asText()))))
          .andExpect(status().isOk());
      run(fixtureFile, fixture, directory, "active");
      assertRegistration(tenant, device, registration, "ACTIVE");
      assertThat(
              database.queryForObject(
                  "SELECT heartbeat_sequence FROM devices WHERE tenant_id=? AND id=?",
                  Long.class,
                  tenant,
                  device))
          .isEqualTo(1L);

      var deviceResponse =
          mvc.perform(get(root + "/devices/" + device).with(adult(owner)))
              .andExpect(status().isOk())
              .andReturn()
              .getResponse();
      String etag = deviceResponse.getHeader("ETag");
      assertThat(etag != null && etag.matches("\"(0|[1-9][0-9]*)\"")).isTrue();
      String deprovision = root + "/devices/" + device + "/deprovision";
      JsonNode preview =
          mapper.readTree(
              mvc.perform(
                      post(deprovision + "/previews")
                          .with(adult(owner))
                          .header("If-Match", etag)
                          .contentType(MediaType.APPLICATION_JSON)
                          .content("{\"action\":\"AGENT_UNENROLL\"}"))
                  .andExpect(status().isCreated())
                  .andReturn()
                  .getResponse()
                  .getContentAsString());
      JsonNode operation =
          mapper.readTree(
              mvc.perform(
                      post(deprovision + "/operations")
                          .with(adult(owner))
                          .header("If-Match", etag)
                          .header("Idempotency-Key", UUID.randomUUID().toString())
                          .contentType(MediaType.APPLICATION_JSON)
                          .content(
                              mapper.writeValueAsString(
                                  Map.of(
                                      "previewId", uuid(preview, "id"),
                                      "previewHash", preview.get("hash").asText()))))
                  .andExpect(status().isCreated())
                  .andReturn()
                  .getResponse()
                  .getContentAsString());
      String operationId = uuid(operation, "id");
      String commandId = uuid(operation, "commandId");
      assertThat(operation.path("state").asText()).isEqualTo("WAITING_FOR_AGENT");
      assertThat(operation.path("remoteAccess").asText()).isEqualTo("REVOKED");
      assertThat(operation.path("localEvidence").asText()).isEqualTo("NONE");
      String commandHash =
          database.queryForObject(
              "SELECT command_hash FROM deprovision_operations WHERE tenant_id=? AND id=?",
              String.class,
              tenant,
              operationId);
      assertThat(commandHash != null && commandHash.matches("[0-9a-f]{64}")).isTrue();
      assertThat(
              commandHash.equals(
                  SecretMaterial.hash(
                      database.queryForObject(
                          "SELECT compact_jws FROM deprovision_operations WHERE tenant_id=? AND id=?",
                          String.class,
                          tenant,
                          operationId))))
          .isTrue();
      fixture.put("operationId", operationId);
      fixture.put("commandHash", commandHash);
      assertRegistration(tenant, device, registration, "REVOKED");
      assertCredentialsRevoked(tenant, device, registration);
      assertThat(receiptCount(tenant, operationId)).isZero();

      run(fixtureFile, fixture, directory, "cleanup");
      JsonNode finalOperation =
          assertCleanupReported(
              tenant, device, registration, operationId, commandId, commandHash, operation);
      run(fixtureFile, fixture, directory, "verify");
      JsonNode afterRestart =
          assertCleanupReported(
              tenant, device, registration, operationId, commandId, commandHash, operation);
      assertThat(afterRestart).isEqualTo(finalOperation);
      Map<String, Object> nativeEvidence = assertNativePhases(directory);
      var summary = new LinkedHashMap<String, Object>();
      summary.put("schemaVersion", 1);
      summary.put("tenantId", tenant);
      summary.put("deviceId", device);
      summary.put("registrationId", registration);
      summary.put("operationId", operationId);
      summary.put("commandHash", commandHash);
      summary.put("state", finalOperation.path("state").asText());
      summary.put("remoteAccess", finalOperation.path("remoteAccess").asText());
      summary.put("localEvidence", finalOperation.path("localEvidence").asText());
      summary.put("receiptCount", receiptCount(tenant, operationId));
      summary.put("receiptStages", List.of("RECEIVED", "AGENT_DATA_CLEARED"));
      summary.put("credentialsRevoked", true);
      summary.put("realAndroidKey", true);
      summary.put("realTls", true);
      summary.put("untrustedCertificateRejectedInFourProcesses", true);
      summary.put("cloudResponsesAreReal", true);
      summary.put("adultIdentityIsFixture", true);
      summary.put("physicalWipeProven", false);
      summary.put("nativeEvidence", nativeEvidence);
      mapper.writeValue(directory.resolve("server-result.json").toFile(), summary);
      System.out.println("Android real HTTPS cleanup journey: PASS; own-agent cleanup reported");
    } finally {
      // Never reset the installation or retry a failed destructive phase to hide a failure.
      Files.deleteIfExists(fixtureFile);
      Files.deleteIfExists(pairingFile);
    }
  }

  private void assertTenantHasNoDeviceOrReceipts(String tenant) {
    for (String table : List.of("devices", "device_credentials", "cleanup_receipts")) {
      assertThat(
              database.queryForObject(
                  "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Integer.class, tenant))
          .isZero();
    }
  }

  private void assertRegistration(
      String tenant, String device, String registration, String expectedState) {
    assertThat(
            database.queryForObject(
                "SELECT COUNT(*) FROM devices WHERE tenant_id=? AND id=? AND registration_id=?"
                    + " AND state=?",
                Integer.class,
                tenant,
                device,
                registration,
                expectedState))
        .isEqualTo(1);
    assertThat(
            database.queryForObject(
                "SELECT COUNT(*) FROM devices WHERE tenant_id=?", Integer.class, tenant))
        .isEqualTo(1);
  }

  private void assertCredentialsRevoked(String tenant, String device, String registration) {
    assertThat(
            database.queryForObject(
                "SELECT COUNT(*) FROM device_credentials WHERE tenant_id=? AND device_id=?"
                    + " AND registration_id=? AND active=true",
                Integer.class,
                tenant,
                device,
                registration))
        .isZero();
    assertThat(
            database.queryForObject(
                "SELECT COUNT(*) FROM device_credentials WHERE tenant_id=? AND device_id=?"
                    + " AND registration_id=? AND active=false AND revoked_at IS NOT NULL",
                Integer.class,
                tenant,
                device,
                registration))
        .isEqualTo(1);
    assertThat(
            database.queryForObject(
                "SELECT COUNT(*) FROM device_credential_scopes WHERE tenant_id=? AND device_id=?"
                    + " AND registration_id=? AND active=false AND revoked_at IS NOT NULL",
                Integer.class,
                tenant,
                device,
                registration))
        .isEqualTo(1);
  }

  private int receiptCount(String tenant, String operation) {
    return database.queryForObject(
        "SELECT COUNT(*) FROM cleanup_receipts WHERE tenant_id=? AND operation_id=?",
        Integer.class,
        tenant,
        operation);
  }

  private JsonNode assertCleanupReported(
      String tenant,
      String device,
      String registration,
      String operationId,
      String commandId,
      String commandHash,
      JsonNode originalOperation)
      throws Exception {
    assertRegistration(tenant, device, registration, "REVOKED");
    assertCredentialsRevoked(tenant, device, registration);
    assertThat(receiptCount(tenant, operationId)).isEqualTo(2);
    var operations =
        database.queryForList(
            "SELECT command_hash,state,local_evidence,reason_code,served_at,absolute_not_after"
                + " FROM deprovision_operations WHERE tenant_id=? AND id=?",
            tenant,
            operationId);
    assertThat(operations).hasSize(1);
    Map<String, Object> persisted = operations.get(0);
    assertThat(persisted.get("command_hash")).isEqualTo(commandHash);
    assertThat(persisted.get("state")).isEqualTo("CLEANUP_REPORTED");
    assertThat(persisted.get("local_evidence")).isEqualTo("DEVICE_REPORT_UNVERIFIED");
    assertThat(persisted.get("reason_code")).isNull();
    assertThat(persisted.get("served_at")).isNotNull();
    assertThat(((Number) persisted.get("absolute_not_after")).longValue())
        .isEqualTo(originalOperation.path("notAfter").asLong());
    var stages = new HashSet<String>();
    var ids = new HashSet<String>();
    JsonNode finalResponse = null;
    for (var row :
        database.queryForList(
            "SELECT receipt_id,payload_hash,stage,response_json FROM cleanup_receipts"
                + " WHERE tenant_id=? AND operation_id=?",
            tenant,
            operationId)) {
      String id = (String) row.get("receipt_id");
      String stage = (String) row.get("stage");
      assertThat(id != null && id.matches("[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}")).isTrue();
      assertThat(ids.add(id)).isTrue();
      assertThat(stages.add(stage)).isTrue();
      assertThat(Set.of("RECEIVED", "AGENT_DATA_CLEARED").contains(stage)).isTrue();
      var expectedPayload = new ExpectedReceiptPayload(id, commandId, commandHash, stage, null);
      assertThat(
              SecretMaterial.hash(mapper.writeValueAsString(expectedPayload))
                  .equals(row.get("payload_hash")))
          .isTrue();
      JsonNode response = mapper.readTree((String) row.get("response_json"));
      assertThat(response.path("id").asText()).isEqualTo(operationId);
      assertThat(response.path("deviceId").asText()).isEqualTo(device);
      assertThat(response.path("registrationId").asText()).isEqualTo(registration);
      assertThat(response.path("commandId").asText()).isEqualTo(commandId);
      assertThat(response.path("action").asText()).isEqualTo("AGENT_UNENROLL");
      assertThat(response.path("remoteAccess").asText()).isEqualTo("REVOKED");
      assertThat(response.path("reasonCode").isNull()).isTrue();
      assertThat(response.path("notAfter").asLong())
          .isEqualTo(originalOperation.path("notAfter").asLong());
      if ("RECEIVED".equals(stage)) {
        assertThat(response.path("state").asText()).isEqualTo("COMMAND_RECEIVED");
        assertThat(response.path("localEvidence").asText()).isEqualTo("NONE");
      } else {
        assertThat(response.path("state").asText()).isEqualTo("CLEANUP_REPORTED");
        assertThat(response.path("localEvidence").asText()).isEqualTo("DEVICE_REPORT_UNVERIFIED");
        finalResponse = response;
      }
    }
    assertThat(stages).containsExactlyInAnyOrder("RECEIVED", "AGENT_DATA_CLEARED");
    assertThat(finalResponse).isNotNull();
    return finalResponse;
  }

  private record ExpectedReceiptPayload(
      String receiptId, String commandId, String commandHash, String stage, String reasonCode) {}

  private static String uuid(JsonNode node, String name) {
    String value = node.path(name).asText();
    assertThat(value.matches("[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}")).isTrue();
    return value;
  }

  private void run(Path file, Map<String, Object> input, Path directory, String phase)
      throws Exception {
    assertThat(PHASES.contains(phase)).isTrue();
    assertThat(input.containsKey("ticket")).isEqualTo("enroll".equals(phase));
    assertThat(input.containsKey("deviceId")).isEqualTo(!Set.of("negative", "enroll").contains(phase));
    assertThat(input.containsKey("registrationId"))
        .isEqualTo(!Set.of("negative", "enroll").contains(phase));
    assertThat(input.containsKey("operationId")).isEqualTo(Set.of("cleanup", "verify").contains(phase));
    assertThat(input.containsKey("commandHash")).isEqualTo(Set.of("cleanup", "verify").contains(phase));
    input.put("phase", phase);
    mapper.writeValue(file.toFile(), input);
    Path log = directory.resolve("host-" + phase + ".log");
    try {
      var command =
          new ArrayList<>(
              List.of(
                  requiredProperty("device.python.command"),
                  requiredProperty("device.cleanup.android.runner"),
                  "--fixture",
                  file.toString(),
                  "--phase",
                  phase,
                  "--app",
                  requiredProperty("device.child.package"),
                  "--apk",
                  requiredProperty("device.cleanup.apk"),
                  "--adb",
                  requiredProperty("device.adb.command"),
                  "--aapt",
                  requiredProperty("device.aapt.command"),
                  "--flutter",
                  requiredProperty("device.flutter.command"),
                  "--serial",
                  requiredProperty("device.android.serial"),
                  "--expected-avd",
                  requiredProperty("device.android.avd"),
                  "--allow-owned-debug-avd"));
      var process =
          new ProcessBuilder(command).redirectErrorStream(true).redirectOutput(log.toFile()).start();
      if (!process.waitFor(360, TimeUnit.SECONDS)) {
        var descendants = process.descendants().toList();
        for (int i = descendants.size() - 1; i >= 0; i--) descendants.get(i).destroyForcibly();
        process.destroyForcibly();
        process.waitFor(5, TimeUnit.SECONDS);
        throw new AssertionError("Owned cleanup HTTPS phase exceeded its deadline: " + phase);
      }
      assertThat(process.exitValue()).as("Cleanup HTTPS %s diagnostics: %s", phase, log).isZero();
      // The runner only emits PASS after correlating the actual process and private report.
      assertThat(Files.readString(log).contains("Android real HTTPS cleanup " + phase + ": PASS"))
          .isTrue();
    } finally {
      Files.deleteIfExists(file);
    }
  }

  private Map<String, Object> assertNativePhases(Path directory) throws Exception {
    JsonNode installation = null;
    String apkDigest = null;
    var pids = new HashSet<Integer>();
    var reports = new LinkedHashMap<String, Integer>();
    for (String phase : PHASES) {
      JsonNode report =
          mapper.readTree(directory.resolve("native-" + phase).resolve("host-result.json").toFile());
      assertThat(report.path("phase").asText()).isEqualTo(phase);
      assertThat(report.path("pid").isIntegralNumber()).isTrue();
      int nativePid = report.path("pid").asInt();
      assertThat(nativePid).isPositive();
      assertThat(pids.add(nativePid)).isTrue();
      reports.put(phase, nativePid);
      for (String field :
          List.of("nativePidVerified", "processStopped", "installPreserved", "driverAttachedExistingApp")) {
        booleanField(report, field, true);
      }
      JsonNode currentInstallation = report.path("installation");
      assertThat(currentInstallation.isObject()).isTrue();
      assertThat(currentInstallation.path("uid").asText().matches("[0-9]+")).isTrue();
      assertThat(currentInstallation.path("firstInstallTime").asText().isBlank()).isFalse();
      String currentDigest = report.path("apkSha256").asText();
      assertThat(currentDigest.matches("[0-9a-f]{64}")).isTrue();
      if (installation == null) {
        installation = currentInstallation;
        apkDigest = currentDigest;
      } else {
        assertThat(currentInstallation).isEqualTo(installation);
        assertThat(currentDigest).isEqualTo(apkDigest);
      }
      if ("negative".equals(phase)) {
        booleanField(report, "expectedMissingSeedFailure", true);
        continue;
      }
      assertThat(report.path("driverExitCode").asInt(-1)).isZero();
      for (String field :
          List.of(
              "realTls", "untrustedCertificateRejected", "realAndroidKey", "cloudResponsesAreReal",
              "adultIdentityIsFixture")) {
        booleanField(report, field, true);
      }
      booleanField(report, "physicalWipeProven", false);
      boolean cleaned = Set.of("cleanup", "verify").contains(phase);
      for (String field :
          List.of("cleanupCompleted", "journalRetained", "originalKeyDeleted", "cachesDeleted")) {
        booleanField(report, field, cleaned);
      }
    }
    return Map.of("phasePids", reports, "installation", installation, "apkSha256", apkDigest);
  }

  private static void booleanField(JsonNode report, String field, boolean expected) {
    assertThat(report.path(field).isBoolean()).as("Native report field %s", field).isTrue();
    assertThat(report.path(field).asBoolean()).as("Native report field %s", field).isEqualTo(expected);
  }
}
