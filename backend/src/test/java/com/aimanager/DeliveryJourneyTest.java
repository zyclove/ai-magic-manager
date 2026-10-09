package com.aimanager;

import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.JWSObject;
import com.nimbusds.jose.crypto.ECDSAVerifier;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.ECKey;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
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
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Real Nimbus signatures and opaque authentication; no broker, EMM or device execution is mocked as success. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:delivery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc
class DeliveryJourneyTest {
    private static final ECKey KEY;
    private static final Path KEY_FILE;
    static {
        try {
            KEY = new ECKeyGenerator(Curve.P_256).keyID("test-signing-key").generate();
            var directory = Path.of(".local").toAbsolutePath(); Files.createDirectories(directory);
            KEY_FILE = Files.createTempFile(directory, "delivery-test-", ".jwk");
            Files.writeString(KEY_FILE, KEY.toJSONString());
        } catch (Exception failure) { throw new IllegalStateException("Test key creation failed"); }
    }
    @DynamicPropertySource static void configureKey(DynamicPropertyRegistry registry) {
        registry.add("manager.delivery.signing-key-file", () -> KEY_FILE.toString());
    }
    @AfterAll static void removeTestKey() throws Exception { Files.deleteIfExists(KEY_FILE); }
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate database;
    @MockitoBean JwtDecoder decoder;
    @BeforeEach void rejectNonUserTokens() { when(decoder.decode(anyString())).thenThrow(new BadJwtException("Not a user token")); }
    private RequestPostProcessor actor(String owner) {
        return jwt().jwt(t -> t.subject(owner).claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }
    private JsonNode body(String json) throws Exception { return mapper.readTree(json); }
    private Scope scope() throws Exception {
        String owner = "delivery-" + UUID.randomUUID();
        String tenant = body(mvc.perform(post("/api/v1/tenants").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String subject = body(mvc.perform(post("/api/v1/tenants/" + tenant + "/subjects").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        var first = device(tenant, subject); var second = device(tenant, subject);
        String policy = body(mvc.perform(post("/api/v1/tenants/" + tenant + "/policies").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家长规则\",\"kind\":\"POLICY\",\"rules\":[{\"id\":\"break\",\"kind\":\"USAGE_REMINDER\",\"effect\":\"REMIND\",\"required\":false,\"seconds\":900}]}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        return new Scope(owner, tenant, policy, first, second);
    }
    private Agent device(String tenant, String subject) {
        String id = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString(), token = SecretMaterial.token();
        database.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)", tenant, id, subject, registration, "设备", Instant.now().toEpochMilli());
        database.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,true)", tenant, registration, id);
        database.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,true,?,?)",
            UUID.randomUUID().toString(), tenant, id, registration, SecretMaterial.hash(token), Instant.now().toEpochMilli(), Instant.now().plusSeconds(3600).toEpochMilli());
        return new Agent(id, registration, token);
    }
    private JsonNode publish(Scope s, List<String> targets) throws Exception {
        String path = "/api/v1/tenants/" + s.tenant() + "/policies/" + s.policy();
        var preview = body(mvc.perform(post(path + "/previews").with(actor(s.owner())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("deviceIds", targets))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        return body(mvc.perform(post(path + "/publications").with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", UUID.randomUUID().toString())
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("previewId", preview.get("id").asText(),
                "previewHash", preview.get("hash").asText(), "mode", "CONFIGURE_ONLY"))))
            .andExpect(status().isCreated()).andExpect(jsonPath("$.state").value("CONFIGURED_NOT_ENFORCED"))
            .andReturn().getResponse().getContentAsString());
    }
    private JsonNode pull(Agent agent, long after) throws Exception {
        return body(mvc.perform(get("/api/v1/device-api/configurations").header("Authorization", "Bearer " + agent.token())
            .param("after", Long.toString(after))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }
    private String receipt(JsonNode delivery, String id, String stage) throws Exception {
        return mapper.writeValueAsString(Map.of("receiptId", id, "deliveryId", delivery.get("id").asText(), "cursor", delivery.get("cursor").asLong(),
            "envelopeHash", SecretMaterial.hash(delivery.get("compactJws").asText()), "stage", stage));
    }
    private JsonNode ack(Agent agent, String payload) throws Exception {
        return body(mvc.perform(post("/api/v1/device-api/configuration-receipts").header("Authorization", "Bearer " + agent.token())
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }

    @Test void signedPullIsBoundToOneRegistrationAndDoesNotClaimEnforcement() throws Exception {
        var s = scope(); publish(s, List.of(s.first().id(), s.second().id()));
        var item = pull(s.first(), 0).get("items").get(0); var jws = JWSObject.parse(item.get("compactJws").asText());
        assertThat(jws.verify(new ECDSAVerifier(KEY.toPublicJWK()))).isTrue();
        assertThat(jws.getHeader().getAlgorithm().getName()).isEqualTo("ES256");
        assertThat(jws.getHeader().getType().toString()).isEqualTo("aimanager-configuration+jws");
        var envelope = body(jws.getPayload().toString());
        assertThat(envelope.get("tenantId").asText()).isEqualTo(s.tenant());
        assertThat(envelope.get("deviceId").asText()).isEqualTo(s.first().id());
        assertThat(envelope.get("registrationId").asText()).isEqualTo(s.first().registration());
        assertThat(envelope.get("mode").asText()).isEqualTo("CONFIGURE_ONLY");
        assertThat(envelope.get("effectiveUntil").isNull()).isTrue();
        assertThat(envelope.get("document").get("rules").get(0).get("predictedEffect").asText()).isEqualTo("REMIND");
        assertThat(envelope.get("document").get("rules").get(0).get("effectiveEffect").isNull()).isTrue();
        assertThat(envelope.toString()).doesNotContain(s.second().id(), s.second().registration());
        var publicKeys = mvc.perform(get("/api/v1/device-api/signing-keys").header("Authorization", "Bearer " + s.first().token()))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        assertThat(body(publicKeys).get("keys").get(0).has("d")).isFalse();
        assertThat(pull(s.first(), item.get("cursor").asLong()).get("items").size()).isZero();
    }

    @Test void receiptReplayAndOutOfOrderPhasesNeverBecomeApplied() throws Exception {
        var s = scope(); var publication = publish(s, List.of(s.first().id())); var item = pull(s.first(), 0).get("items").get(0);
        String payload = receipt(item, UUID.randomUUID().toString(), "STORED"); var first = ack(s.first(), payload);
        assertThat(first.get("state").asText()).isEqualTo("DEVICE_REPORTED_STORED");
        assertThat(ack(s.first(), payload)).isEqualTo(first);
        assertThat(ack(s.first(), receipt(item, UUID.randomUUID().toString(), "RECEIVED")).get("state").asText()).isEqualTo("DEVICE_REPORTED_STORED");
        mvc.perform(post("/api/v1/device-api/configuration-receipts").header("Authorization", "Bearer " + s.first().token())
            .contentType(MediaType.APPLICATION_JSON).content(receipt(item, UUID.randomUUID().toString(), "APPLIED"))).andExpect(status().isBadRequest());
        mvc.perform(get("/api/v1/tenants/" + s.tenant() + "/policy-publications/" + publication.get("id").asText())
            .with(actor(s.owner()))).andExpect(status().isOk()).andExpect(jsonPath("$.state").value("CONFIGURED_NOT_ENFORCED"));
    }

    @Test void foreignReceiptAndChangedReplayBodyAreRejected() throws Exception {
        var s = scope(); publish(s, List.of(s.first().id())); var item = pull(s.first(), 0).get("items").get(0); String id = UUID.randomUUID().toString();
        var payload = receipt(item, id, "RECEIVED"); ack(s.first(), payload);
        mvc.perform(post("/api/v1/device-api/configuration-receipts").header("Authorization", "Bearer " + s.second().token())
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/device-api/configuration-receipts").header("Authorization", "Bearer " + s.first().token())
            .contentType(MediaType.APPLICATION_JSON).content(receipt(item, id, "STORED")))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("RECEIPT_ID_CONFLICT"));
    }

    @Test void newerVersionSupersedesTransportAndLateReceiptDoesNotChangeItsState() throws Exception {
        var s = scope(); publish(s, List.of(s.first().id())); var old = pull(s.first(), 0).get("items").get(0);
        var currentPublication = publish(s, List.of(s.first().id())); var current = pull(s.first(), 0).get("items").get(0);
        assertThat(current.get("cursor").asLong()).isGreaterThan(old.get("cursor").asLong());
        assertThat(ack(s.first(), receipt(old, UUID.randomUUID().toString(), "STORED")).get("historical").asBoolean()).isTrue();
        mvc.perform(get("/api/v1/tenants/" + s.tenant() + "/policy-publications/" + currentPublication.get("id").asText() + "/deliveries")
            .with(actor(s.owner()))).andExpect(status().isOk()).andExpect(jsonPath("$.items[0].state").value("SERVED"));
    }

    @Test void withdrawnTargetGetsSignedConfigurationRemovalNotDeviceUnmanagement() throws Exception {
        var s = scope(); publish(s, List.of(s.first().id(), s.second().id())); var first = pull(s.first(), 0).get("items").get(0);
        publish(s, List.of(s.second().id())); var removal = pull(s.first(), first.get("cursor").asLong()).get("items").get(0);
        var payload = body(JWSObject.parse(removal.get("compactJws").asText()).getPayload().toString());
        assertThat(payload.get("action").asText()).isEqualTo("REMOVE_CONFIGURATION");
        assertThat(payload.get("document").isNull()).isTrue();
        assertThat(payload.get("mode").asText()).isEqualTo("CONFIGURE_ONLY");
    }

    @Test void expiredFirstDeliveryIsReissuedWithoutChangingSourceVersionOrSkippingCursor() throws Exception {
        var s = scope(); var publication = publish(s, List.of(s.first().id())); var first = pull(s.first(), 0).get("items").get(0);
        database.update("UPDATE configuration_deliveries SET delivery_expires_at=0 WHERE tenant_id=? AND id=?", s.tenant(), first.get("id").asText());
        var replacement = pull(s.first(), 0).get("items").get(0);
        assertThat(replacement.get("id").asText()).isNotEqualTo(first.get("id").asText());
        assertThat(replacement.get("cursor").asLong()).isEqualTo(first.get("cursor").asLong());
        var payload = body(JWSObject.parse(replacement.get("compactJws").asText()).getPayload().toString());
        assertThat(payload.get("versionId").asText()).isEqualTo(publication.get("versionId").asText());
        assertThat(payload.get("effectiveUntil").isNull()).isTrue();
    }

    @Test void revokedDeviceCannotPullOrAcknowledgeAndUserTokenCannotEnterDeviceChain() throws Exception {
        var s = scope(); publish(s, List.of(s.first().id())); var item = pull(s.first(), 0).get("items").get(0);
        mvc.perform(post("/api/v1/tenants/" + s.tenant() + "/devices/" + s.first().id() + "/revoke").with(actor(s.owner())))
            .andExpect(status().isNoContent());
        mvc.perform(get("/api/v1/device-api/configurations").header("Authorization", "Bearer " + s.first().token())).andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/device-api/configuration-receipts").header("Authorization", "Bearer " + s.first().token())
            .contentType(MediaType.APPLICATION_JSON).content(receipt(item, UUID.randomUUID().toString(), "STORED"))).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/device-api/configurations").header("Authorization", "Bearer user-jwt")).andExpect(status().isUnauthorized());
    }
    private record Scope(String owner, String tenant, String policy, Agent first, Agent second) {}
    @Test void storedReceiptCannotBeRegressedByLateRejection() throws Exception {
        var s = scope(); publish(s, List.of(s.first().id())); var item = pull(s.first(), 0).get("items").get(0);
        ack(s.first(), receipt(item, UUID.randomUUID().toString(), "STORED"));
        var rejection = (com.fasterxml.jackson.databind.node.ObjectNode) body(receipt(item, UUID.randomUUID().toString(), "REJECTED"));
        rejection.put("reason", "UNSUPPORTED_RULES");
        mvc.perform(post("/api/v1/device-api/configuration-receipts").header("Authorization", "Bearer " + s.first().token())
            .contentType(MediaType.APPLICATION_JSON).content(rejection.toString()))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("RECEIPT_PHASE_CONFLICT"));
    }
    private record Agent(String id, String registration, String token) {}
    @Test void paginationAndExpiredRetryDoNotSkipAnotherPolicyStream() throws Exception {
        var s = scope(); publish(s, List.of(s.first().id())); var first = pull(s.first(), 0).get("items").get(0);
        String secondPolicy = body(mvc.perform(post("/api/v1/tenants/" + s.tenant() + "/policies").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"另一条配置\",\"kind\":\"POLICY\",\"rules\":[]}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        publish(new Scope(s.owner(), s.tenant(), secondPolicy, s.first(), s.second()), List.of(s.first().id()));
        database.update("UPDATE configuration_deliveries SET delivery_expires_at=0 WHERE tenant_id=? AND id=?", s.tenant(), first.get("id").asText());
        var page = body(mvc.perform(get("/api/v1/device-api/configurations").header("Authorization", "Bearer " + s.first().token())
            .param("after", "0").param("limit", "1")).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        assertThat(page.get("hasMore").asBoolean()).isTrue();
        assertThat(page.get("items").get(0).get("cursor").asLong()).isEqualTo(first.get("cursor").asLong());
        assertThat(pull(s.first(), page.get("nextAfter").asLong()).get("items").size()).isEqualTo(1);
    }
    @Test void explicitRejectionRemainsVisibleAfterExpiryAndDoesNotRefreshItself() throws Exception {
        var s = scope(); var publication = publish(s, List.of(s.first().id())); var item = pull(s.first(), 0).get("items").get(0);
        var rejection = (com.fasterxml.jackson.databind.node.ObjectNode) body(receipt(item, UUID.randomUUID().toString(), "REJECTED"));
        rejection.put("reason", "UNSUPPORTED_SCHEMA"); ack(s.first(), rejection.toString());
        database.update("UPDATE configuration_deliveries SET delivery_expires_at=0 WHERE tenant_id=? AND id=?", s.tenant(), item.get("id").asText());
        mvc.perform(get("/api/v1/tenants/" + s.tenant() + "/policy-publications/" + publication.get("id").asText() + "/deliveries")
            .with(actor(s.owner()))).andExpect(status().isOk()).andExpect(jsonPath("$.items[0].state").value("DEVICE_REPORTED_REJECTED"));
        assertThat(pull(s.first(), 0).get("items").get(0).get("id").asText()).isEqualTo(item.get("id").asText());
    }
    @Test void signedDocumentContainsTheResolvedApplicationReferencedByItsRule() throws Exception {
        var s = scope();
        var app = body(mvc.perform(post("/api/v1/tenants/" + s.tenant() + "/applications").with(actor(s.owner()))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("displayName", "阅读应用", "platform", "ANDROID",
                "packageName", "org.example.reader", "profile", "PRIMARY", "signingDigests", List.of("a".repeat(64))))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        var rules = List.of(Map.of("id", "reader", "kind", "APP_LAUNCH", "effect", "DENY", "required", true, "applicationId", app.get("id").asText()));
        var policy = body(mvc.perform(post("/api/v1/tenants/" + s.tenant() + "/policies").with(actor(s.owner()))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("name", "应用配置", "kind", "POLICY", "rules", rules))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        publish(new Scope(s.owner(), s.tenant(), policy.get("id").asText(), s.first(), s.second()), List.of(s.first().id()));
        var document = body(JWSObject.parse(pull(s.first(), 0).get("items").get(0).get("compactJws").asText()).getPayload().toString()).get("document");
        assertThat(document.get("applications").get(0).get("id").asText()).isEqualTo(document.get("rules").get(0).get("applicationId").asText());
        assertThat(document.get("applications").get(0).get("evidenceStatus").asText()).isEqualTo("ADMIN_DECLARED");
    }
}
