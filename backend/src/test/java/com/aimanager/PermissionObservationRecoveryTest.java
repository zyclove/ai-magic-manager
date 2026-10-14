package com.aimanager;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
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

/** 注册绑定、真实事务和只读恢复；身份与设备是显式测试夹具。 */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:permission-observation-recovery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "manager.observation.permissions.enabled=true", "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc
class PermissionObservationRecoveryTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate db;
    @MockitoBean JwtDecoder decoder;
    private RequestPostProcessor actor(String id, boolean mfa) {
        return jwt().jwt(t -> t.subject(id).claim("auth_time", Instant.now().getEpochSecond())
            .claim("amr", mfa ? List.of("pwd", "otp") : List.of("pwd")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }
    private Scope fixture() throws Exception {
        String owner = UUID.randomUUID().toString();
        String tenant = mapper.readTree(mvc.perform(post("/api/v1/tenants").with(actor(owner, true))
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"观察验证\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String subject = mapper.readTree(mvc.perform(post("/api/v1/tenants/" + tenant + "/subjects")
            .with(actor(owner, true)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
        db.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,"
            + "state,public_key_jwk,key_thumbprint,created_at) VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)",
            tenant, device, subject, registration, "测试设备", System.currentTimeMillis());
        return new Scope(owner, tenant, device, registration);
    }
    private record Scope(String owner, String tenant, String device, String registration) {
        String path() { return "/api/v1/tenants/" + tenant + "/devices/" + device + "/permission-observation-settings"; }
    }
    private String body(Scope scope, int version, boolean enabled) throws Exception {
        return mapper.writeValueAsString(Map.of("registrationId", scope.registration(), "version", version,
            "enabled", enabled, "reason", "确认授权用途"));
    }
    private void change(Scope s, int version, boolean enabled, String key) throws Exception {
        mvc.perform(post(s.path() + "/changes").with(actor(s.owner(), true))
            .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(body(s, version, enabled)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.version").value(version + 1));
    }
    @Test void originalResponseRemainsDistinctFromRevocationAndQueryDoesNotWrite() throws Exception {
        var s = fixture(); String key = UUID.randomUUID().toString();
        change(s, 0, true, key);
        change(s, 1, false, UUID.randomUUID().toString());
        db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=? AND operation='permission.observation.update'", s.tenant());
        for (int count = 0; count < 2; count++) {
            mvc.perform(post(s.path() + "/operation-results/" + key + "/query").with(actor(s.owner(), false))
                .contentType(MediaType.APPLICATION_JSON).content(body(s, 0, true)))
                .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(jsonPath("$.committed.version").value(1)).andExpect(jsonPath("$.committed.enabled").value(true))
                .andExpect(jsonPath("$.current.version").value(2)).andExpect(jsonPath("$.current.enabled").value(false));
        }
        assertThat(db.queryForObject("SELECT version FROM device_permission_observation_settings WHERE tenant_id=?", Long.class, s.tenant())).isEqualTo(2);
        assertThat(db.queryForObject("SELECT MAX(expires_at) FROM idempotency_requests WHERE scope_id=? AND operation='permission.observation.update'", Long.class, s.tenant())).isZero();
    }
    @Test void erasedReceiptNeverReplaysOrDisclosesResponse() throws Exception {
        var s = fixture(); String key = UUID.randomUUID().toString(); change(s, 0, true, key);
        assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=? AND operation='permission.observation.update' AND response_state='SCOPED'", Integer.class, s.tenant())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_subject_owners WHERE scope_id=?", Integer.class, s.tenant())).isGreaterThanOrEqualTo(1);
        db.update("UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL WHERE scope_id=? AND operation='permission.observation.update'", s.tenant());
        for (String suffix : List.of("/changes", "/operation-results/" + key + "/query")) {
            mvc.perform(post(s.path() + suffix).with(actor(s.owner(), true)).header("Idempotency-Key", key)
                .contentType(MediaType.APPLICATION_JSON).content(body(s, 0, true)))
                .andExpect(status().isGone()).andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_RESPONSE_ERASED"));
        }
        assertThat(db.queryForObject("SELECT version FROM device_permission_observation_settings WHERE tenant_id=?", Long.class, s.tenant())).isEqualTo(1);
    }
    @Test void aNewRegistrationCannotReplayOldPermissionConsent() throws Exception {
        var s = fixture(); String key = UUID.randomUUID().toString(); change(s, 0, true, key);
        String registration = UUID.randomUUID().toString();
        // Fixture mirrors revocation cleanup before a different registration is installed.
        db.update("DELETE FROM device_permission_observation_settings WHERE tenant_id=? AND device_id=?", s.tenant(), s.device());
        db.update("UPDATE devices SET registration_id=? WHERE tenant_id=? AND id=?", registration, s.tenant(), s.device());
        var renewed = new Scope(s.owner(), s.tenant(), s.device(), registration);
        mvc.perform(post(s.path() + "/changes").with(actor(s.owner(), true)).header("Idempotency-Key", key)
            .contentType(MediaType.APPLICATION_JSON).content(body(renewed, 0, true)))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("REGISTRATION_CHANGED"));
        assertThat(db.queryForObject("SELECT COUNT(*) FROM device_permission_observation_settings WHERE tenant_id=? AND registration_id=?", Integer.class, s.tenant(), registration)).isZero();
    }
    @Test void fingerprintOriginalActorAndCurrentRoleAreRequired() throws Exception {
        var s = fixture(); String key = UUID.randomUUID().toString(); change(s, 0, true, key);
        String query = s.path() + "/operation-results/" + key + "/query";
        mvc.perform(post(query).with(actor(s.owner(), true)).contentType(MediaType.APPLICATION_JSON).content(body(s, 0, false)))
            .andExpect(status().isConflict());
        String other = UUID.randomUUID().toString();
        db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')", s.tenant(), other, ActorKeys.key(other));
        mvc.perform(post(query).with(actor(other, true)).contentType(MediaType.APPLICATION_JSON).content(body(s, 0, true)))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.errorCode").value("OBSERVATION_RESULT_UNAVAILABLE"));
        mvc.perform(post(query).with(actor("outsider", true)).contentType(MediaType.APPLICATION_JSON).content(body(s, 0, true)))
            .andExpect(status().isForbidden());
        db.update("UPDATE tenant_members SET role='AUDITOR' WHERE tenant_id=? AND actor_key=?", s.tenant(), ActorKeys.key(s.owner()));
        mvc.perform(post(query).with(actor(s.owner(), true)).contentType(MediaType.APPLICATION_JSON).content(body(s, 0, true)))
            .andExpect(status().isForbidden());
    }
    @Test void changedRegistrationMfaAndOptimisticVersionPreventNewWrites() throws Exception {
        var s = fixture();
        mvc.perform(post(s.path() + "/changes").with(actor(s.owner(), false)).contentType(MediaType.APPLICATION_JSON)
            .content(body(s, 0, true))).andExpect(status().isUnauthorized());
        mvc.perform(post(s.path() + "/changes").with(actor(s.owner(), true)).contentType(MediaType.APPLICATION_JSON)
            .content(body(s, 0, true))).andExpect(status().isBadRequest());
        String key = UUID.randomUUID().toString(); change(s, 0, true, key);
        mvc.perform(post(s.path() + "/changes").with(actor(s.owner(), true)).header("Idempotency-Key", UUID.randomUUID())
            .contentType(MediaType.APPLICATION_JSON).content(body(s, 0, false))).andExpect(status().isPreconditionFailed());
        var stale = new Scope(s.owner(), s.tenant(), s.device(), UUID.randomUUID().toString());
        for (String path : List.of("/changes", "/operation-results/" + key + "/query")) {
            mvc.perform(post(s.path() + path).with(actor(s.owner(), true)).header("Idempotency-Key", key)
                .contentType(MediaType.APPLICATION_JSON).content(body(stale, 0, true)))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("REGISTRATION_CHANGED"));
        }
        assertThat(db.queryForObject("SELECT COUNT(*) FROM device_permission_observation_settings WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(1);
    }
}
