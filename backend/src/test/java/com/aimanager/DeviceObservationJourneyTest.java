package com.aimanager;

import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
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

/** 真实安全链、事务和迁移；设备记录为受控夹具，不冒充 Android 系统执行证明。 */
@SpringBootTest(properties = {
    "spring.datasource.url=${OBSERVATION_TEST_DATABASE_URL:jdbc:h2:mem:device_observation;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
    "spring.datasource.username=${OBSERVATION_TEST_DATABASE_USERNAME:sa}",
    "spring.datasource.password=${OBSERVATION_TEST_DATABASE_PASSWORD:}", "spring.flyway.enabled=true",
    "manager.observations.minimum-report-interval-seconds=1", "manager.observations.max-retained-batches=2"
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
@Import(DeviceObservationJourneyTest.ClockConfiguration.class)
class DeviceObservationJourneyTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate database;
    @MockitoBean JwtDecoder decoder;
    @Autowired ObservationTestClock clock;
    private AtomicLong now;

    @BeforeEach void configureClockAndDecoder() {
        now = clock.value;
        now.set(Instant.now().toEpochMilli());
        when(decoder.decode(anyString())).thenThrow(new BadJwtException("Not an adult token"));
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class ClockConfiguration {
        @Bean @Primary ObservationTestClock observationTestClock() {
            return new ObservationTestClock(new AtomicLong(Instant.now().toEpochMilli()), ZoneOffset.UTC);
        }
    }

    /** Real typed Clock: Mockito interception of Clock.millis failed on the first MySQL request. */
    static class ObservationTestClock extends Clock {
        final AtomicLong value;
        private final ZoneId zone;
        ObservationTestClock(AtomicLong value, ZoneId zone) {
            this.value = value;
            this.zone = java.util.Objects.requireNonNull(zone);
        }
        @Override public long millis() { return value.get(); }
        @Override public Instant instant() { return Instant.ofEpochMilli(millis()); }
        @Override public ZoneId getZone() { return zone; }
        @Override public Clock withZone(ZoneId target) { return new ObservationTestClock(value, target); }
    }
    private RequestPostProcessor actor(String name, boolean mfa) {
        return jwt().jwt(t -> t.subject(name).claim("auth_time", now.get() / 1000)
            .claim("amr", mfa ? List.of("pwd", "otp") : List.of("pwd")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }
    private Scope scope() throws Exception {
        String owner = "observation-" + UUID.randomUUID();
        var family = mvc.perform(post("/api/v1/tenants").with(actor(owner, true))
            .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andDo(result -> {
                var failure = result.getResolvedException();
                if (failure != null) {
                    // Safe diagnostics: types and frames only, never SQL values or token bodies.
                    throw new AssertionError("Tenant fixture exception: " + failure.getClass().getName()
                        + "\n" + java.util.Arrays.stream(failure.getStackTrace()).limit(24)
                            .map(StackTraceElement::toString).collect(java.util.stream.Collectors.joining("\n")));
                }
            })
            .andExpect(status().isCreated()).andReturn().getResponse();
        String tenant = mapper.readTree(family.getContentAsString()).get("id").asText();
        var child = mvc.perform(post("/api/v1/tenants/" + tenant + "/subjects").with(actor(owner, true))
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse();
        String subject = mapper.readTree(child.getContentAsString()).get("id").asText();
        String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString(), token = SecretMaterial.token();
        database.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)", tenant, device, subject, registration, "设备", now.get());
        database.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,true)", tenant, registration, device);
        database.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,true,?,?)",
            UUID.randomUUID().toString(), tenant, device, registration, SecretMaterial.hash(token), now.get(), now.get() + 3600000);
        return new Scope(owner, tenant, device, registration, token);
    }
    private String settings(Scope s) { return "/api/v1/tenants/" + s.tenant() + "/devices/" + s.device() + "/observation-settings"; }
    private String usage(Scope s) { return "/api/v1/tenants/" + s.tenant() + "/devices/" + s.device() + "/usage-observations"; }
    private JsonNode update(Scope s, int version, boolean inventory, boolean usage, String key) throws Exception {
        return mapper.readTree(mvc.perform(put(settings(s)).with(actor(s.owner(), true))
            .header("If-Match", "\"" + version + "\"").header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON)
            .content("{\"inventoryEnabled\":" + inventory + ",\"usageEnabled\":" + usage + ",\"reason\":\"监护人确认用途\"}"))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }
    private String report(int sequence, int version) throws Exception {
        return mapper.writeValueAsString(java.util.Map.of("reportId", UUID.randomUUID().toString(), "sequence", sequence,
            "authorizationVersion", version, "source", "ANDROID_USAGE_STATS", "profile", "PRIMARY",
            "queryStart", now.get() - 3600000, "queryEnd", now.get(), "observedAt", now.get(), "timeZone", "UTC",
            "applications", List.of(java.util.Map.of("packageName", "org.example.reader", "displayName", "阅读",
                "firstTimeStamp", now.get() - 3600000, "lastTimeStamp", now.get(), "foregroundMillis", 1234))));
    }
    private JsonNode send(Scope s, String body) throws Exception {
        return mapper.readTree(mvc.perform(post("/api/v1/device-api/usage-observations")
            .header("Authorization", "Bearer " + s.token()).contentType(MediaType.APPLICATION_JSON).content(body))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }

    @Test void defaultsAreOffAndOpaqueSettingsAreBoundToRegistration() throws Exception {
        var s = scope();
        mvc.perform(get(settings(s)).with(actor(s.owner(), true))).andExpect(status().isOk())
            .andExpect(header().string("ETag", "\"0\""))
            .andExpect(jsonPath("$.inventoryEnabled").value(false)).andExpect(jsonPath("$.usageEnabled").value(false));
        mvc.perform(get("/api/v1/device-api/observation-settings").header("Authorization", "Bearer " + s.token()))
            .andExpect(status().isOk()).andExpect(jsonPath("$.registrationId").value(s.registration()))
            .andExpect(jsonPath("$.version").value(0));
        mvc.perform(post("/api/v1/device-api/usage-observations").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(report(1, 1)))
            .andExpect(status().isForbidden()).andExpect(jsonPath("$.errorCode").value("OBSERVATION_NOT_AUTHORIZED"));
    }
    @Test void recentMfaStrongVersionAndTenantScopeAreRequired() throws Exception {
        var s = scope(); String body = "{\"inventoryEnabled\":true,\"usageEnabled\":true,\"reason\":\"授权\"}";
        mvc.perform(put(settings(s)).with(actor(s.owner(), false)).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isUnauthorized());
        mvc.perform(put(settings(s)).with(actor(s.owner(), true)).contentType(MediaType.APPLICATION_JSON).content(body))
            .andExpect(status().isPreconditionRequired());
        mvc.perform(put(settings(s)).with(actor(s.owner(), true)).header("If-Match", "W/\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isBadRequest());
        mvc.perform(get(settings(s)).with(actor("other-owner", true))).andExpect(status().isForbidden());
        String key = UUID.randomUUID().toString();
        assertThat(update(s, 0, true, true, key)).isEqualTo(update(s, 0, true, true, key));
        mvc.perform(put(settings(s)).with(actor(s.owner(), true)).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isPreconditionFailed());
    }
    @Test void usageReplayIsExactAndNeverCertifiedOrChargedAsQuota() throws Exception {
        var s = scope(); update(s, 0, false, true, UUID.randomUUID().toString());
        String body = report(1, 1); var first = send(s, body);
        assertThat(send(s, body)).isEqualTo(first);
        mvc.perform(post("/api/v1/device-api/usage-observations").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(body.replace("1234", "1235")))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("USAGE_SEQUENCE_CONFLICT"));
        mvc.perform(get(usage(s)).with(actor(s.owner(), true))).andExpect(status().isOk())
            .andExpect(jsonPath("$.items.length()").value(1))
            .andExpect(jsonPath("$.items[0].precision").value("OS_AGGREGATE"))
            .andExpect(jsonPath("$.items[0].evidenceStatus").value("AGENT_REPORTED_UNVERIFIED"));
    }
    @Test void withdrawalDeletesPayloadsAndOldAuthorizationCannotResurrectThem() throws Exception {
        var s = scope(); update(s, 0, true, true, UUID.randomUUID().toString());
        send(s, report(1, 1)); update(s, 1, false, false, UUID.randomUUID().toString());
        mvc.perform(get(usage(s)).with(actor(s.owner(), true))).andExpect(status().isOk())
            .andExpect(jsonPath("$.items.length()").value(0));
        update(s, 2, true, true, UUID.randomUUID().toString());
        mvc.perform(post("/api/v1/device-api/usage-observations").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(report(2, 1)))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("OBSERVATION_AUTHORIZATION_CHANGED"));
    }
    @Test void duplicateApplicationsAndUnboundedOrForgedReportsAreRejected() throws Exception {
        var s = scope(); update(s, 0, false, true, UUID.randomUUID().toString());
        var body = (com.fasterxml.jackson.databind.node.ObjectNode) mapper.readTree(report(1, 1));
        var apps = (com.fasterxml.jackson.databind.node.ArrayNode) body.get("applications"); apps.add(apps.get(0).deepCopy());
        mvc.perform(post("/api/v1/device-api/usage-observations").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(body.toString())).andExpect(status().isBadRequest());
        body = (com.fasterxml.jackson.databind.node.ObjectNode) mapper.readTree(report(1, 1)); body.put("tenantId", UUID.randomUUID().toString());
        mvc.perform(post("/api/v1/device-api/usage-observations").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(body.toString())).andExpect(status().isBadRequest());
    }
    @Test void reportRateAndRetainedHistoryAreBoundedButLatestAckSurvives() throws Exception {
        var s = scope(); update(s, 0, false, true, UUID.randomUUID().toString()); send(s, report(1, 1));
        mvc.perform(post("/api/v1/device-api/usage-observations").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(report(2, 1)))
            .andExpect(status().isTooManyRequests());
        now.addAndGet(2000); send(s, report(2, 1)); now.addAndGet(2000); String last = report(3, 1); send(s, last);
        mvc.perform(get(usage(s)).with(actor(s.owner(), true))).andExpect(status().isOk())
            .andExpect(jsonPath("$.items.length()").value(2)).andExpect(jsonPath("$.items[0].sequence").value(3));
        assertThat(send(s, last).get("sequence").asInt()).isEqualTo(3);
    }
    @Test void revokedCredentialsCannotReadSettingsOrSubmitUsage() throws Exception {
        var s = scope(); update(s, 0, false, true, UUID.randomUUID().toString());
        database.update("UPDATE device_credentials SET revoked_at=? WHERE tenant_id=? AND device_id=?", now.get(), s.tenant(), s.device());
        mvc.perform(get("/api/v1/device-api/observation-settings").header("Authorization", "Bearer " + s.token()))
            .andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/device-api/usage-observations").header("Authorization", "Bearer " + s.token())
            .contentType(MediaType.APPLICATION_JSON).content(report(1, 1))).andExpect(status().isUnauthorized());
    }
    private record Scope(String owner, String tenant, String device, String registration, String token) {}
}
