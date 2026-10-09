package com.aimanager;

import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.support.TransactionTemplate;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Real loopback HTTP, production Dart protocols, Spring transactions and Flyway.
 * Adult decoder, active registration, system source and file storage are explicit
 * synthetic fixtures, not OIDC/MFA, native collection or encrypted-storage proof. */
@EnabledIfSystemProperty(named = "device.dart.command", matches = ".+")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
    "server.address=127.0.0.1",
    "spring.datasource.url=jdbc:h2:mem:observationhttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "spring.datasource.username=sa", "spring.datasource.password="
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class DeviceObservationHttpInteropTest {
    private static final Path DIRECTORY;
    static {
        try {
            Path root = Path.of(".local").toAbsolutePath(); Files.createDirectories(root);
            DIRECTORY = Files.createTempDirectory(root, "observation-http-");
        } catch (Exception failure) { throw new IllegalStateException("Fixture initialization failed"); }
    }
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        String url = System.getenv("OBSERVATION_TEST_DATABASE_URL");
        if (url == null) return;
        // Opt-in real database must be an explicitly provisioned disposable loopback schema.
        if (!url.matches("jdbc:mysql://(127\\.0\\.0\\.1|localhost):[0-9]+/observation_http_[a-f0-9]{32}(\\?.*)?")) {
            throw new IllegalArgumentException("Only isolated observation test schemas are permitted");
        }
        properties.add("spring.datasource.url", () -> url);
        properties.add("spring.datasource.username", () -> System.getenv("OBSERVATION_TEST_DATABASE_USERNAME"));
        properties.add("spring.datasource.password", () -> System.getenv("OBSERVATION_TEST_DATABASE_PASSWORD"));
    }
    @AfterAll static void removeSecrets() throws Exception {
        for (String file : List.of("fixture.json", "observation-state.json", "lost-pending.json")) {
            Files.deleteIfExists(DIRECTORY.resolve(file));
        }
    }
    @LocalServerPort int port;
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate jdbc;
    @Autowired DeviceCredentials credentials;
    @Autowired TransactionTemplate transactions;
    @MockitoBean JwtDecoder decoder;

    private String create(String path, String owner, Map<String, Object> input) throws Exception {
        var response = mvc.perform(post(path).with(jwt().jwt(token -> token.subject(owner)
                .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
                .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create")))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(input)))
            .andExpect(status().isCreated()).andReturn().getResponse();
        return mapper.readTree(response.getContentAsString()).get("id").asText();
    }
    private void dart(Path fixture, String target, String mode) throws Exception {
        String property = target.equals("device") ? "observation.device.package" : "observation.guardian.package";
        String fallback = target.equals("device") ? "../packages/device_observation" : "../apps/guardian";
        Path directory = Path.of(System.getProperty(property, fallback)).toAbsolutePath();
        String tool = target.equals("device") ? "tool/verify_http_fixture.dart" : "tool/verify_observation_fixture.dart";
        Path output = DIRECTORY.resolve(target + "-" + mode + ".log");
        var process = new ProcessBuilder(System.getProperty("device.dart.command"), "run", tool, fixture.toString(), mode)
            .directory(directory.toFile()).redirectErrorStream(true).redirectOutput(output.toFile()).start();
        if (!process.waitFor(60, TimeUnit.SECONDS)) {
            process.destroyForcibly(); throw new AssertionError("Bounded observation fixture exceeded deadline");
        }
        assertThat(process.exitValue()).as("Observation %s/%s; diagnostics %s", target, mode, output).isZero();
        assertThat(Files.readString(output)).contains("PASS observation");
    }
    @Test void adultConsentDeviceLostAcknowledgementReplayWithdrawalAndRevocation() throws Exception {
        String owner = "observation-http-" + UUID.randomUUID(), adultToken = SecretMaterial.token();
        when(decoder.decode(anyString())).thenAnswer(invocation -> {
            if (!adultToken.equals(invocation.getArgument(0))) throw new BadJwtException("Not an adult fixture");
            return Jwt.withTokenValue(adultToken).header("alg", "fixture").subject(owner)
                .claim("scope", "tenant:create").claim("auth_time", Instant.now().getEpochSecond())
                .claim("amr", List.of("pwd", "otp")).issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(3600)).build();
        });
        String tenant = create("/api/v1/tenants", owner, Map.of("name", "Observation HTTP fixture", "kind", "FAMILY", "timeZone", "UTC"));
        String subject = create("/api/v1/tenants/" + tenant + "/subjects", owner, Map.of("nickname", "Fixture child", "ageBand", "AGE_7_12"));
        String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString(), credential = SecretMaterial.token();
        long now = Instant.now().toEpochMilli();
        jdbc.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
                + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)", tenant, device, subject, registration, "Fixture device", now);
        jdbc.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,true)", tenant, registration, device);
        jdbc.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,true,?,?)",
            UUID.randomUUID().toString(), tenant, device, registration, SecretMaterial.hash(credential), now, now + 3600000);
        Path fixture = DIRECTORY.resolve("fixture.json");
        mapper.writeValue(fixture.toFile(), Map.of("testOnly", true, "apiRoot", "http://127.0.0.1:" + port + "/api/v1",
            "tenantId", tenant, "deviceId", device, "registrationId", registration,
            "credential", credential, "adultCredential", adultToken, "now", now));
        dart(fixture, "device", "off");
        dart(fixture, "guardian", "grant");
        dart(fixture, "device", "lost");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM usage_observation_batches WHERE tenant_id=?", Integer.class, tenant)).isEqualTo(1);
        String firstReport = jdbc.queryForObject("SELECT report_id FROM usage_observation_batches WHERE tenant_id=?", String.class, tenant);
        dart(fixture, "device", "replay");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM usage_observation_batches WHERE tenant_id=?", Integer.class, tenant)).isEqualTo(1);
        dart(fixture, "guardian", "list");
        dart(fixture, "guardian", "withdraw");
        for (String table : List.of("application_inventory_snapshots", "usage_observation_batches", "usage_observation_heads")) {
            assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Integer.class, tenant)).isZero();
        }
        dart(fixture, "device", "withdraw");
        dart(fixture, "guardian", "regrant");
        dart(fixture, "device", "regrant");
        assertThat(jdbc.queryForObject("SELECT authorization_version FROM usage_observation_batches WHERE tenant_id=?", Long.class, tenant)).isEqualTo(3L);
        assertThat(jdbc.queryForObject("SELECT sequence_number FROM usage_observation_batches WHERE tenant_id=?", Long.class, tenant)).isEqualTo(2L);
        assertThat(jdbc.queryForObject("SELECT report_id FROM usage_observation_batches WHERE tenant_id=?", String.class, tenant)).isNotEqualTo(firstReport);
        transactions.executeWithoutResult(status -> credentials.revoke(tenant, registration));
        dart(fixture, "device", "revoked");
    }
}
