package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
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

/** Real loopback Spring/Flutter client; H2, JWT identity/MFA and mobile storage remain explicit fixtures. */
@EnabledIfSystemProperty(named = "parent.dart.command", matches = ".+")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
    "server.address=127.0.0.1", "spring.datasource.url=jdbc:h2:mem:parentacceptancehttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "spring.datasource.username=sa", "spring.datasource.password="})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ParentAcceptanceHttpInteropTest {
  @LocalServerPort int port;
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  @Test void productionRecipientDistinguishesAcceptedRevokedAndRejoinedMembership() throws Exception {
    String actor = "parent-invitation-" + UUID.randomUUID(), token = SecretMaterial.token();
    String recipient = "recipient-" + UUID.randomUUID(), recipientToken = SecretMaterial.token(), recipientEmail = recipient + "@example.test";
    when(decoder.decode(anyString())).thenAnswer(invocation -> {
      String supplied = invocation.getArgument(0);
      if (!token.equals(supplied) && !recipientToken.equals(supplied)) throw new BadJwtException("Not a fixture identity");
      return Jwt.withTokenValue(supplied).header("alg", "fixture").subject(token.equals(supplied) ? actor : recipient)
          .claim("scope", "tenant:create").claim("email_verified", true).claim("email", recipientEmail)
          .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp"))
          .issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(600)).build();
    });
    String tenant = json.readTree(mvc.perform(post("/api/v1/tenants")
        .with(jwt().jwt(t -> t.subject(actor).claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create")))
        .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"Invitation HTTP fixture\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
    Path output = Path.of("target", "parent-acceptance-http.log").toAbsolutePath();
    var builder = new ProcessBuilder(System.getProperty("parent.dart.command"),
        Path.of(System.getProperty("parent.flutter.tool")).toAbsolutePath().toString(),
        "test", "--no-pub", "tool/verify_acceptance_http_test.dart")
        .directory(Path.of(System.getProperty("parent.package", "../apps/parent")).toAbsolutePath().toFile())
        .redirectErrorStream(true).redirectOutput(output.toFile());
    builder.environment().put("PARENT_ACCEPTANCE_HTTP_FIXTURE", json.writeValueAsString(Map.of(
        "testOnly", true, "apiRoot", "http://127.0.0.1:" + port + "/api/v1", "tenantId", tenant, "actorId", actor, "token", token, "recipientToken", recipientToken, "recipientEmail", recipientEmail, "recipientActor", recipient)));
    var process = builder.start();
    try {
      assertThat(process.waitFor(90, TimeUnit.SECONDS)).isTrue();
      assertThat(process.exitValue()).as("Flutter diagnostics: %s", output).isZero();
      assertThat(Files.readString(output)).contains("All tests passed!");
    } finally { if (process.isAlive()) process.destroyForcibly(); }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM member_invitations WHERE tenant_id=? AND consumed_at IS NOT NULL", Integer.class, tenant)).isEqualTo(2);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND actor_id=? AND revoked_at IS NULL", Integer.class, tenant, recipient)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT version FROM tenant_members WHERE tenant_id=? AND actor_id=?", Long.class, tenant, recipient)).isEqualTo(2L);
    assertThat(db.queryForObject("SELECT role FROM tenant_members WHERE tenant_id=? AND actor_id=?", String.class, tenant, recipient)).isEqualTo("AUDITOR");
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='MEMBER_JOINED'", Integer.class, tenant)).isEqualTo(2);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='MEMBERSHIP_REVOKED'", Integer.class, tenant)).isEqualTo(1);
  }
}
