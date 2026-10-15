package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.SecretMaterial;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.Jwt;

/** Runs the production Dart repository against a loopback server and fixture identities.
 * The inherited cases also verify roles, revocation, stable ties and tenant-bound cursors.
 */
@EnabledIfSystemProperty(named = "parent.dart.command", matches = ".+")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
    "spring.datasource.url=jdbc:h2:mem:parentaudithttp;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.exports.worker.enabled=false", "manager.notifications.retention-job.enabled=false",
    "server.address=127.0.0.1"
})
class ParentAuditHttpInteropTest extends AuditExplorerTest {
  @LocalServerPort int port;

  @Test
  void mobileReaderUsesRealPaginationFiltersAndAuthorization() throws Exception {
    String token = SecretMaterial.token(), childToken = SecretMaterial.token();
    String child = "audit-child-" + UUID.randomUUID();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'CHILD')",
        tenant, child, ActorKeys.key(child));
    long from = START + 1000;
    for (int n = 0; n < 21; n++) row(UUID.randomUUID().toString(), from + n, "SUBJECT_CREATED");
    when(decoder.decode(org.mockito.ArgumentMatchers.anyString())).thenAnswer(call -> {
      String supplied = call.getArgument(0);
      if (!token.equals(supplied) && !childToken.equals(supplied)) throw new BadJwtException("Not a fixture");
      return Jwt.withTokenValue(supplied).header("alg", "fixture")
          .subject(token.equals(supplied) ? owner : child)
          .issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(600)).build();
    });
    var count = db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=?", Integer.class, tenant);
    Path output = Path.of("target", "parent-audit-http.log").toAbsolutePath();
    var builder = new ProcessBuilder(System.getProperty("parent.dart.command"),
        System.getProperty("parent.flutter.tool"), "test", "--no-pub", "tool/verify_audit_http_test.dart")
        .directory(Path.of(System.getProperty("parent.package", "../apps/parent")).toAbsolutePath().toFile())
        .redirectErrorStream(true).redirectOutput(output.toFile());
    builder.environment().put("PARENT_AUDIT_HTTP_FIXTURE", mapper.writeValueAsString(Map.of(
        "testOnly", true, "apiRoot", "http://127.0.0.1:" + port + "/api/v1",
        "tenant", tenant, "otherTenant", UUID.randomUUID().toString(), "actor", owner,
        "token", token, "childToken", childToken, "from", from, "resource", RESOURCE, "trace", TRACE)));
    var process = builder.start();
    try {
      assertThat(process.waitFor(90, TimeUnit.SECONDS)).isTrue();
      assertThat(process.exitValue()).as("Flutter diagnostics: %s", output).isZero();
      assertThat(Files.readString(output)).contains("All tests passed!");
    } finally {
      if (process.isAlive()) process.destroyForcibly();
    }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=?", Integer.class, tenant))
        .isEqualTo(count);
  }
}
