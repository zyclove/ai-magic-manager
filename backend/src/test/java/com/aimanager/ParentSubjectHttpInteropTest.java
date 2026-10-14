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

/** 实际手机控制器与 Spring 回环 HTTP；身份、手机存储和重新验证为显式测试夹具。 */
@EnabledIfSystemProperty(named = "parent.dart.command", matches = ".+")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
    "server.address=127.0.0.1", "spring.datasource.url=jdbc:h2:mem:parentsubjecthttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "spring.datasource.username=sa", "spring.datasource.password="})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ParentSubjectHttpInteropTest {
  @LocalServerPort int port;
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  @Test void fullManagementFlowUsesProductionClient() throws Exception {
    String actor = "parent-profile-" + UUID.randomUUID(), token = SecretMaterial.token();
    when(decoder.decode(anyString())).thenAnswer(invocation -> {
      if (!token.equals(invocation.getArgument(0))) throw new BadJwtException("Not a fixture identity");
      return Jwt.withTokenValue(token).header("alg", "fixture").subject(actor)
          .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp"))
          .issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(600)).build();
    });
    String tenant = json.readTree(mvc.perform(post("/api/v1/tenants")
        .with(jwt().jwt(t -> t.subject(actor).claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create")))
        .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"HTTP fixture\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
    Path output = Path.of("target", "parent-subject-http.log").toAbsolutePath();
    var builder = new ProcessBuilder(System.getProperty("parent.dart.command"),
        Path.of(System.getProperty("parent.flutter.tool")).toAbsolutePath().toString(),
        "test", "--no-pub", "tool/verify_subject_http_test.dart")
        .directory(Path.of(System.getProperty("parent.package", "../apps/parent")).toAbsolutePath().toFile())
        .redirectErrorStream(true).redirectOutput(output.toFile());
    // 临时凭据仅传入子进程环境，不写日志或命令行参数。
    builder.environment().put("PARENT_SUBJECT_HTTP_FIXTURE", json.writeValueAsString(Map.of(
        "testOnly", true, "apiRoot", "http://127.0.0.1:" + port + "/api/v1", "tenantId", tenant, "actorId", actor, "token", token)));
    var process = builder.start();
    try {
      assertThat(process.waitFor(90, TimeUnit.SECONDS)).isTrue();
      assertThat(process.exitValue()).as("Flutter diagnostics: %s", output).isZero();
      assertThat(Files.readString(output)).contains("All tests passed!");
    } finally { if (process.isAlive()) process.destroyForcibly(); }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=?", Integer.class, tenant)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT version FROM subjects WHERE tenant_id=?", Long.class, tenant)).isEqualTo(3);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=? AND archived_at IS NOT NULL", Integer.class, tenant)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_subject_owners WHERE tenant_id=?", Integer.class, tenant)).isEqualTo(3);
  }
}
