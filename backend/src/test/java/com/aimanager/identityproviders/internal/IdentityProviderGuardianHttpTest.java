package com.aimanager.identityproviders.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.JWEAlgorithm;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

/** Production Dart repository over actual HTTP/Flyway/H2; JWT and supplier inputs are fixtures. */
@EnabledIfSystemProperty(named="guardian.dart.command", matches=".+")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT, properties={
    "server.address=127.0.0.1",
    "spring.datasource.url=jdbc:h2:mem:identity-provider-http;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.identity-providers.environment-id=isolated-http",
    "manager.consumer-security.enabled=false"})
class IdentityProviderGuardianHttpTest {
  static final Path DIRECTORY = directory();
  static Path directory() {
    try {
      Path path=Files.createTempDirectory(Path.of(System.getProperty("java.io.tmpdir")), "provider-http-");
      byte[] random=new byte[32]; new java.security.SecureRandom().nextBytes(random);
      var key=new OctetSequenceKey.Builder(random).keyID("http-key").keyUse(KeyUse.ENCRYPTION).algorithm(JWEAlgorithm.DIR).build();
      Files.writeString(path.resolve("keyring.json"),new JWKSet(key).toString(false));
      Files.createDirectory(path.resolve("releases")); return path;
    } catch(Exception failure) { throw new ExceptionInInitializerError(failure); }
  }
  @DynamicPropertySource static void properties(DynamicPropertyRegistry properties) {
    properties.add("manager.identity-providers.key-file", ()->DIRECTORY.resolve("keyring.json").toString());
    properties.add("manager.identity-providers.release-directory", ()->DIRECTORY.resolve("releases").toString());
  }
  @LocalServerPort int port;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;

  @Test void productionDartReadsWritesRecoversAndKeepsRealAcceptancePending() throws Exception {
    String admin="provider-admin-"+UUID.randomUUID(),weak="provider-weak-"+UUID.randomUUID(),family="provider-family-"+UUID.randomUUID();
    when(decoder.decode(anyString())).thenAnswer(invocation->{
      String bearer=invocation.getArgument(0);
      if(!Set.of(admin,weak,family).contains(bearer)) throw new BadJwtException("Not an explicit fixture identity");
      boolean isFamily=family.equals(bearer),isWeak=weak.equals(bearer);Instant now=Instant.now();
      return Jwt.withTokenValue(bearer).header("alg","fixture").subject(isFamily?"family-fixture":"platform-fixture")
          .issuedAt(now).expiresAt(now.plusSeconds(300)).claim("auth_time",now.getEpochSecond())
          .claim("amr",isWeak?List.of("pwd"):List.of("pwd","otp"))
          .claim("scope",isFamily?"tenant:create":"identity-config:read identity-config:manage identity-config:test").build();
    });
    Path guardian=Path.of(System.getProperty("guardian.package","../apps/guardian")).toAbsolutePath();
    Path output=Path.of("target/identity-provider-guardian-http.log").toAbsolutePath();
    var builder=new ProcessBuilder(System.getProperty("guardian.dart.command"),
        "--packages="+guardian.resolve(".dart_tool/package_config.json"),
        guardian.resolve("tool/verify_identity_provider_http.dart").toString())
        .directory(guardian.toFile()).redirectErrorStream(true).redirectOutput(output.toFile());
    builder.environment().put("IDENTITY_PROVIDER_HTTP_FIXTURE",json.writeValueAsString(Map.of(
        "testOnly",true,"apiRoot","http://127.0.0.1:"+port+"/api/v1",
        "adminBearer",admin,"weakBearer",weak,"familyBearer",family)));
    var process=builder.start();
    try {
      assertThat(process.waitFor(90,TimeUnit.SECONDS)).as("Bounded production Dart HTTP check").isTrue();
      assertThat(process.exitValue()).as("See private HTTP diagnostic log: %s",output).isZero();
      assertThat(Files.readString(output)).contains("Provider administrator production HTTP checks passed: 22");
    } finally {
      if(process.isAlive()) {process.destroyForcibly();assertThat(process.waitFor(10,TimeUnit.SECONDS)).isTrue();}
    }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_versions",Integer.class)).isEqualTo(3);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_acceptance_runs",Integer.class)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_release_preparations WHERE status='PREPARED'",Integer.class)).isEqualTo(1);
    String audits=String.join("",db.queryForList("SELECT result_code FROM identity_provider_audit_events",String.class));
    assertThat(audits).doesNotContain("ProviderFixtureSecret123456789","abcdef0123456789abcdef0123456789");
  }
}
