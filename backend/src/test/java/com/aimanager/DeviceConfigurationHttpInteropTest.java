package com.aimanager;

import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.signing.ConfigurationSigner;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.support.TransactionTemplate;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Real loopback Spring HTTP, Nimbus, opaque authentication and Dart file storage.
 * Adult identities and activated registrations are explicit bootstrap fixtures;
 * this does not prove OIDC/OTP enrollment or native device enforcement. */
@EnabledIfSystemProperty(named="device.dart.command", matches=".+")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT, properties={
    "server.address=127.0.0.1",
    "spring.datasource.url=jdbc:h2:mem:devicehttp;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "spring.datasource.username=sa", "spring.datasource.password="
})
@AutoConfigureMockMvc
class DeviceConfigurationHttpInteropTest {
    private static final Path DIRECTORY;
    private static final Path PRIVATE_KEY;
    static {
        try {
            Path root=Path.of(".local").toAbsolutePath(); Files.createDirectories(root);
            DIRECTORY=Files.createTempDirectory(root,"device-http-");
            PRIVATE_KEY=Files.createTempFile(DIRECTORY,"test-signing-",".jwk");
            Files.writeString(PRIVATE_KEY,new ECKeyGenerator(Curve.P_256).keyID("device-http-key").generate().toJSONString());
        } catch(Exception failure) { throw new IllegalStateException("Test key initialization failed"); }
    }
    @DynamicPropertySource static void signing(DynamicPropertyRegistry properties) {
        properties.add("manager.delivery.signing-key-file",()->PRIVATE_KEY.toString());
    }
    @AfterAll static void removeSensitiveFixtures() throws Exception {
        Files.deleteIfExists(PRIVATE_KEY); Files.deleteIfExists(DIRECTORY.resolve("fixture.json"));
    }
    @LocalServerPort int port;
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate jdbc;
    @Autowired ConfigurationSigner signer;
    @Autowired DeviceCredentials credentials;
    @Autowired TransactionTemplate transactions;
    @MockitoBean JwtDecoder userDecoder;

    private RequestPostProcessor adult(String subject) {
        return jwt().jwt(token->token.subject(subject).claim("auth_time",Instant.now().getEpochSecond()).claim("amr",List.of("pwd","otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }
    private String createdId(String path,String actor,Map<String,Object> input) throws Exception {
        var response=mvc.perform(post(path).with(adult(actor)).contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(input)))
            .andExpect(status().isCreated()).andReturn().getResponse();
        return mapper.readTree(response.getContentAsString()).get("id").asText();
    }
    private void publish(String tenant,String owner,String device,int index) throws Exception {
        String policy=createdId("/api/v1/tenants/"+tenant+"/policies",owner,Map.of("name","HTTP fixture "+index,"kind","POLICY",
            "rules",List.of(Map.of("id","reminder","kind","USAGE_REMINDER","effect","REMIND","required",false,"seconds",900))));
        String path="/api/v1/tenants/"+tenant+"/policies/"+policy;
        var preview=mapper.readTree(mvc.perform(post(path+"/previews").with(adult(owner)).header("If-Match","\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("deviceIds",List.of(device)))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        mvc.perform(post(path+"/publications").with(adult(owner)).header("If-Match","\"0\"").header("Idempotency-Key",UUID.randomUUID().toString())
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("previewId",preview.get("id").asText(),
                "previewHash",preview.get("hash").asText(),"mode","CONFIGURE_ONLY")))).andExpect(status().isCreated());
    }
    private void runDart(Path fixture,String mode) throws Exception {
        Path packageDirectory=Path.of(System.getProperty("device.policy.package","../packages/device_policy")).toAbsolutePath();
        Path output=DIRECTORY.resolve("dart-"+mode+".log");
        var process=new ProcessBuilder(System.getProperty("device.dart.command"),"run","tool/verify_http_fixture.dart",fixture.toString(),mode)
            .directory(packageDirectory.toFile()).redirectErrorStream(true).redirectOutput(output.toFile()).start();
        boolean completed=process.waitFor(45,TimeUnit.SECONDS);
        if(!completed) { process.destroyForcibly(); throw new AssertionError("Isolated Dart HTTP fixture exceeded its bounded deadline"); }
        assertThat(process.exitValue()).as("Dart interoperability; diagnostic file %s",output).isZero();
        assertThat(Files.readString(output)).contains("PASS");
    }
    @Test void realDeviceTransportStoresTwoPagesAndRejectsRevokedCredential() throws Exception {
        when(userDecoder.decode(anyString())).thenThrow(new BadJwtException("User token fixture unavailable"));
        String owner="http-owner-"+UUID.randomUUID();
        String tenant=createdId("/api/v1/tenants",owner,Map.of("name","HTTP test","kind","FAMILY","timeZone","UTC"));
        String subject=createdId("/api/v1/tenants/"+tenant+"/subjects",owner,Map.of("nickname","Fixture child","ageBand","AGE_7_12"));
        String device=UUID.randomUUID().toString(), registration=UUID.randomUUID().toString(), credential=SecretMaterial.token();
        jdbc.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','test-fixture',?)",
            tenant,device,subject,registration,"Fixture agent",Instant.now().toEpochMilli());
        jdbc.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,TRUE)",tenant,registration,device);
        jdbc.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,TRUE,?,?)",
            UUID.randomUUID().toString(),tenant,device,registration,SecretMaterial.hash(credential),Instant.now().toEpochMilli(),Instant.now().plusSeconds(3600).toEpochMilli());
        publish(tenant,owner,device,1); publish(tenant,owner,device,2);
        Path fixture=Files.createFile(DIRECTORY.resolve("fixture.json"));
        mapper.writeValue(fixture.toFile(),Map.of("apiRoot","http://127.0.0.1:"+port+"/api/v1","tenantId",tenant,
            "deviceId",device,"registrationId",registration,"credential",credential,"publicKeys",signer.publicKeys()));
        runDart(fixture,"sync");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM configuration_deliveries WHERE tenant_id=? AND state='DEVICE_REPORTED_STORED'",Integer.class,tenant)).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM configuration_receipts WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(2);
        transactions.executeWithoutResult(status->credentials.revoke(tenant,registration));
        runDart(fixture,"revoked");
    }
}
