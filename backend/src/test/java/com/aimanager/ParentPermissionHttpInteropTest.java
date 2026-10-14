package com.aimanager;

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
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** 真实回环 HTTP + 生产手机控制器；身份、活动设备及手机存储是显式夹具。 */
@EnabledIfSystemProperty(named = "parent.dart.command", matches = ".+")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
    "server.address=127.0.0.1",
    "spring.datasource.url=jdbc:h2:mem:parentpermissionhttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "manager.observation.permissions.enabled=true", "spring.datasource.username=sa", "spring.datasource.password="
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ParentPermissionHttpInteropTest {
    @LocalServerPort int port;
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate db;
    @MockitoBean JwtDecoder decoder;
    private String create(String path, String actor, Map<String, Object> input) throws Exception {
        var response = mvc.perform(post(path).with(jwt().jwt(token -> token.subject(actor)
            .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create")))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(input)))
            .andExpect(status().isCreated()).andReturn().getResponse();
        return mapper.readTree(response.getContentAsString()).get("id").asText();
    }
    @Test void lostResponseRecoveryAndWithdrawalThroughParentController() throws Exception {
        String actor = "parent-http-" + UUID.randomUUID(), token = SecretMaterial.token();
        when(decoder.decode(anyString())).thenAnswer(invocation -> {
            if (!token.equals(invocation.getArgument(0))) throw new BadJwtException("Not a fixture identity");
            return Jwt.withTokenValue(token).header("alg", "fixture").subject(actor)
                .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp"))
                .issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(600)).build();
        });
        String tenant = create("/api/v1/tenants", actor,
            Map.of("name", "Parent HTTP fixture", "kind", "FAMILY", "timeZone", "UTC"));
        String subject = create("/api/v1/tenants/" + tenant + "/subjects", actor,
            Map.of("nickname", "Fixture child", "ageBand", "AGE_7_12"));
        String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
        db.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,"
            + "state,public_key_jwk,key_thumbprint,created_at) VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)",
            tenant, device, subject, registration, "Fixture device", System.currentTimeMillis());
        String deviceToken = SecretMaterial.token();
        long now = System.currentTimeMillis();
        db.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,true)", tenant, registration, device);
        db.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,true,?,?)",
            UUID.randomUUID().toString(), tenant, device, registration, SecretMaterial.hash(deviceToken), now, now + 3600000);
        Path output = Path.of("target", "parent-permission-http.log").toAbsolutePath();
        Path parent = Path.of(System.getProperty("parent.package", "../apps/parent")).toAbsolutePath();
        Path flutter = Path.of(System.getProperty("parent.flutter.tool")).toAbsolutePath();
        var builder = new ProcessBuilder(System.getProperty("parent.dart.command"), flutter.toString(),
            "test", "--no-pub", "tool/verify_permission_http_test.dart")
            .directory(parent.toFile()).redirectErrorStream(true).redirectOutput(output.toFile());
        // 临时夹具凭据仅在子进程环境传递，不写入参数、文件或日志。
        builder.environment().put("PARENT_PERMISSION_HTTP_FIXTURE", mapper.writeValueAsString(Map.of(
            "testOnly", true, "apiRoot", "http://127.0.0.1:" + port + "/api/v1", "tenantId", tenant,
            "actorId", actor, "deviceId", device, "registrationId", registration, "subjectId", subject, "token", token,
            "deviceToken", deviceToken)));
        var process = builder.start();
        try {
            assertThat(process.waitFor(90, TimeUnit.SECONDS)).as("Bounded Flutter HTTP fixture").isTrue();
            assertThat(process.exitValue()).as("Flutter HTTP diagnostics: %s", output).isZero();
            assertThat(Files.readString(output)).contains("All tests passed!");
        } finally {
            if (process.isAlive()) process.destroyForcibly();
        }
        assertThat(db.queryForObject("SELECT version FROM device_permission_observation_settings WHERE tenant_id=?", Long.class, tenant)).isEqualTo(2L);
        assertThat(db.queryForObject("SELECT enabled FROM device_permission_observation_settings WHERE tenant_id=?", Boolean.class, tenant)).isFalse();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=? AND operation='permission.observation.update'", Integer.class, tenant)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT COUNT(*) FROM device_permission_observation_snapshots WHERE tenant_id=?", Integer.class, tenant)).isZero();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=? AND operation='permission.observation.update' AND response_state='SCOPED'", Integer.class, tenant)).isEqualTo(2);
    }
}
