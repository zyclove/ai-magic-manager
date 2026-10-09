package com.aimanager;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.*;
import java.nio.file.*;
import java.time.*;
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
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Real device claims, Nimbus proofs, opaque authentication and Dart lifecycle.
 * Adult JWT/OTP is an explicit bootstrap fixture, never real MFA evidence.
 * Temporary plaintext fixture state is removed; native encrypted storage is a
 * separate gate. The test has no device-registration/credential SQL bootstrap. */
@EnabledIfSystemProperty(named="device.identity.package", matches=".+")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT, properties={
    "server.address=127.0.0.1",
    "spring.datasource.url=jdbc:h2:mem:identityhttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "spring.datasource.username=sa", "spring.datasource.password="
})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class DeviceIdentityHttpInteropTest {
    private static Path directory;
    @BeforeAll static void initializeFixtureDirectory() throws Exception {
        Path root=Path.of(".local").toAbsolutePath(); Files.createDirectories(root);
        directory=Files.createTempDirectory(root,"device-identity-http-");
    }
    @AfterAll static void removeSecretFixtures() throws Exception {
        if(directory==null) return;
        for(String name:List.of("fixture.json","identity-state.json","identity-state.json.tmp"))
            Files.deleteIfExists(directory.resolve(name));
    }
    @LocalServerPort int port;
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate jdbc;
    @MockitoBean JwtDecoder userDecoder;
    private RequestPostProcessor adult(String actor) {
        return jwt().jwt(token->token.subject(actor).claim("auth_time",Instant.now().getEpochSecond()).claim("amr",List.of("pwd","otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }
    private com.fasterxml.jackson.databind.JsonNode create(String path,String actor,Map<String,Object> input) throws Exception {
        var response=mvc.perform(post(path).with(adult(actor)).contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(input)))
            .andExpect(status().isCreated()).andReturn().getResponse();
        return mapper.readTree(response.getContentAsString());
    }
    private void runDart(Path fixture,String mode) throws Exception {
        Path packageDirectory=Path.of(System.getProperty("device.identity.package")).toAbsolutePath();
        Path log=directory.resolve("dart-"+mode+".log");
        var process=new ProcessBuilder(System.getProperty("device.dart.command"),"run","tool/verify_http_fixture.dart",fixture.toString(),mode)
            .directory(packageDirectory.toFile()).redirectErrorStream(true).redirectOutput(log.toFile()).start();
        if(!process.waitFor(45,TimeUnit.SECONDS)) {
            process.destroyForcibly(); throw new AssertionError("Isolated Dart identity process exceeded its deadline");
        }
        assertThat(process.exitValue()).as("Dart identity diagnostics: %s",log).isZero();
        assertThat(Files.readString(log)).contains("PASS");
    }
    private int actualHeartbeatStatus(String credential) throws Exception {
        var client=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).followRedirects(HttpClient.Redirect.NEVER).build();
            var request=HttpRequest.newBuilder(URI.create("http://127.0.0.1:"+port+"/api/v1/device-api/heartbeats"))
                .timeout(Duration.ofSeconds(5)).header("Authorization","Bearer "+credential).header("Content-Type","application/json")
                .POST(HttpRequest.BodyPublishers.ofString("{\"sequence\":4,\"agentVersion\":\"java-http\",\"capabilities\":[]}")).build();
            return client.send(request,HttpResponse.BodyHandlers.discarding()).statusCode();
    }
    @Test void actualEnrollmentRecoveryConfirmationRotationAndRevocation() throws Exception {
        when(userDecoder.decode(anyString())).thenThrow(new BadJwtException("Adult fixture unavailable"));
        String owner="identity-owner-"+UUID.randomUUID();
        String tenant=create("/api/v1/tenants",owner,Map.of("name","Identity HTTP test","kind","FAMILY","timeZone","UTC")).get("id").asText();
        String subject=create("/api/v1/tenants/"+tenant+"/subjects",owner,Map.of("nickname","Fixture child","ageBand","AGE_7_12")).get("id").asText();
        var ticket=create("/api/v1/tenants/"+tenant+"/enrollments",owner,Map.of("subjectId",subject,"requestedMode","BYOD","platform","ANDROID"));
        String enrollment=ticket.get("id").asText();
        Path fixture=directory.resolve("fixture.json");
        mapper.writeValue(fixture.toFile(),Map.of("testOnly",true,"apiRoot","http://127.0.0.1:"+port+"/api/v1",
            "tenantId",tenant,"enrollmentId",enrollment,"token",ticket.get("token").asText(),"expiresAt",ticket.get("expiresAt").asLong()));
        runDart(fixture,"claim-lost");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM devices WHERE tenant_id=? AND state='AWAITING_CONFIRMATION'",Integer.class,tenant)).isEqualTo(1);
        runDart(fixture,"recover");
        assertThat(jdbc.queryForObject("SELECT recovery_attempts FROM device_enrollments WHERE tenant_id=? AND id=?",Integer.class,tenant,enrollment)).isEqualTo(1);
        var local=mapper.readTree(directory.resolve("identity-state.json").toFile());
        String device=local.get("deviceId").asText(), oldCredential=local.get("credential").asText();
        assertThat(actualHeartbeatStatus(oldCredential)).isEqualTo(401);
        mvc.perform(post("/api/v1/tenants/"+tenant+"/enrollments/"+enrollment+"/confirm").with(adult(owner)).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("pairingCode",local.get("pairingCode").asText())))).andExpect(status().isOk());
        runDart(fixture,"activate-rotate");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM device_credentials WHERE tenant_id=? AND active=TRUE AND revoked_at IS NULL",Integer.class,tenant)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT heartbeat_sequence FROM devices WHERE tenant_id=? AND id=?",Long.class,tenant,device)).isEqualTo(3L);
        assertThat(actualHeartbeatStatus(oldCredential)).isEqualTo(401);
        mvc.perform(post("/api/v1/tenants/"+tenant+"/devices/"+device+"/revoke").with(adult(owner))).andExpect(status().isNoContent());
        runDart(fixture,"revoked");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM devices WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
    }
}
