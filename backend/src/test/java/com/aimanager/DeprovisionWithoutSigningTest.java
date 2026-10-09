package com.aimanager;

import com.fasterxml.jackson.databind.*;
import com.nimbusds.jose.jwk.*;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** A real unconfigured signer cannot partially revoke a device through the normal exit workflow. */
@SpringBootTest(properties = {"spring.datasource.url=jdbc:h2:mem:cleanup-no-signing;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true", "manager.delivery.signing-key-file="})
@AutoConfigureMockMvc
class DeprovisionWithoutSigningTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate database;
    @MockitoBean JwtDecoder decoder;
    @Test void normalExitFailsBeforeRevocationAndEmergencyCredentialRevokeStillWorks() throws Exception {
        String owner = "cleanup-no-signer-" + UUID.randomUUID();
        RequestPostProcessor actor = jwt().jwt(t -> t.subject(owner).claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
        String tenant = mapper.readTree(mvc.perform(post("/api/v1/tenants").with(actor).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String subject = mapper.readTree(mvc.perform(post("/api/v1/tenants/" + tenant + "/subjects").with(actor).contentType(MediaType.APPLICATION_JSON)
            .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        var key = new ECKeyGenerator(Curve.P_256).generate(); String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
        database.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE',?,?,?)", tenant, device, subject, registration, "设备", key.toPublicJWK().toJSONString(),
            key.computeThumbprint().toString(), Instant.now().toEpochMilli());
        database.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,true)", tenant, registration, device);
        String path = "/api/v1/tenants/" + tenant + "/devices/" + device;
        JsonNode preview = mapper.readTree(mvc.perform(post(path + "/deprovision/previews").with(actor).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content("{\"action\":\"AGENT_UNENROLL\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        mvc.perform(post(path + "/deprovision/operations").with(actor).header("If-Match", "\"0\"").header("Idempotency-Key", "no-signer")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("previewId", preview.get("id").asText(), "previewHash", preview.get("hash").asText()))))
            .andExpect(status().isServiceUnavailable()).andExpect(jsonPath("$.errorCode").value("SIGNING_KEY_NOT_CONFIGURED"));
        assertThat(database.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?", String.class, tenant, device)).isEqualTo("ACTIVE");
        assertThat(database.queryForObject("SELECT active FROM device_credential_scopes WHERE tenant_id=? AND registration_id=?", Boolean.class, tenant, registration)).isTrue();
        assertThat(database.queryForObject("SELECT COUNT(*) FROM deprovision_operations WHERE tenant_id=?", Integer.class, tenant)).isZero();
        mvc.perform(post(path + "/revoke").with(actor)).andExpect(status().isNoContent());
        assertThat(database.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?", String.class, tenant, device)).isEqualTo("REVOKED");
    }
}
