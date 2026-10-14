package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.ObjectMapper;
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

/**
 * Production guardian controller and gateway against actual loopback Spring HTTP.
 * H2/Flyway, adult JWT issuance/MFA claims, and the claimed-device prerequisite
 * are explicit fixtures; this is not real IdP/MFA, browser storage, or device proof acceptance.
 */
@EnabledIfSystemProperty(named = "guardian.dart.command", matches = ".+")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
    "server.address=127.0.0.1",
    "spring.datasource.url=jdbc:h2:mem:guardianenrollmenthttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.approval.expiry-job.enabled=false", "manager.quota.materialization-job.enabled=false",
    "manager.lifecycle.expiry-job.enabled=false", "manager.notifications.retention-job.enabled=false"
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class GuardianEnrollmentRecoveryHttpInteropTest {
  @LocalServerPort int port;
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;

  private String create(String path, String actor, Map<String, Object> input) throws Exception {
    var response = mvc.perform(post(path).with(jwt().jwt(token -> token.subject(actor)
            .claim("auth_time", Instant.now().getEpochSecond())
            .claim("amr", List.of("pwd", "otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create")))
        .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(input)))
        .andExpect(status().isCreated()).andReturn().getResponse();
    return mapper.readTree(response.getContentAsString()).path("id").asText();
  }

  @Test void lostCreationRecoversWithoutSecretReplayAndFailedConfirmationCommitsItsCount()
      throws Exception {
    String owner = "guardian-http-owner-" + UUID.randomUUID();
    String otherAdult = "guardian-http-other-" + UUID.randomUUID();
    String token = SecretMaterial.token(), otherToken = SecretMaterial.token();
    when(decoder.decode(anyString())).thenAnswer(invocation -> {
      String supplied = invocation.getArgument(0), actor;
      if (token.equals(supplied)) actor = owner;
      else if (otherToken.equals(supplied)) actor = otherAdult;
      else throw new BadJwtException("Not a fixture identity");
      return Jwt.withTokenValue(supplied).header("alg", "fixture").subject(actor)
          .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp"))
          .issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(600)).build();
    });
    String tenant = create("/api/v1/tenants", owner,
        Map.of("name", "Guardian enrollment HTTP fixture", "kind", "FAMILY", "timeZone", "UTC"));
    String subject = create("/api/v1/tenants/" + tenant + "/subjects", owner,
        Map.of("nickname", "Fixture child", "ageBand", "AGE_7_12"));
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",
        tenant, otherAdult, ActorKeys.key(otherAdult));

    String creationId = UUID.randomUUID().toString(), claimedId = UUID.randomUUID().toString();
    String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
    long now = System.currentTimeMillis();
    db.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,"
            + "os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','AWAITING_CONFIRMATION','{}','fixture',?)",
        tenant, device, subject, registration, "Claimed prerequisite fixture", now);
    db.update("INSERT INTO device_enrollments(tenant_id,id,subject_id,creator_actor_id,platform,"
            + "requested_mode,token_hash,state,created_at,expires_at,device_id,pairing_hash) "
            + "VALUES(?,?,?,?,'ANDROID','BYOD',?,'AWAITING_CONFIRMATION',?,?,?,?)",
        tenant, claimedId, subject, owner, SecretMaterial.hash(SecretMaterial.token()),
        now, now + 900_000, device, SecretMaterial.hash("A1B2C3D4"));

    var fixture = new LinkedHashMap<String, Object>();
    fixture.put("testOnly", true);
    fixture.put("apiRoot", "http://127.0.0.1:" + port + "/api/v1");
    fixture.put("tenantId", tenant);
    fixture.put("actorId", owner);
    fixture.put("otherActorId", otherAdult);
    fixture.put("subjectId", subject);
    fixture.put("creationId", creationId);
    fixture.put("claimedId", claimedId);
    fixture.put("deviceId", device);
    fixture.put("createdAt", now);
    fixture.put("token", token);
    fixture.put("otherToken", otherToken);

    String flutterTool = System.getProperty("guardian.flutter.tool");
    assertThat(flutterTool).as("Configure the Flutter tools snapshot for the guardian HTTP gate")
        .isNotBlank();
    Path output = Path.of("target", "guardian-enrollment-http.log").toAbsolutePath();
    var builder = new ProcessBuilder(System.getProperty("guardian.dart.command"),
        Path.of(flutterTool).toAbsolutePath().toString(), "test", "--no-pub",
        "tool/verify_enrollment_http_test.dart")
        .directory(Path.of(System.getProperty("guardian.package", "../apps/guardian"))
            .toAbsolutePath().toFile())
        .redirectErrorStream(true).redirectOutput(output.toFile());
    // Fixture credentials travel only in the child environment, never command arguments or files.
    builder.environment().put("GUARDIAN_ENROLLMENT_HTTP_FIXTURE", mapper.writeValueAsString(fixture));
    var process = builder.start();
    try {
      assertThat(process.waitFor(120, TimeUnit.SECONDS)).as("Bounded guardian HTTP fixture")
          .isTrue();
      assertThat(process.exitValue()).as("Guardian Flutter HTTP diagnostics: %s", output).isZero();
      assertThat(Files.readString(output)).contains("All tests passed!");
    } finally {
      if (process.isAlive()) {
        process.destroyForcibly();
        assertThat(process.waitFor(10, TimeUnit.SECONDS))
            .as("Terminated guardian HTTP fixture process").isTrue();
      }
    }

    assertThat(db.queryForObject("SELECT COUNT(*) FROM device_enrollments WHERE tenant_id=?",
        Integer.class, tenant)).isEqualTo(2);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM device_enrollments WHERE tenant_id=? AND id=?",
        Integer.class, tenant, creationId)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT state FROM device_enrollments WHERE tenant_id=? AND id=?",
        String.class, tenant, creationId)).isEqualTo("CANCELLED");
    assertThat(db.queryForObject("SELECT creator_actor_id FROM device_enrollments WHERE tenant_id=? AND id=?",
        String.class, tenant, creationId)).isEqualTo(owner);
    assertThat(db.queryForObject("SELECT pairing_failures FROM device_enrollments WHERE tenant_id=? AND id=?",
        Integer.class, tenant, claimedId)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT state FROM device_enrollments WHERE tenant_id=? AND id=?",
        String.class, tenant, claimedId)).isEqualTo("AWAITING_CONFIRMATION");
    assertThat(db.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?",
        String.class, tenant, device)).isEqualTo("AWAITING_CONFIRMATION");
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='ENROLLMENT_CREATED'",
        Integer.class, tenant)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='ENROLLMENT_CANCELLED'",
        Integer.class, tenant)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='DEVICE_CONFIRMED'",
        Integer.class, tenant)).isZero();
  }
}
