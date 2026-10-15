package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

import com.aimanager.shared.SecretMaterial;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.Jwt;

/** Uses production Dart transport/controller and real encrypted artifact generation.
 * Identity and local durable storage remain explicit test fixtures. */
@EnabledIfSystemProperty(named="parent.dart.command",matches=".+")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT, properties={
  "spring.datasource.url=jdbc:h2:mem:parentexporthttp;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
  "spring.datasource.username=sa","spring.datasource.password=","server.address=127.0.0.1",
  "manager.exports.worker.enabled=false","manager.notifications.retention-job.enabled=false"
})
class ParentAuditExportHttpInteropTest extends AuditExportJourneyTest {
  @LocalServerPort int port;
  @Test void productionMobileExportFlow() throws Exception {
    clock.value.set(System.currentTimeMillis());
    String token=SecretMaterial.token();
    when(decoder.decode(org.mockito.ArgumentMatchers.anyString())).thenAnswer(call->{
      if(!token.equals(call.getArgument(0)))throw new BadJwtException("Not a fixture");
      return Jwt.withTokenValue(token).header("alg","fixture").subject(owner)
        .claim("auth_time",clock.instant().getEpochSecond()).claim("amr",List.of("pwd","otp"))
        .issuedAt(clock.instant()).expiresAt(clock.instant().plusSeconds(600)).build();
    });
    Path output=Path.of("target","parent-audit-export-http.log").toAbsolutePath();
    var builder=new ProcessBuilder(System.getProperty("parent.dart.command"),System.getProperty("parent.flutter.tool"),
      "test","--no-pub","tool/verify_audit_export_http_test.dart")
      .directory(Path.of(System.getProperty("parent.package","../apps/parent")).toAbsolutePath().toFile())
      .redirectErrorStream(true).redirectOutput(output.toFile());
    builder.environment().put("PARENT_EXPORT_HTTP_FIXTURE",json.writeValueAsString(Map.of(
      "testOnly",true,"apiRoot","http://127.0.0.1:"+port+"/api/v1","token",token,
      "tenant",tenant,"actor",owner,"from",NOW-60000,"to",NOW,"resource",RESOURCE)));
    var process=builder.start();
    try {
      long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(90);
      while(!process.waitFor(500,TimeUnit.MILLISECONDS)&&System.nanoTime()<deadline)maintenance.runBatch(25);
      assertThat(process.isAlive()).as("Flutter completion before timeout").isFalse();
      assertThat(process.exitValue()).as("Flutter diagnostics: %s",output).isZero();
      assertThat(Files.readString(output)).contains("All tests passed!");
    } finally {if(process.isAlive())process.destroyForcibly();}
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_exports WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='AUDIT_EXPORT_REQUESTED'",Integer.class,tenant)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='AUDIT_EXPORT_DOWNLOADED'",Integer.class,tenant)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT artifact FROM audit_exports WHERE tenant_id=?",String.class,tenant)).isNull();
  }
}
