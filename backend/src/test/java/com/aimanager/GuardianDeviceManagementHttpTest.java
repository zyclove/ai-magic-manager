package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
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
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Production guardian DTOs/repository/controller against actual loopback Spring HTTP and H2/Flyway.
 * Adult JWT issuance/MFA claims and activated registrations are explicit test fixtures. Heartbeats,
 * inventory authorization/reporting and revocation use production services. This is not real
 * IdP/OTP, browser/session lifecycle, MySQL runtime, or Android proof/execution acceptance.
 */
@EnabledIfSystemProperty(named = "guardian.dart.command", matches = ".+")
@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "server.address=127.0.0.1",
      "spring.datasource.url=jdbc:h2:mem:guardiandevicemanagementhttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "manager.approval.expiry-job.enabled=false",
      "manager.quota.materialization-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false",
      "manager.notifications.retention-job.enabled=false"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class GuardianDeviceManagementHttpTest {
  @LocalServerPort int port;
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate db;
  @Autowired DeviceCredentials credentials;
  @Autowired TransactionTemplate transactions;
  @MockitoBean JwtDecoder decoder;

  private RequestPostProcessor adult(String actor) {
    return jwt()
        .jwt(
            value ->
                value
                    .subject(actor)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private String create(String path, String actor, Map<String, Object> input) throws Exception {
    var response =
        mvc.perform(
                post(path)
                    .with(adult(actor))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(mapper.writeValueAsString(input)))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse();
    return mapper.readTree(response.getContentAsString()).path("id").asText();
  }

  private RegisteredDevice registeredDevice(String tenant, String subject, String name)
      throws Exception {
    String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
    var key = new ECKeyGenerator(Curve.P_256).generate().toPublicJWK();
    db.update(
        "INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,"
            + "os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE',?,?,?)",
        tenant,
        device,
        subject,
        registration,
        name,
        key.toJSONString(),
        key.computeThumbprint().toString(),
        System.currentTimeMillis());
    // The registration prerequisite is explicit; credential creation/activation remain real.
    String token =
        transactions.execute(
            ignored -> {
              var issued = credentials.issuePending(tenant, device, registration);
              credentials.activate(tenant, registration);
              return issued.credential();
            });
    assertThat(token).as("Issued fixture device credential").isNotBlank();
    return new RegisteredDevice(device, registration, token);
  }

  private void reportObservations(String tenant, String owner, RegisteredDevice device)
      throws Exception {
    mvc.perform(
            post("/api/v1/device-api/heartbeats")
                .header("Authorization", "Bearer " + device.token())
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    mapper.writeValueAsString(
                        Map.of(
                            "sequence", 1,
                            "agentVersion", "management-http-fixture",
                            "capabilities",
                                List.of(
                                    Map.of(
                                        "key", "usage.report",
                                        "reportedSupported", true,
                                        "grantStatus", "GRANTED"),
                                    Map.of(
                                        "key", "managed.app_policy",
                                        "reportedSupported", true,
                                        "grantStatus", "GRANTED"))))))
        .andExpect(status().isOk());
    mvc.perform(
            put("/api/v1/tenants/" + tenant + "/devices/" + device.id()
                    + "/observation-settings")
                .with(adult(owner))
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    mapper.writeValueAsString(
                        Map.of(
                            "inventoryEnabled", true,
                            "usageEnabled", false,
                            "reason", "Fixture authorizes limited inventory observations"))))
        .andExpect(status().isOk());
    mvc.perform(
            post("/api/v1/device-api/application-inventory")
                .header("Authorization", "Bearer " + device.token())
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    mapper.writeValueAsString(
                        Map.of(
                            "sequence", 1,
                            "authorizationVersion", 1,
                            "visibility", "VISIBLE_PACKAGES",
                            "applications",
                                List.of(
                                    Map.of(
                                        "packageName", "org.example.management",
                                        "displayName", "Management HTTP fixture app",
                                        "profile", "PRIMARY",
                                        "signingDigests", List.of("a".repeat(64)),
                                        "versionCode", 3,
                                        "systemApplication", false))))))
        .andExpect(status().isOk());
  }

  private long version(String tenant, RegisteredDevice device) {
    return db.queryForObject(
        "SELECT version FROM devices WHERE tenant_id=? AND id=?", Long.class, tenant, device.id());
  }

  private void verifyRevokeFacts(
      String tenant, String owner, RegisteredDevice device, long before, boolean revoked)
      throws Exception {
    assertThat(
            db.queryForObject(
                "SELECT state FROM devices WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                device.id()))
        .isEqualTo(revoked ? "REVOKED" : "ACTIVE");
    assertThat(version(tenant, device)).isEqualTo(before + (revoked ? 1 : 0));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM device_credentials WHERE tenant_id=? AND device_id=? "
                    + "AND registration_id=? AND active=TRUE AND revoked_at IS NULL",
                Integer.class,
                tenant,
                device.id(),
                device.registration()))
        .isEqualTo(revoked ? 0 : 1);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM device_credential_scopes WHERE tenant_id=? AND device_id=? "
                    + "AND registration_id=? AND active=TRUE AND revoked_at IS NULL",
                Integer.class,
                tenant,
                device.id(),
                device.registration()))
        .isEqualTo(revoked ? 0 : 1);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND resource_id=? "
                    + "AND action='DEVICE_CREDENTIALS_REVOKED'",
                Integer.class,
                tenant,
                device.id()))
        .isEqualTo(revoked ? 1 : 0);
    if (revoked) {
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM device_credentials WHERE tenant_id=? AND device_id=? "
                      + "AND registration_id=? AND active=FALSE AND revoked_at IS NOT NULL",
                  Integer.class,
                  tenant,
                  device.id(),
                  device.registration()))
          .isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM device_credential_scopes WHERE tenant_id=? AND device_id=? "
                      + "AND registration_id=? AND active=FALSE AND revoked_at IS NOT NULL",
                  Integer.class,
                  tenant,
                  device.id(),
                  device.registration()))
          .isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT actor_id FROM audit_events WHERE tenant_id=? AND resource_id=? "
                      + "AND action='DEVICE_CREDENTIALS_REVOKED'",
                  String.class,
                  tenant,
                  device.id()))
          .isEqualTo(owner);
      // A real request with the previously active opaque credential now fails authentication.
      mvc.perform(
              post("/api/v1/device-api/heartbeats")
                  .header("Authorization", "Bearer " + device.token())
                  .contentType(MediaType.APPLICATION_JSON)
                  .content("{\"sequence\":2,\"agentVersion\":\"revoked-fixture\",\"capabilities\":[]}"))
          .andExpect(status().isUnauthorized());
    }
  }

  @Test
  void dartReadsRealContractsAndRecoversCommittedRevokeWithoutReplay() throws Exception {
    String owner = "guardian-management-owner-" + UUID.randomUUID();
    String outsider = "guardian-management-outsider-" + UUID.randomUUID();
    String ownerToken = SecretMaterial.token(), weakToken = SecretMaterial.token();
    String outsiderToken = SecretMaterial.token(), invalidToken = SecretMaterial.token();
    when(decoder.decode(anyString()))
        .thenAnswer(
            invocation -> {
              String supplied = invocation.getArgument(0), actor;
              boolean weak;
              if (ownerToken.equals(supplied)) {
                actor = owner;
                weak = false;
              } else if (weakToken.equals(supplied)) {
                actor = owner;
                weak = true;
              } else if (outsiderToken.equals(supplied)) {
                actor = outsider;
                weak = false;
              } else {
                throw new BadJwtException("Not a management fixture identity");
              }
              return Jwt.withTokenValue(supplied)
                  .header("alg", "fixture")
                  .subject(actor)
                  .claim("auth_time", Instant.now().getEpochSecond())
                  .claim("amr", weak ? List.of("pwd") : List.of("pwd", "otp"))
                  .issuedAt(Instant.now())
                  .expiresAt(Instant.now().plusSeconds(600))
                  .build();
            });
    String tenant =
        create(
            "/api/v1/tenants", owner,
            Map.of("name", "Guardian management HTTP fixture", "kind", "FAMILY", "timeZone", "UTC"));
    String subject =
        create(
            "/api/v1/tenants/" + tenant + "/subjects", owner,
            Map.of("nickname", "Fixture child", "ageBand", "AGE_7_12"));
    var read = registeredDevice(tenant, subject, "Readable fixture device");
    var direct = registeredDevice(tenant, subject, "Direct revoke fixture device");
    var lost = registeredDevice(tenant, subject, "Lost reply fixture device");
    reportObservations(tenant, owner, read);
    long readVersion = version(tenant, read), directVersion = version(tenant, direct);
    long lostVersion = version(tenant, lost);

    var fixture = new LinkedHashMap<String, Object>();
    fixture.put("testOnly", true);
    fixture.put("apiRoot", "http://127.0.0.1:" + port + "/api/v1");
    fixture.put("actorId", owner);
    fixture.put("tenantId", tenant);
    fixture.put("subjectId", subject);
    fixture.put("readDeviceId", read.id());
    fixture.put("readRegistrationId", read.registration());
    fixture.put("readVersion", readVersion);
    fixture.put("directDeviceId", direct.id());
    fixture.put("directVersion", directVersion);
    fixture.put("lostDeviceId", lost.id());
    fixture.put("lostRegistrationId", lost.registration());
    fixture.put("lostVersion", lostVersion);
    fixture.put("ownerToken", ownerToken);
    fixture.put("weakToken", weakToken);
    fixture.put("outsiderToken", outsiderToken);
    fixture.put("invalidToken", invalidToken);

    String flutterTool = System.getProperty("guardian.flutter.tool");
    assertThat(flutterTool).as("Configure the Flutter tools snapshot for the guardian HTTP gate")
        .isNotBlank();
    Path output = Path.of("target", "guardian-device-management-http.log").toAbsolutePath();
    var builder =
        new ProcessBuilder(
                System.getProperty("guardian.dart.command"),
                Path.of(flutterTool).toAbsolutePath().toString(),
                "test", "--no-pub", "tool/verify_device_management_http_test.dart")
            .directory(
                Path.of(System.getProperty("guardian.package", "../apps/guardian"))
                    .toAbsolutePath().toFile())
            .redirectErrorStream(true)
            .redirectOutput(output.toFile());
    // Fixture bearer material is passed only in the child environment, never arguments/files.
    builder.environment()
        .put("GUARDIAN_DEVICE_MANAGEMENT_HTTP_FIXTURE", mapper.writeValueAsString(fixture));
    var process = builder.start();
    try {
      assertThat(process.waitFor(180, TimeUnit.SECONDS)).as("Bounded guardian management HTTP gate")
          .isTrue();
      assertThat(process.exitValue()).as("Guardian management HTTP diagnostics: %s", output).isZero();
      assertThat(Files.readString(output)).contains("All tests passed!");
    } finally {
      if (process.isAlive()) {
        process.destroyForcibly();
        assertThat(process.waitFor(10, TimeUnit.SECONDS)).as("Terminated guardian HTTP fixture")
            .isTrue();
      }
    }

    verifyRevokeFacts(tenant, owner, read, readVersion, false);
    verifyRevokeFacts(tenant, owner, direct, directVersion, true);
    verifyRevokeFacts(tenant, owner, lost, lostVersion, true);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? "
                    + "AND action='DEVICE_CREDENTIALS_REVOKED'", Integer.class, tenant))
        .isEqualTo(2);
  }

  private record RegisteredDevice(String id, String registration, String token) {}
}
