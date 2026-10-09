package com.aimanager;

import com.aimanager.identity.ActorKeys;
import com.aimanager.lifecycle.CleanupMaintenance;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.*;
import com.nimbusds.jose.jwk.*;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import com.nimbusds.jwt.*;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.*;
import org.springframework.context.annotation.*;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Exercises cloud revoke and registered-key cleanup authentication; local erasure remains an unverified report. */
@SpringBootTest(properties = {"spring.datasource.url=jdbc:h2:mem:deprovision;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true", "manager.lifecycle.expiry-job.enabled=false"})
@AutoConfigureMockMvc
@Import(DeprovisionJourneyTest.TimeConfiguration.class)
class DeprovisionJourneyTest {
    private static final ECKey SERVER_KEY;
    private static final Path KEY_FILE;
    static {
        try {
            SERVER_KEY = new ECKeyGenerator(Curve.P_256).keyID("cleanup-test-key").generate();
            var directory = Path.of(".local").toAbsolutePath(); Files.createDirectories(directory);
            KEY_FILE = Files.createTempFile(directory, "cleanup-test-", ".jwk");
            Files.writeString(KEY_FILE, SERVER_KEY.toJSONString());
        } catch (Exception failure) { throw new IllegalStateException("Test key creation failed"); }
    }
    @DynamicPropertySource static void configureKey(DynamicPropertyRegistry registry) {
        registry.add("manager.delivery.signing-key-file", () -> KEY_FILE.toString());
    }
    @AfterAll static void removeTestKey() throws Exception { Files.deleteIfExists(KEY_FILE); }
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate database;
    @Autowired TestClock clock;
    @Autowired CleanupMaintenance maintenance;
    @MockitoBean JwtDecoder decoder;
    @BeforeEach void reset() {
        clock.set(Instant.parse("2026-10-09T03:00:00Z"));
        when(decoder.decode(anyString())).thenThrow(new BadJwtException("Not a user token"));
    }
    private RequestPostProcessor actor(String name) {
        return jwt().jwt(t -> t.subject(name).claim("auth_time", clock.instant().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }
    private JsonNode body(String json) throws Exception { return mapper.readTree(json); }
    private Scope scope() throws Exception {
        String owner = "cleanup-owner-" + UUID.randomUUID(), child = "cleanup-child-" + UUID.randomUUID();
        String tenant = body(mvc.perform(post("/api/v1/tenants").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String subject = body(mvc.perform(post("/api/v1/tenants/" + tenant + "/subjects").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,'CHILD',?)",
            tenant, child, ActorKeys.key(child), subject);
        String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString(), token = SecretMaterial.token();
        var key = new ECKeyGenerator(Curve.P_256).generate();
        database.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE',?,?,?)", tenant, device, subject, registration, "设备", key.toPublicJWK().toJSONString(),
            key.computeThumbprint().toString(), clock.millis());
        database.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,true)", tenant, registration, device);
        database.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,true,?,?)",
            UUID.randomUUID().toString(), tenant, device, registration, SecretMaterial.hash(token), clock.millis(), clock.instant().plusSeconds(3600).toEpochMilli());
        return new Scope(owner, child, tenant, device, registration, token, key);
    }
    private String path(Scope s) { return "/api/v1/tenants/" + s.tenant() + "/devices/" + s.device() + "/deprovision"; }
    private JsonNode preview(Scope s) throws Exception {
        return body(mvc.perform(post(path(s) + "/previews").with(actor(s.owner())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content("{\"action\":\"AGENT_UNENROLL\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    }
    private String confirmation(JsonNode p) throws Exception {
        return mapper.writeValueAsString(Map.of("previewId", p.get("id").asText(), "previewHash", p.get("hash").asText()));
    }
    private JsonNode start(Scope s, JsonNode p, String requestKey) throws Exception {
        return body(mvc.perform(post(path(s) + "/operations").with(actor(s.owner())).header("If-Match", "\"0\"")
            .header("Idempotency-Key", requestKey).contentType(MediaType.APPLICATION_JSON).content(confirmation(p)))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    }
    private String proof(Scope s, ECKey key, String action, String operation) throws Exception {
        var claims = new JWTClaimsSet.Builder().issuer("device:" + s.registration()).subject(s.device()).audience("ai-manager:cleanup")
            .claim("tenantId", s.tenant()).claim("registrationId", s.registration()).claim("purpose", "AGENT_CLEANUP")
            .claim("action", action).issueTime(Date.from(clock.instant())).expirationTime(Date.from(clock.instant().plusSeconds(120)))
            .jwtID(UUID.randomUUID().toString());
        if (operation != null) claims.claim("operationId", operation);
        var token = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.ES256).keyID(s.registration())
            .type(new JOSEObjectType("aimanager-cleanup-auth+jwt")).build(), claims.build());
        token.sign(new ECDSASigner(key)); return token.serialize();
    }
    private JsonNode pull(Scope s) throws Exception {
        return body(mvc.perform(get("/api/v1/device-cleanup/command").header("Authorization", "Bearer " + proof(s, s.key(), "READ", null)))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }
    private String operationPath(Scope s, JsonNode operation) { return path(s) + "/operations/" + operation.get("id").asText(); }
    private JsonNode getOperation(Scope s, JsonNode operation) throws Exception {
        return body(mvc.perform(get(operationPath(s, operation)).with(actor(s.owner())))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }
    private String receipt(JsonNode command, String stage) throws Exception {
        var input = new HashMap<String, Object>(); input.put("receiptId", UUID.randomUUID().toString());
        input.put("commandId", command.get("commandId").asText()); input.put("commandHash", SecretMaterial.hash(command.get("compactJws").asText()));
        input.put("stage", stage); if ("FAILED".equals(stage)) input.put("reasonCode", "STORAGE_FAILURE"); return mapper.writeValueAsString(input);
    }
    private JsonNode acknowledge(Scope s, JsonNode operation, String payload) throws Exception {
        return body(mvc.perform(post("/api/v1/device-cleanup/receipts").header("Authorization", "Bearer " + proof(s, s.key(), "RECEIPT", operation.get("id").asText()))
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }

    @Test void confirmedExitRevokesBusinessAccessAndDeliversAnOwnAgentOnlySignedCommand() throws Exception {
        var s = scope(); var p = preview(s); var op = start(s, p, "exit");
        assertThat(p.get("deviceVersion").asLong()).isZero();
        assertThat(p.get("limitations").toString()).contains("LOCAL_ERASURE_UNVERIFIED", "NO_SYSTEM_UNMANAGE", "NO_DEVICE_WIPE");
        assertThat(op.get("remoteAccess").asText()).isEqualTo("REVOKED");
        assertThat(op.get("localEvidence").asText()).isEqualTo("NONE");
        mvc.perform(get("/api/v1/device-api/configurations").header("Authorization", "Bearer " + s.token())).andExpect(status().isUnauthorized());
        assertThat(database.queryForObject("SELECT active FROM device_credential_scopes WHERE tenant_id=? AND registration_id=?", Boolean.class,
            s.tenant(), s.registration())).isFalse();
        var command = pull(s); var jws = JWSObject.parse(command.get("compactJws").asText());
        assertThat(jws.verify(new ECDSAVerifier(SERVER_KEY.toPublicJWK()))).isTrue();
        assertThat(jws.getHeader().getType().toString()).isEqualTo("aimanager-cleanup-command+jws");
        var payload = body(jws.getPayload().toString());
        assertThat(payload.get("purpose").asText()).isEqualTo("AGENT_CLEANUP");
        assertThat(payload.get("operationId").asText()).isEqualTo(op.get("id").asText());
        assertThat(payload.get("registrationId").asText()).isEqualTo(s.registration());
        assertThat(payload.get("scope").asText()).isEqualTo("OWN_AGENT_DATA_ONLY");
        assertThat(payload.get("keyRemoval").asText()).isEqualTo("AFTER_SERVER_ACK");
        assertThat(pull(s).get("compactJws").asText()).isEqualTo(command.get("compactJws").asText());
        assertThat(start(s, p, "exit").get("id").asText()).isEqualTo(op.get("id").asText());
    }
    @Test void childrenAndUnsupportedDestructiveActionsCannotExitManagement() throws Exception {
        var s = scope();
        mvc.perform(post(path(s) + "/previews").with(actor(s.child())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content("{\"action\":\"AGENT_UNENROLL\"}")).andExpect(status().isForbidden());
        mvc.perform(post(path(s) + "/previews").with(actor(s.owner())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content("{\"action\":\"DEVICE_WIPE\"}"))
            .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.errorCode").value("DEPROVISION_ACTION_UNSUPPORTED"));
        assertThat(database.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?", String.class, s.tenant(), s.device())).isEqualTo("ACTIVE");
    }
    @Test void normalTokensWrongKeysAndWrongNamespacesDoNotGrantCleanupAuthority() throws Exception {
        var s = scope(); start(s, preview(s), "exit");
        mvc.perform(get("/api/v1/device-cleanup/command").header("Authorization", "Bearer " + s.token())).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/device-cleanup/command").header("Authorization", "Bearer " + proof(s, new ECKeyGenerator(Curve.P_256).generate(), "READ", null)))
            .andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/device-api/configurations").header("Authorization", "Bearer " + proof(s, s.key(), "READ", null)))
            .andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/tenants").header("Authorization", "Bearer " + proof(s, s.key(), "READ", null)))
            .andExpect(status().isUnauthorized());
    }
    @Test void cleanupReceiptIsIdempotentAndNeverPretendsToVerifyLocalErasure() throws Exception {
        var s = scope(); var op = start(s, preview(s), "exit"); var cmd = pull(s);
        String receipt = mapper.writeValueAsString(Map.of("receiptId", UUID.randomUUID().toString(), "commandId", cmd.get("commandId").asText(),
            "commandHash", SecretMaterial.hash(cmd.get("compactJws").asText()), "stage", "AGENT_DATA_CLEARED"));
        String proof = proof(s, s.key(), "RECEIPT", op.get("id").asText());
        String response = mvc.perform(post("/api/v1/device-cleanup/receipts").header("Authorization", "Bearer " + proof)
            .contentType(MediaType.APPLICATION_JSON).content(receipt)).andExpect(status().isOk())
            .andExpect(jsonPath("$.state").value("CLEANUP_REPORTED")).andExpect(jsonPath("$.localEvidence").value("DEVICE_REPORT_UNVERIFIED"))
            .andReturn().getResponse().getContentAsString();
        assertThat(mvc.perform(post("/api/v1/device-cleanup/receipts").header("Authorization", "Bearer " + proof)
            .contentType(MediaType.APPLICATION_JSON).content(receipt)).andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).isEqualTo(response);
        mvc.perform(post("/api/v1/device-cleanup/receipts").header("Authorization", "Bearer " + proof)
            .contentType(MediaType.APPLICATION_JSON).content(receipt.replace("AGENT_DATA_CLEARED", "FAILED")))
            .andExpect(status().isConflict());
    }
    @Test void staleOrExpiredPreviewAndWrongAcknowledgementCannotRevokeCredentials() throws Exception {
        var s = scope(); var p = preview(s);
        mvc.perform(post(path(s) + "/operations").with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "bad-hash")
            .contentType(MediaType.APPLICATION_JSON).content(confirmation(p).replace(p.get("hash").asText(), "a".repeat(64))))
            .andExpect(status().isForbidden());
        database.update("UPDATE devices SET version=version+1 WHERE tenant_id=? AND id=?", s.tenant(), s.device());
        mvc.perform(post(path(s) + "/operations").with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "stale")
            .contentType(MediaType.APPLICATION_JSON).content(confirmation(p))).andExpect(status().isPreconditionFailed());
        database.update("UPDATE devices SET version=0 WHERE tenant_id=? AND id=?", s.tenant(), s.device());
        clock.set(clock.instant().plusSeconds(301));
        mvc.perform(post(path(s) + "/operations").with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "expired")
            .contentType(MediaType.APPLICATION_JSON).content(confirmation(p))).andExpect(status().isConflict());
        assertThat(database.queryForObject("SELECT active FROM device_credential_scopes WHERE tenant_id=? AND registration_id=?", Boolean.class,
            s.tenant(), s.registration())).isTrue();
        assertThat(database.queryForObject("SELECT COUNT(*) FROM deprovision_operations WHERE tenant_id=?", Integer.class, s.tenant())).isZero();
    }
    @Test void confirmationRequiresMfaVersionIdempotencyAndCurrentAdultMembershipEvenOnReplay() throws Exception {
        var s = scope(); var p = preview(s);
        mvc.perform(post(path(s) + "/operations").with(jwt().jwt(t -> t.subject(s.owner())))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "reauth").contentType(MediaType.APPLICATION_JSON).content(confirmation(p)))
            .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
        mvc.perform(post(path(s) + "/operations").with(actor(s.owner())).header("Idempotency-Key", "version")
            .contentType(MediaType.APPLICATION_JSON).content(confirmation(p))).andExpect(status().is(428));
        mvc.perform(post(path(s) + "/operations").with(actor(s.owner())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(confirmation(p))).andExpect(status().isBadRequest());
        start(s, p, "exit");
        database.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?", s.tenant(), ActorKeys.key(s.owner()));
        mvc.perform(post(path(s) + "/operations").with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "exit")
            .contentType(MediaType.APPLICATION_JSON).content(confirmation(p))).andExpect(status().isForbidden());
    }
    @Test void proofActionForeignOperationAndCommandBindingCannotBeSubstituted() throws Exception {
        var s = scope(); var other = scope(); var op = start(s, preview(s), "exit"); var foreign = start(other, preview(other), "exit");
        var cmd = pull(s);
        mvc.perform(get("/api/v1/device-cleanup/command").header("Authorization", "Bearer " + proof(s, s.key(), "READ", foreign.get("id").asText())))
            .andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/device-cleanup/receipts").header("Authorization", "Bearer " + proof(s, s.key(), "READ", null))
            .contentType(MediaType.APPLICATION_JSON).content(receipt(cmd, "RECEIVED"))).andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/device-cleanup/receipts").header("Authorization", "Bearer " + proof(s, s.key(), "RECEIPT", op.get("id").asText()))
            .contentType(MediaType.APPLICATION_JSON).content(receipt(cmd, "RECEIVED").replace(cmd.get("commandId").asText(), UUID.randomUUID().toString())))
            .andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/device-cleanup/command").header("Authorization", "Bearer " + proof(s, s.key(), "RECEIPT", op.get("id").asText())))
            .andExpect(status().isForbidden());
    }
    @Test void unservedCommandsCannotBeAcknowledgedAndLateStagesCannotRegressAnErasureReport() throws Exception {
        var s = scope(); var op = start(s, preview(s), "exit");
        String compact = database.queryForObject("SELECT compact_jws FROM deprovision_operations WHERE tenant_id=? AND id=?", String.class, s.tenant(), op.get("id").asText());
        var unserved = mapper.valueToTree(Map.of("commandId", op.get("commandId").asText(), "compactJws", compact));
        mvc.perform(post("/api/v1/device-cleanup/receipts").header("Authorization", "Bearer " + proof(s, s.key(), "RECEIPT", op.get("id").asText()))
            .contentType(MediaType.APPLICATION_JSON).content(receipt(unserved, "RECEIVED"))).andExpect(status().isConflict());
        var cmd = pull(s); acknowledge(s, op, receipt(cmd, "FAILED"));
        assertThat(getOperation(s, op).get("state").asText()).isEqualTo("CLEANUP_FAILED");
        acknowledge(s, op, receipt(cmd, "AGENT_DATA_CLEARED")); var reported = getOperation(s, op);
        assertThat(acknowledge(s, op, receipt(cmd, "RECEIVED")).get("version").asLong()).isEqualTo(reported.get("version").asLong());
        mvc.perform(post("/api/v1/device-cleanup/receipts").header("Authorization", "Bearer " + proof(s, s.key(), "RECEIPT", op.get("id").asText()))
            .contentType(MediaType.APPLICATION_JSON).content(receipt(cmd, "FAILED"))).andExpect(status().isConflict());
        assertThat(getOperation(s, op).get("state").asText()).isEqualTo("CLEANUP_REPORTED");
    }
    @Test void cancellationStopsCloudCleanupWithoutRestoringCredentialsAndRenewalRejectsOldProof() throws Exception {
        var s = scope(); var op = start(s, preview(s), "exit"); var original = pull(s); var current = getOperation(s, op);
        String oldProof = proof(s, s.key(), "READ", op.get("id").asText());
        mvc.perform(post(operationPath(s, op) + "/cancel").with(actor(s.owner())).header("If-Match", "\"" + current.get("version").asLong() + "\"")
            .header("Idempotency-Key", "cancel")).andExpect(status().isOk()).andExpect(jsonPath("$.state").value("CLEANUP_CANCELLED"))
            .andExpect(jsonPath("$.remoteAccess").value("REVOKED"));
        mvc.perform(get("/api/v1/device-cleanup/command").header("Authorization", "Bearer " + oldProof)).andExpect(status().isUnauthorized());
        var p = body(mvc.perform(post(path(s) + "/previews").with(actor(s.owner())).header("If-Match", "\"1\"")
            .contentType(MediaType.APPLICATION_JSON).content("{\"action\":\"AGENT_UNENROLL\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        var next = body(mvc.perform(post(path(s) + "/operations").with(actor(s.owner())).header("If-Match", "\"1\"").header("Idempotency-Key", "renew")
            .contentType(MediaType.APPLICATION_JSON).content(confirmation(p))).andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        assertThat(next.get("id").asText()).isNotEqualTo(op.get("id").asText());
        assertThat(pull(s).get("commandId").asText()).isNotEqualTo(original.get("commandId").asText());
        mvc.perform(get("/api/v1/device-cleanup/command").header("Authorization", "Bearer " + oldProof)).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/device-api/configurations").header("Authorization", "Bearer " + s.token())).andExpect(status().isUnauthorized());
    }
    @Test void absoluteCleanupDeadlineNeverExtendsOnPullAndExpiryIsPersistedWithANewEtag() throws Exception {
        var s = scope(); var op = start(s, preview(s), "exit"); var cmd = pull(s); var served = getOperation(s, op);
        clock.set(Instant.ofEpochMilli(op.get("notAfter").asLong()));
        mvc.perform(get("/api/v1/device-cleanup/command").header("Authorization", "Bearer " + proof(s, s.key(), "READ", null))).andExpect(status().isUnauthorized());
        var expired = getOperation(s, op);
        assertThat(expired.get("state").asText()).isEqualTo("CLEANUP_EXPIRED");
        assertThat(expired.get("localEvidence").asText()).isEqualTo("NONE");
        assertThat(expired.get("version").asLong()).isGreaterThan(served.get("version").asLong());
        assertThat(expired.get("notAfter").asLong()).isEqualTo(cmd.get("notAfter").asLong());
        assertThat(database.queryForObject("SELECT state FROM deprovision_operations WHERE tenant_id=? AND id=?", String.class,
            s.tenant(), op.get("id").asText())).isEqualTo("CLEANUP_EXPIRED");
    }
    @Test void wrongAudienceTypePurposeAndUnboundedOrExpiredProofsAreRejected() throws Exception {
        var s = scope(); start(s, preview(s), "exit");
        for (var mutation : List.of("audience", "purpose", "type", "expiry", "longLifetime", "jti", "embeddedKey")) {
            var original = SignedJWT.parse(proof(s, s.key(), "READ", null)); var claims = new JWTClaimsSet.Builder(original.getJWTClaimsSet());
            var header = new JWSHeader.Builder(original.getHeader());
            switch (mutation) {
                case "audience" -> claims.audience("ai-manager:configuration");
                case "purpose" -> claims.claim("purpose", "DEVICE_OPERATE");
                case "type" -> header.type(JOSEObjectType.JWT);
                case "expiry" -> claims.expirationTime(Date.from(clock.instant()));
                case "longLifetime" -> claims.expirationTime(Date.from(clock.instant().plusSeconds(301)));
                case "jti" -> claims.jwtID(null);
                case "embeddedKey" -> header.jwk(s.key().toPublicJWK());
            }
            var token = new SignedJWT(header.build(), claims.build()); token.sign(new ECDSASigner(s.key()));
            mvc.perform(get("/api/v1/device-cleanup/command").header("Authorization", "Bearer " + token.serialize())).andExpect(status().isUnauthorized());
        }
    }
    @Test void concurrentConfirmationsCreateOneOperationAndRevocationAudit() throws Exception {
        var s = scope(); var p = preview(s); String input = confirmation(p); var barrier = new java.util.concurrent.CyclicBarrier(2);
        var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            var first = pool.submit(() -> { barrier.await(5, java.util.concurrent.TimeUnit.SECONDS); return mvc.perform(post(path(s) + "/operations")
                .with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "first").contentType(MediaType.APPLICATION_JSON).content(input))
                .andReturn().getResponse().getStatus(); });
            var second = pool.submit(() -> { barrier.await(5, java.util.concurrent.TimeUnit.SECONDS); return mvc.perform(post(path(s) + "/operations")
                .with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "second").contentType(MediaType.APPLICATION_JSON).content(input))
                .andReturn().getResponse().getStatus(); });
            assertThat(List.of(first.get(15, java.util.concurrent.TimeUnit.SECONDS), second.get(15, java.util.concurrent.TimeUnit.SECONDS)))
                .containsExactlyInAnyOrder(201, 412);
            assertThat(database.queryForObject("SELECT COUNT(*) FROM deprovision_operations WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(1);
            assertThat(database.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='DEVICE_CREDENTIALS_REVOKED'", Integer.class, s.tenant())).isEqualTo(1);
        } finally { pool.shutdownNow(); }
    }
    @Test void cleanupKeysRemainPublicOnlyAndAuthenticatedAfterOrdinaryAccessIsRevoked() throws Exception {
        var s = scope(); start(s, preview(s), "exit");
        var ring = body(mvc.perform(get("/api/v1/device-cleanup/signing-keys").header("Authorization", "Bearer " + proof(s, s.key(), "READ", null)))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        var key = ECKey.parse(ring.get("keys").get(0).toString());
        assertThat(key.isPrivate()).isFalse(); assertThat(key.getKeyOperations()).containsExactly(KeyOperation.VERIFY);
        assertThat(key.computeThumbprint()).isEqualTo(SERVER_KEY.computeThumbprint());
        mvc.perform(get("/api/v1/device-cleanup/signing-keys").header("Authorization", "Bearer " + s.token())).andExpect(status().isUnauthorized());
    }
    @Test void boundedMaintenancePersistsUnreportedExpiredOperationsOnce() throws Exception {
        // The worker is global; drain unrelated test registrations before testing one bounded transition.
        clock.set(clock.instant().plusSeconds(604801));
        while (maintenance.expireDue(1000) > 0) { /* bounded batches over previous test fixtures */ }
        clock.set(Instant.parse("2026-10-09T03:00:00Z"));
        var s = scope(); var op = start(s, preview(s), "exit");
        clock.set(Instant.ofEpochMilli(op.get("notAfter").asLong()));
        assertThat(maintenance.expireDue(1)).isEqualTo(1);
        assertThat(maintenance.expireDue(1)).isZero();
        assertThat(database.queryForObject("SELECT state FROM deprovision_operations WHERE tenant_id=? AND id=?", String.class,
            s.tenant(), op.get("id").asText())).isEqualTo("CLEANUP_EXPIRED");
        assertThat(database.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='CLEANUP_WINDOW_EXPIRED'", Integer.class,
            s.tenant())).isEqualTo(1);
    }
    @Test void normalExitInvalidatesTheExistingApprovedWindowInTheSameTransaction() throws Exception {
        var s = scope(); String base = "/api/v1/tenants/" + s.tenant();
        String app = body(mvc.perform(post(base + "/applications").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON)
            .content("{\"displayName\":\"游戏\",\"platform\":\"ANDROID\",\"packageName\":\"org.example.game\",\"profile\":\"PRIMARY\",\"signingDigests\":[\"" + "a".repeat(64) + "\"]}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String policy = body(mvc.perform(post(base + "/policies").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("name", "游戏", "kind", "POLICY", "rules", List.of(
                Map.of("id", "game", "kind", "APP_LAUNCH", "effect", "DENY", "applicationId", app, "required", true))))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        var preview = body(mvc.perform(post(base + "/policies/" + policy + "/previews").with(actor(s.owner())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("deviceIds", List.of(s.device())))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        String version = body(mvc.perform(post(base + "/policies/" + policy + "/publications").with(actor(s.owner())).header("If-Match", "\"0\"")
            .header("Idempotency-Key", "policy").contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of(
                "previewId", preview.get("id").asText(), "previewHash", preview.get("hash").asText(), "mode", "CONFIGURE_ONLY"))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("versionId").asText();
        String request = body(mvc.perform(post(base + "/access-requests").with(actor(s.child())).header("Idempotency-Key", "request")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("deviceId", s.device(), "policyId", policy,
                "baseVersionId", version, "applicationId", app, "ruleIds", List.of("game"), "requestedWindowSeconds", 300))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        mvc.perform(post(base + "/access-requests/" + request + "/decisions").with(actor(s.owner())).header("If-Match", "\"0\"")
            .header("Idempotency-Key", "approve").contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":120}"))
            .andExpect(status().isOk());
        start(s, preview(s), "exit");
        assertThat(database.queryForObject("SELECT state FROM access_requests WHERE tenant_id=? AND id=?", String.class, s.tenant(), request)).isEqualTo("REVOKED");
        assertThat(database.queryForObject("SELECT reason_code FROM access_requests WHERE tenant_id=? AND id=?", String.class, s.tenant(), request))
            .isEqualTo("DEVICE_REGISTRATION_INACTIVE");
    }
    @Test void persistenceFailureRollsBackRevocationCommandJournalAndAuditTogether() throws Exception {
        var s = scope(); var p = preview(s);
        // A test-only database constraint causes a failure after the actual fleet revocation.
        // Tenant IDs are server-generated UUIDs; no user-controlled SQL is interpolated.
        database.execute("ALTER TABLE deprovision_operations ADD CONSTRAINT cleanup_failure_fixture CHECK (tenant_id <> '" + s.tenant() + "')");
        try {
            String failure = mvc.perform(post(path(s) + "/operations").with(actor(s.owner())).header("If-Match", "\"0\"")
                .header("Idempotency-Key", "atomic").contentType(MediaType.APPLICATION_JSON).content(confirmation(p)))
                .andExpect(status().isInternalServerError()).andReturn().getResponse().getContentAsString();
            assertThat(failure).doesNotContain("cleanup_failure_fixture", "INSERT INTO", s.key().getD().toString());
            assertThat(database.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?", String.class, s.tenant(), s.device())).isEqualTo("ACTIVE");
            assertThat(database.queryForObject("SELECT active FROM device_credential_scopes WHERE tenant_id=? AND registration_id=?", Boolean.class,
                s.tenant(), s.registration())).isTrue();
            assertThat(database.queryForObject("SELECT COUNT(*) FROM deprovision_operations WHERE tenant_id=?", Integer.class, s.tenant())).isZero();
            assertThat(database.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=? AND operation=?", Integer.class,
                s.tenant(), "device-exit:" + s.device())).isZero();
            assertThat(database.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='DEVICE_CREDENTIALS_REVOKED'", Integer.class, s.tenant())).isZero();
        } finally { database.execute("ALTER TABLE deprovision_operations DROP CONSTRAINT cleanup_failure_fixture"); }
        assertThat(start(s, p, "atomic").get("remoteAccess").asText()).isEqualTo("REVOKED");
    }
    @Test void incompatibleRegisteredKeyMetadataIsRejectedBeforeAnIrrecoverableRevocation() throws Exception {
        for (String mode : List.of("algorithm", "operations")) {
            var s = scope(); var builder = new ECKey.Builder(s.key().toPublicJWK());
            if ("algorithm".equals(mode)) builder.algorithm(JWSAlgorithm.ES384);
            else builder.keyOperations(Set.of(KeyOperation.SIGN));
            database.update("UPDATE devices SET public_key_jwk=? WHERE tenant_id=? AND id=?", builder.build().toJSONString(), s.tenant(), s.device());
            mvc.perform(post(path(s) + "/previews").with(actor(s.owner())).header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON).content("{\"action\":\"AGENT_UNENROLL\"}"))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("REGISTRATION_KEY_UNAVAILABLE"));
            assertThat(database.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?", String.class, s.tenant(), s.device())).isEqualTo("ACTIVE");
        }
    }
    private record Scope(String owner, String child, String tenant, String device, String registration, String token, ECKey key) {}
    @TestConfiguration static class TimeConfiguration { @Bean @Primary TestClock cleanupClock() { return new TestClock(); } }
    static class TestClock extends Clock {
        private final AtomicReference<Instant> now = new AtomicReference<>(Instant.parse("2026-10-09T03:00:00Z"));
        void set(Instant time) { now.set(time); }
        @Override public ZoneId getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(ZoneId zone) { return Clock.fixed(instant(), zone); }
        @Override public Instant instant() { return now.get(); }
    }
}
