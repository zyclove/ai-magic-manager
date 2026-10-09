package com.aimanager;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
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
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Real opaque-token and database path; fixture registration does not claim Android execution or provenance. */
@SpringBootTest(properties = {
    "spring.datasource.url=${OBSERVATION_TEST_DATABASE_URL:jdbc:h2:mem:inventory;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
    "spring.datasource.username=${OBSERVATION_TEST_DATABASE_USERNAME:sa}",
    "spring.datasource.password=${OBSERVATION_TEST_DATABASE_PASSWORD:}", "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc
class InventoryJourneyTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate database;
    @MockitoBean JwtDecoder decoder;
    @BeforeEach void rejectDeviceTokensOnUserChain() { when(decoder.decode(anyString())).thenThrow(new BadJwtException("Not a user token")); }
    private RequestPostProcessor actor(String owner) {
        return jwt().jwt(t -> t.subject(owner).claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }
    private Scope scope() throws Exception {
        String owner = "inventory-" + UUID.randomUUID();
        var family = mvc.perform(post("/api/v1/tenants").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse();
        String tenant = mapper.readTree(family.getContentAsString()).get("id").asText();
        var child = mvc.perform(post("/api/v1/tenants/" + tenant + "/subjects").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse();
        String subject = mapper.readTree(child.getContentAsString()).get("id").asText();
        String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString(), token = SecretMaterial.token();
        database.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)", tenant, device, subject, registration, "设备", Instant.now().toEpochMilli());
        database.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,true)", tenant, registration, device);
        database.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,true,?,?)",
            UUID.randomUUID().toString(), tenant, device, registration, SecretMaterial.hash(token), Instant.now().toEpochMilli(), Instant.now().plusSeconds(3600).toEpochMilli());
        mvc.perform(put("/api/v1/tenants/" + tenant + "/devices/" + device + "/observation-settings")
            .with(actor(owner)).header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON)
            .content("{\"inventoryEnabled\":true,\"usageEnabled\":false,\"reason\":\"监护人授权库存观察\"}"))
            .andExpect(status().isOk());
        return new Scope(owner, tenant, subject, device, token);
    }
    private String input(int sequence, String packageName) {
        return "{\"sequence\":" + sequence + ",\"authorizationVersion\":1,\"visibility\":\"VISIBLE_PACKAGES\",\"applications\":[{\"packageName\":\"" + packageName
            + "\",\"displayName\":\"应用\",\"profile\":\"PRIMARY\",\"signingDigests\":[\"" + "a".repeat(64)
            + "\"],\"versionCode\":1,\"systemApplication\":false}]}";
    }
    private JsonNode report(Scope s, String payload) throws Exception {
        return mapper.readTree(mvc.perform(post("/api/v1/device-api/application-inventory").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }
    private String path(Scope s) { return "/api/v1/tenants/" + s.tenant() + "/devices/" + s.device() + "/application-inventory"; }
    @Test void fullSnapshotReplacementAndReplayDoNotRefreshEvidence() throws Exception {
        var s = scope(); var first = report(s, input(1, "org.example.game"));
        var replay = report(s, input(1, "org.example.game")); assertThat(replay).isEqualTo(first);
        mvc.perform(post("/api/v1/device-api/application-inventory").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(input(1, "org.example.other")))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("INVENTORY_SEQUENCE_CONFLICT"));
        report(s, input(2, "org.example.reader"));
        mvc.perform(get(path(s)).with(actor(s.owner()))).andExpect(status().isOk())
            .andExpect(jsonPath("$.applications.length()").value(1)).andExpect(jsonPath("$.applications[0].packageName").value("org.example.reader"))
            .andExpect(jsonPath("$.evidenceStatus").value("AGENT_REPORTED_UNVERIFIED"));
        mvc.perform(post("/api/v1/device-api/application-inventory").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(input(1, "org.example.game"))).andExpect(status().isConflict());
    }
    @Test void missingOrStaleInventoryDoesNotBecomeVerifiedOrComplete() throws Exception {
        var s = scope(); mvc.perform(get(path(s)).with(actor(s.owner()))).andExpect(status().isOk())
            .andExpect(jsonPath("$.observationStatus").value("UNKNOWN"));
        report(s, input(1, "org.example.game"));
        database.update("UPDATE application_inventory_snapshots SET received_at=0 WHERE tenant_id=? AND device_id=?", s.tenant(), s.device());
        mvc.perform(get(path(s)).with(actor(s.owner()))).andExpect(status().isOk()).andExpect(jsonPath("$.observationStatus").value("STALE"));
        mvc.perform(get(path(s)).with(actor("other-owner"))).andExpect(status().isForbidden());
    }
    @Test void revocationAndWrongAuthenticationChainBlockInventory() throws Exception {
        var s = scope(); report(s, input(1, "org.example.game"));
        mvc.perform(get(path(s)).header("Authorization", "Bearer " + s.token())).andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/device-api/application-inventory").header("Authorization", "Bearer user-jwt")
            .contentType(MediaType.APPLICATION_JSON).content(input(2, "org.example.reader"))).andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/tenants/" + s.tenant() + "/devices/" + s.device() + "/revoke").with(actor(s.owner())))
            .andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/device-api/application-inventory").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(input(2, "org.example.reader"))).andExpect(status().isUnauthorized());
    }
    @Test void childCanReadOwnVisibleInventoryButNotAnotherSubjectDevice() throws Exception {
        var s = scope(); report(s, input(1, "org.example.reader")); String child = "child-" + UUID.randomUUID();
        database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,'CHILD',?)",
            s.tenant(), child, ActorKeys.key(child), s.subject());
        mvc.perform(get(path(s)).with(actor(child))).andExpect(status().isOk());
        String otherSubject = UUID.randomUUID().toString(), otherDevice = UUID.randomUUID().toString();
        database.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'另一人','AGE_7_12',?)",
            s.tenant(), otherSubject, Instant.now().toEpochMilli());
        database.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)", s.tenant(), otherDevice, otherSubject, UUID.randomUUID().toString(), "其他设备", Instant.now().toEpochMilli());
        mvc.perform(get("/api/v1/tenants/" + s.tenant() + "/devices/" + otherDevice + "/application-inventory").with(actor(child)))
            .andExpect(status().isForbidden());
    }

    @Test void duplicateInstancesAndForgedScopeOrProvenanceAreRejected() throws Exception {
        var s = scope();
        var payload = (com.fasterxml.jackson.databind.node.ObjectNode) mapper.readTree(input(1, "org.example.reader"));
        var apps = (com.fasterxml.jackson.databind.node.ArrayNode) payload.get("applications"); apps.add(apps.get(0).deepCopy());
        mvc.perform(post("/api/v1/device-api/application-inventory").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(payload.toString()))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("DUPLICATE_APPLICATION_INSTANCE"));
        payload = (com.fasterxml.jackson.databind.node.ObjectNode) mapper.readTree(input(1, "org.example.reader"));
        payload.put("tenantId", UUID.randomUUID().toString());
        mvc.perform(post("/api/v1/device-api/application-inventory").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(payload.toString())).andExpect(status().isBadRequest());
        mvc.perform(post("/api/v1/device-api/application-inventory").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(input(1, "org.example.reader").replace("VISIBLE_PACKAGES", "EMM_VERIFIED")))
            .andExpect(status().isBadRequest());
        assertThat(database.queryForObject("SELECT COUNT(*) FROM application_inventory_snapshots WHERE tenant_id=?", Integer.class, s.tenant())).isZero();
    }

    @Test void normalizedOrderingReplaysAndEmptyVisibleSnapshotDoesNotMeanNoInstalledApps() throws Exception {
        var s = scope();
        var payload = (com.fasterxml.jackson.databind.node.ObjectNode) mapper.readTree(input(1, "org.example.reader"));
        var apps = (com.fasterxml.jackson.databind.node.ArrayNode) payload.get("applications");
        var other = (com.fasterxml.jackson.databind.node.ObjectNode) apps.get(0).deepCopy(); other.put("packageName", "org.example.game"); apps.add(other);
        var first = report(s, payload.toString());
        var reordered = mapper.createArrayNode(); reordered.add(apps.get(1)); reordered.add(apps.get(0)); payload.set("applications", reordered);
        assertThat(report(s, payload.toString())).isEqualTo(first);
        report(s, "{\"sequence\":2,\"authorizationVersion\":1,\"visibility\":\"VISIBLE_PACKAGES\",\"applications\":[]}");
        mvc.perform(get(path(s)).with(actor(s.owner()))).andExpect(status().isOk()).andExpect(jsonPath("$.applications.length()").value(0))
            .andExpect(jsonPath("$.visibility").value("VISIBLE_PACKAGES")).andExpect(jsonPath("$.evidenceStatus").value("AGENT_REPORTED_UNVERIFIED"));
    }
    private record Scope(String owner, String tenant, String subject, String device, String token) {}
    @Test void missingProductionSigningConfigurationIsExplicitlyUnavailable() throws Exception {
        var s = scope();
        mvc.perform(get("/api/v1/device-api/signing-keys").header("Authorization", "Bearer " + s.token())).andExpect(status().isServiceUnavailable())
            .andExpect(jsonPath("$.errorCode").value("SIGNING_KEY_NOT_CONFIGURED"));
        mvc.perform(get("/api/v1/device-api/configurations").header("Authorization", "Bearer " + s.token())).andExpect(status().isServiceUnavailable());
    }
}
