package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.shared.SecretMaterial;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.Jwt;

/** Uses existing domain fixtures; the native controller talks to actual loopback HTTP. */
@EnabledIfSystemProperty(named = "parent.dart.command", matches = ".+")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
    "server.address=127.0.0.1",
    "spring.datasource.url=jdbc:h2:mem:parentnotificationhttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.approval.expiry-job.enabled=false", "manager.quota.materialization-job.enabled=false",
    "manager.lifecycle.expiry-job.enabled=false", "manager.notifications.retention-job.enabled=false"})
class ParentNotificationHttpInteropTest extends NotificationJourneyTest {
  @LocalServerPort int port;

  @Test void productionClientRecoversReadAndFetchesCurrentRequest() throws Exception {
    var s = scope();
    var request = request(s, "notification-http-create");
    clock.advance(1);
    approve(s, request);
    clock.advance(1);
    postAs(s.requests() + "/" + request.path("id").asText() + "/revoke",
        s.owner(), null, "notification-http-revoke", 1L).andExpect(status().isOk());
    String token = SecretMaterial.token();
    when(decoder.decode(anyString())).thenAnswer(invocation -> {
      if (!token.equals(invocation.getArgument(0))) throw new BadJwtException("Not a fixture identity");
      return Jwt.withTokenValue(token).header("alg", "fixture").subject(s.owner())
          .issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(600)).build();
    });
    Path output = Path.of("target", "parent-notification-http.log").toAbsolutePath();
    var builder = new ProcessBuilder(System.getProperty("parent.dart.command"),
        Path.of(System.getProperty("parent.flutter.tool")).toAbsolutePath().toString(),
        "test", "--no-pub", "tool/verify_notification_http_test.dart")
        .directory(Path.of(System.getProperty("parent.package", "../apps/parent")).toAbsolutePath().toFile())
        .redirectErrorStream(true).redirectOutput(output.toFile());
    builder.environment().put("PARENT_NOTIFICATION_HTTP_FIXTURE", json.writeValueAsString(Map.of(
        "testOnly", true, "apiRoot", "http://127.0.0.1:" + port + "/api/v1", "tenantId", s.tenant(),
        "requestId", request.path("id").asText(), "token", token)));
    var process = builder.start();
    try {
      assertThat(process.waitFor(90, TimeUnit.SECONDS)).isTrue();
      assertThat(process.exitValue()).as("Flutter diagnostics: %s", output).isZero();
      assertThat(Files.readString(output)).contains("All tests passed!");
    } finally { if (process.isAlive()) process.destroyForcibly(); }
    assertThat(inbox(s, s.owner(), "?unreadOnly=true").path("items").size()).isZero();
    assertThat(inbox(s, s.child(), "?unreadOnly=true").path("items").size()).isEqualTo(3);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM notification_reads WHERE tenant_id=?",
        Integer.class, s.tenant())).isEqualTo(3);
  }

  @Test void productionDecisionClientRecoversWithoutResubmittingApproval() throws Exception {
    var s = scope();
    var request = request(s, "parent-decision-http");
    String token = SecretMaterial.token();
    when(decoder.decode(anyString())).thenAnswer(invocation -> {
      if (!token.equals(invocation.getArgument(0))) throw new BadJwtException("Not a fixture identity");
      return Jwt.withTokenValue(token).header("alg", "fixture").subject(s.owner())
          .claim("auth_time", clock.instant().getEpochSecond()).claim("amr", java.util.List.of("pwd", "otp"))
          .issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(600)).build();
    });
    Path output = Path.of("target", "parent-decision-http.log").toAbsolutePath();
    var builder = new ProcessBuilder(System.getProperty("parent.dart.command"),
        Path.of(System.getProperty("parent.flutter.tool")).toAbsolutePath().toString(),
        "test", "--no-pub", "tool/verify_decision_http_test.dart")
        .directory(Path.of(System.getProperty("parent.package", "../apps/parent")).toAbsolutePath().toFile())
        .redirectErrorStream(true).redirectOutput(output.toFile());
    builder.environment().put("PARENT_DECISION_HTTP_FIXTURE", json.writeValueAsString(Map.of(
        "testOnly", true, "apiRoot", "http://127.0.0.1:" + port + "/api/v1", "tenantId", s.tenant(),
        "actorId", s.owner(), "requestId", request.path("id").asText(), "token", token)));
    var process = builder.start();
    try {
      assertThat(process.waitFor(90, TimeUnit.SECONDS)).isTrue();
      assertThat(process.exitValue()).as("Flutter diagnostics: %s", output).isZero();
      assertThat(Files.readString(output)).contains("All tests passed!");
    } finally { if (process.isAlive()) process.destroyForcibly(); }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM access_request_decisions WHERE tenant_id=?",
        Integer.class, s.tenant())).isEqualTo(1);
    assertThat(db.queryForObject("SELECT granted_window_seconds FROM access_requests WHERE tenant_id=? AND id=?",
        Long.class, s.tenant(), request.path("id").asText())).isEqualTo(300L);
  }
}
