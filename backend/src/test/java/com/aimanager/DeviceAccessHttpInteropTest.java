package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.signing.ConfigurationSigner;
import com.fasterxml.jackson.databind.*;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.*;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.*;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Real Spring HTTP, device opaque authentication, Nimbus and separate Dart processes with a durable
 * file journal. Adult JWT/MFA claims, activated device and baseline readiness are explicit test
 * fixtures, not real OTP/native proof.
 */
@EnabledIfSystemProperty(named = "device.access.package", matches = ".+")
@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "server.address=127.0.0.1",
      "spring.datasource.url=jdbc:h2:mem:accesshttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "manager.approval.expiry-job.enabled=false",
      "manager.quota.materialization-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false"
    })
@AutoConfigureMockMvc
@Import(DeviceAccessHttpInteropTest.TimeConfiguration.class)
class DeviceAccessHttpInteropTest {
  private static final Path DIRECTORY, KEY_FILE;

  static {
    try {
      Path root = Path.of(".local").toAbsolutePath();
      Files.createDirectories(root);
      DIRECTORY = Files.createTempDirectory(root, "access-http-");
      KEY_FILE = Files.createTempFile(DIRECTORY, "temporary-signing-", ".jwk");
      Files.writeString(
          KEY_FILE,
          new ECKeyGenerator(Curve.P_256).keyID("access-http-key").generate().toJSONString());
    } catch (Exception failure) {
      throw new IllegalStateException("Isolated signing fixture unavailable");
    }
  }

  @DynamicPropertySource
  static void signing(DynamicPropertyRegistry registry) {
    registry.add("manager.delivery.signing-key-file", () -> KEY_FILE.toString());
  }

  @AfterAll
  static void cleanup() throws Exception {
    Files.deleteIfExists(KEY_FILE);
    Files.deleteIfExists(DIRECTORY.resolve("fixture.json"));
  }

  @LocalServerPort int port;
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate db;
  @Autowired ConfigurationSigner signer;
  @Autowired DeviceCredentials credentials;
  @Autowired TransactionTemplate transactions;
  @Autowired TestClock clock;
  @MockitoBean JwtDecoder decoder;

  RequestPostProcessor actor(String id) {
    return jwt()
        .jwt(
            t ->
                t.subject(id)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  String create(String path, String actor, Object input) throws Exception {
    return mapper
        .readTree(
            mvc.perform(
                    post(path)
                        .with(actor(actor))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(mapper.writeValueAsString(input)))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
        .get("id")
        .asText();
  }

  Map<String, Object> grant(String tenant, String owner, String child, String device, int index)
      throws Exception {
    String root = "/api/v1/tenants/" + tenant;
    String app =
        create(
            root + "/applications",
            owner,
            Map.of(
                "displayName",
                "HTTP game " + index,
                "platform",
                "ANDROID",
                "packageName",
                "org.example.http" + index,
                "profile",
                "PRIMARY",
                "signingDigests",
                List.of("a".repeat(64))));
    String policy =
        create(
            root + "/policies",
            owner,
            Map.of(
                "name",
                "HTTP policy " + index,
                "kind",
                "POLICY",
                "rules",
                List.of(
                    Map.of(
                        "id",
                        "game",
                        "kind",
                        "APP_LAUNCH",
                        "effect",
                        "DENY",
                        "applicationId",
                        app,
                        "required",
                        true))));
    String path = root + "/policies/" + policy;
    var preview =
        mapper.readTree(
            mvc.perform(
                    post(path + "/previews")
                        .with(actor(owner))
                        .header("If-Match", "\"0\"")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(mapper.writeValueAsString(Map.of("deviceIds", List.of(device)))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    var published =
        mapper.readTree(
            mvc.perform(
                    post(path + "/publications")
                        .with(actor(owner))
                        .header("If-Match", "\"0\"")
                        .header("Idempotency-Key", UUID.randomUUID().toString())
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
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    String version = published.get("versionId").asText();
    var requested =
        mapper.readTree(
            mvc.perform(
                    post(root + "/access-requests")
                        .with(actor(child))
                        .header("Idempotency-Key", UUID.randomUUID().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            mapper.writeValueAsString(
                                Map.of(
                                    "deviceId",
                                    device,
                                    "policyId",
                                    policy,
                                    "baseVersionId",
                                    version,
                                    "applicationId",
                                    app,
                                    "ruleIds",
                                    List.of("game"),
                                    "requestedWindowSeconds",
                                    600,
                                    "reason",
                                    "HTTP fixture"))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    String request = requested.get("id").asText();
    mvc.perform(
            post(root + "/access-requests/" + request + "/decisions")
                .with(actor(owner))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", UUID.randomUUID().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":300}"))
        .andExpect(status().isOk());
    return Map.of(
        "requestId",
        request,
        "policyId",
        policy,
        "baseVersionId",
        version,
        "applicationId",
        app,
        "absoluteNotAfter",
        clock.millis() + 300000);
  }

  void runDart(Map<String, Object> fixture, String mode) throws Exception {
    fixture.put("nowMillis", clock.millis());
    Path file = DIRECTORY.resolve("fixture.json");
    mapper.writeValue(file.toFile(), fixture);
    Path output = DIRECTORY.resolve("dart-" + mode + ".log");
    Path packageRoot =
        Path.of(System.getProperty("device.access.package", "../packages/device_access"))
            .toAbsolutePath();
    var process =
        new ProcessBuilder(
                System.getProperty("device.dart.command"),
                "run",
                "tool/verify_http_fixture.dart",
                file.toString(),
                mode)
            .directory(packageRoot.toFile())
            .redirectErrorStream(true)
            .redirectOutput(output.toFile())
            .start();
    if (!process.waitFor(45, TimeUnit.SECONDS)) {
      process.destroyForcibly();
      process.waitFor(5, TimeUnit.SECONDS);
      throw new AssertionError("Dart access HTTP fixture exceeded bounded deadline");
    }
    assertThat(process.exitValue()).as("Dart diagnostics: %s", output).isZero();
    assertThat(Files.readString(output)).contains("PASS");
  }

  @Test
  void realApprovalRetryReceiptsRevocationExpiryAndOpaqueRevocation() throws Exception {
    when(decoder.decode(anyString())).thenThrow(new BadJwtException("No user token fixture"));
    String owner = "access-http-owner-" + UUID.randomUUID(),
        child = "access-http-child-" + UUID.randomUUID();
    String tenant =
        create(
            "/api/v1/tenants",
            owner,
            Map.of("name", "HTTP family", "kind", "FAMILY", "timeZone", "UTC"));
    String subject =
        create(
            "/api/v1/tenants/" + tenant + "/subjects",
            owner,
            Map.of("nickname", "HTTP child", "ageBand", "AGE_7_12"));
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    String device = UUID.randomUUID().toString(),
        registration = UUID.randomUUID().toString(),
        token = SecretMaterial.token();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,
        device,
        subject,
        registration,
        "HTTP device",
        clock.millis());
    db.update(
        "INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active)"
            + " VALUES(?,?,?,TRUE)",
        tenant,
        registration,
        device);
    db.update(
        "INSERT INTO"
            + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
            + " VALUES(?,?,?,?,?,TRUE,?,?)",
        UUID.randomUUID().toString(),
        tenant,
        device,
        registration,
        SecretMaterial.hash(token),
        clock.millis(),
        clock.millis() + 3600000);
    var grants =
        List.of(grant(tenant, owner, child, device, 1), grant(tenant, owner, child, device, 2));
    var fixture =
        new LinkedHashMap<String, Object>(
            Map.of(
                "apiRoot",
                "http://127.0.0.1:" + port + "/api/v1",
                "tenantId",
                tenant,
                "subjectId",
                subject,
                "deviceId",
                device,
                "registrationId",
                registration,
                "credential",
                token,
                "publicKeys",
                signer.publicKeys(),
                "grants",
                grants));
    runDart(fixture, "missing");
    assertThat(count("access_window_attempts", tenant, " AND delivery_state='REJECTED'"))
        .isEqualTo(2);
    clock.advance(30);
    runDart(fixture, "recover-unconfirmed");
    assertThat(count("access_window_documents", tenant, "")).isEqualTo(2);
    assertThat(count("access_window_attempts", tenant, "")).isEqualTo(4);
    assertThat(count("access_window_attempt_receipts", tenant, "")).isEqualTo(4);
    runDart(fixture, "resume");
    assertThat(count("access_window_attempt_receipts", tenant, "")).isEqualTo(4);
    mvc.perform(
            post("/api/v1/tenants/"
                    + tenant
                    + "/access-requests/"
                    + grants.get(0).get("requestId")
                    + "/revoke")
                .with(actor(owner))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", UUID.randomUUID().toString()))
        .andExpect(status().isOk());
    clock.advance(1);
    runDart(fixture, "revoked");
    assertThat(count("access_window_documents", tenant, " AND action='REMOVE_ACCESS_WINDOW'"))
        .isEqualTo(1);
    clock.advance(300);
    runDart(fixture, "expired");
    assertThat(count("access_window_documents", tenant, " AND action='REMOVE_ACCESS_WINDOW'"))
        .isEqualTo(2);
    transactions.executeWithoutResult(status -> credentials.revoke(tenant, registration));
    runDart(fixture, "unauthenticated");
  }

  int count(String table, String tenant, String suffix) {
    return db.queryForObject(
        "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?" + suffix, Integer.class, tenant);
  }

  @TestConfiguration
  static class TimeConfiguration {
    @Bean
    @Primary
    TestClock accessHttpClock() {
      return new TestClock();
    }
  }

  static class TestClock extends Clock {
    final AtomicReference<Instant> now =
        new AtomicReference<>(Instant.parse("2026-10-09T07:00:00Z"));

    void advance(long seconds) {
      now.updateAndGet(t -> t.plusSeconds(seconds));
    }

    @Override
    public ZoneId getZone() {
      return ZoneOffset.UTC;
    }

    @Override
    public Clock withZone(ZoneId zone) {
      return Clock.fixed(instant(), zone);
    }

    @Override
    public Instant instant() {
      return now.get();
    }
  }
}
