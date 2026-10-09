package com.aimanager;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.ECDSASigner;
import com.nimbusds.jose.jwk.*;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import com.nimbusds.jwt.*;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import static org.assertj.core.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import static org.mockito.Mockito.when;
import static org.mockito.ArgumentMatchers.anyString;

/** Full registration journey with real ES256 proofs, independent opaque credentials and database state. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:fleet;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc
class FleetJourneyTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate database;
    @MockitoBean JwtDecoder decoder;

    @BeforeEach void rejectNonUserTokensInUserChain() {
        when(decoder.decode(anyString())).thenThrow(new BadJwtException("Invalid user token"));
    }

    private RequestPostProcessor actor(String name) {
        return jwt().jwt(token -> token.subject(name).claim("auth_time", Instant.now().getEpochSecond())
            .claim("amr", List.of("pwd", "otp")).claim("email", name + "@example.test").claim("email_verified", true))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }

    private Scope scope() throws Exception {
        String owner = "fleet-owner-" + UUID.randomUUID();
        var family = mvc.perform(post("/api/v1/tenants").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"设备家庭\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse();
        String tenant = mapper.readTree(family.getContentAsString()).get("id").asText();
        var child = mvc.perform(post("/api/v1/tenants/{id}/subjects", tenant).with(actor(owner))
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse();
        return new Scope(owner, tenant, mapper.readTree(child.getContentAsString()).get("id").asText());
    }

    private String enrollmentPayload(Scope scope, String mode) throws Exception {
        return mapper.writeValueAsString(Map.of("subjectId", scope.subject(), "requestedMode", mode, "platform", "ANDROID"));
    }

    private JsonNode ticket(Scope scope) throws Exception {
        var response = mvc.perform(post("/api/v1/tenants/{tenant}/enrollments", scope.tenant()).with(actor(scope.owner()))
            .contentType(MediaType.APPLICATION_JSON).content(enrollmentPayload(scope, "BYOD")))
            .andExpect(status().isCreated()).andReturn().getResponse();
        return mapper.readTree(response.getContentAsString());
    }

    private String claimPayload(JsonNode ticket, ECKey signingKey, ECKey advertisedKey) throws Exception {
        return claimPayload(ticket, signingKey, advertisedKey, builder -> {});
    }

    private String claimPayload(JsonNode ticket, ECKey signingKey, ECKey advertisedKey,
                                java.util.function.Consumer<JWTClaimsSet.Builder> customize) throws Exception {
        String enrollment = ticket.get("id").asText();
        String nonce = ticket.get("token").asText();
        var builder = new JWTClaimsSet.Builder().subject(enrollment).audience("ai-manager:enrollment-claim")
            .claim("nonce", nonce).issueTime(Date.from(Instant.now())).expirationTime(Date.from(Instant.now().plusSeconds(90)))
            .jwtID(UUID.randomUUID().toString());
        customize.accept(builder);
        var proof = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.ES256).type(JOSEObjectType.JWT).build(), builder.build());
        proof.sign(new ECDSASigner(signingKey));
        return mapper.writeValueAsString(Map.of("enrollmentId", enrollment, "token", nonce,
            "publicKeyJwk", advertisedKey.toPublicJWK().toJSONString(), "proof", proof.serialize(),
            "displayName", "孩子的手机", "osVersion", "15"));
    }

    private JsonNode claim(JsonNode ticket) throws Exception {
        var key = new ECKeyGenerator(Curve.P_256).generate();
        var response = mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON)
            .content(claimPayload(ticket, key, key))).andExpect(status().isCreated()).andReturn().getResponse();
        return mapper.readTree(response.getContentAsString());
    }

    private void confirm(Scope scope, JsonNode ticket, JsonNode claim) throws Exception {
        mvc.perform(post("/api/v1/tenants/{tenant}/enrollments/{id}/confirm", scope.tenant(), ticket.get("id").asText())
            .with(actor(scope.owner())).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("pairingCode", claim.get("pairingCode").asText()))))
            .andExpect(status().isOk()).andExpect(jsonPath("$.managementMode").value("BYOD"))
            .andExpect(jsonPath("$.controlLevel").value("LIMITED"));
    }

    private String heartbeat(long sequence, boolean supported) throws Exception {
        return mapper.writeValueAsString(Map.of("sequence", sequence, "agentVersion", "1.0.0", "capabilities",
            List.of(Map.of("key", "managed.app_policy", "reportedSupported", supported, "grantStatus", "GRANTED"))));
    }

    @Test void deviceMustBeConfirmedBeforeIndependentCredentialCanOperate() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket);
        String credential = claim.get("credential").asText();
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", "Bearer " + credential)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, true))).andExpect(status().isUnauthorized());
        confirm(scope, ticket, claim);
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", "Bearer " + credential)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.registrationId").value(claim.get("registrationId").asText()));
        mvc.perform(get("/api/v1/tenants").header("Authorization", "Bearer " + credential)).andExpect(status().isUnauthorized());
        mvc.perform(get("/api/v1/tenants/{tenant}/devices/{device}/capabilities", scope.tenant(), claim.get("deviceId").asText())
            .with(actor(scope.owner()))).andExpect(status().isOk())
            .andExpect(jsonPath("$.items[0].status").value("UNSUPPORTED"))
            .andExpect(jsonPath("$.items[0].effectiveSupported").value(false));
    }

    @Test void enrollmentCannotBindAnotherTenantSubject() throws Exception {
        var a = scope(); var b = scope();
        mvc.perform(post("/api/v1/tenants/{tenant}/enrollments", a.tenant()).with(actor(a.owner()))
            .contentType(MediaType.APPLICATION_JSON).content(enrollmentPayload(new Scope(a.owner(), a.tenant(), b.subject()), "BYOD")))
            .andExpect(status().isForbidden());
    }

    @Test void requestedStrongModeCannotBeAdvertisedWithoutEmmExecution() throws Exception {
        var scope = scope();
        mvc.perform(post("/api/v1/tenants/{tenant}/enrollments", scope.tenant()).with(actor(scope.owner()))
            .contentType(MediaType.APPLICATION_JSON).content(enrollmentPayload(scope, "FULLY_MANAGED")))
            .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.errorCode").value("CAPABILITY_UNSUPPORTED"));
    }

    @Test void expiredAndReusedTicketsCannotCreateNewRegistrations() throws Exception {
        var scope = scope(); var expired = ticket(scope);
        database.update("UPDATE device_enrollments SET expires_at=0 WHERE id=?", expired.get("id").asText());
        var key = new ECKeyGenerator(Curve.P_256).generate();
        mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(claimPayload(expired, key, key)))
            .andExpect(status().isConflict());
        var ticket = ticket(scope); claim(ticket);
        mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(claimPayload(ticket, key, key)))
            .andExpect(status().isConflict());
    }

    @Test void wrongPublicKeyProofDoesNotConsumeTicket() throws Exception {
        var scope = scope(); var ticket = ticket(scope);
        var key = new ECKeyGenerator(Curve.P_256).generate(); var other = new ECKeyGenerator(Curve.P_256).generate();
        mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(claimPayload(ticket, key, other)))
            .andExpect(status().isForbidden());
        claim(ticket);
    }

    @Test void pairingFailuresPersistAndLockConfirmation() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket);
        for (int attempt = 0; attempt < 5; attempt++) {
            mvc.perform(post("/api/v1/tenants/{tenant}/enrollments/{id}/confirm", scope.tenant(), ticket.get("id").asText())
                .with(actor(scope.owner())).contentType(MediaType.APPLICATION_JSON).content("{\"pairingCode\":\"ZZZZZZZZ\"}"))
                .andExpect(status().isForbidden());
        }
        mvc.perform(post("/api/v1/tenants/{tenant}/enrollments/{id}/confirm", scope.tenant(), ticket.get("id").asText())
            .with(actor(scope.owner())).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("pairingCode", claim.get("pairingCode").asText()))))
            .andExpect(status().isConflict());
        assertThat(database.queryForObject("SELECT pairing_failures FROM device_enrollments WHERE id=?", Integer.class,
            ticket.get("id").asText())).isEqualTo(5);
    }

    @Test void revokedInviterAndArchivedSubjectCannotFinishRegistration() throws Exception {
        var scope = scope(); var ticket = ticket(scope);
        database.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", scope.tenant());
        var key = new ECKeyGenerator(Curve.P_256).generate();
        mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(claimPayload(ticket, key, key)))
            .andExpect(status().isForbidden());
        var other = scope(); var otherTicket = ticket(other);
        database.update("UPDATE subjects SET archived_at=1 WHERE tenant_id=? AND id=?", other.tenant(), other.subject());
        mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(claimPayload(otherTicket, key, key)))
            .andExpect(status().isForbidden());
    }

    @Test void secretsAreNotPersistedOrExposedInManagementReads() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket);
        String hash = database.queryForObject("SELECT token_hash FROM device_enrollments WHERE id=?", String.class, ticket.get("id").asText());
        assertThat(hash).hasSize(64).isNotEqualTo(ticket.get("token").asText());
        String credentialHash = database.queryForObject("SELECT token_hash FROM device_credentials WHERE registration_id=?", String.class,
            claim.get("registrationId").asText());
        assertThat(credentialHash).hasSize(64).isNotEqualTo(claim.get("credential").asText());
        mvc.perform(get("/api/v1/tenants/{tenant}/enrollments/{id}", scope.tenant(), ticket.get("id").asText()).with(actor(scope.owner())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.token").doesNotExist()).andExpect(jsonPath("$.pairingCode").doesNotExist());
    }

    @Test void heartbeatRetryIsIdempotentAndCannotRefreshEvidenceByReplay() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket); confirm(scope, ticket, claim);
        String auth = "Bearer " + claim.get("credential").asText();
        var first = mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", auth)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, true))).andExpect(status().isOk()).andReturn().getResponse();
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", auth)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, true)))
            .andExpect(status().isOk()).andExpect(content().json(first.getContentAsString()));
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", auth)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, false)))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("HEARTBEAT_SEQUENCE_CONFLICT"));
    }

    @Test void deviceRotationAndRevocationInvalidateOldCredentials() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket); confirm(scope, ticket, claim);
        String original = claim.get("credential").asText();
        var response = mvc.perform(post("/api/v1/device-api/credentials/rotate").header("Authorization", "Bearer " + original))
            .andExpect(status().isOk()).andReturn().getResponse();
        String next = mapper.readTree(response.getContentAsString()).get("credential").asText();
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", "Bearer " + original)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, false))).andExpect(status().isOk());
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", "Bearer " + next)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(2, false))).andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/device-api/credentials/activate").header("Authorization", "Bearer " + next))
            .andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/device-api/credentials/activate").header("Authorization", "Bearer " + next))
            .andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", "Bearer " + original)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, false))).andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/tenants/{tenant}/devices/{id}/revoke", scope.tenant(), claim.get("deviceId").asText())
            .with(actor(scope.owner()))).andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", "Bearer " + next)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, false))).andExpect(status().isUnauthorized());
    }

    @Test void managementCannotReadAnotherTenantDeviceOrCancelForeignEnrollment() throws Exception {
        var a = scope(); var b = scope(); var ticket = ticket(a); var claim = claim(ticket);
        mvc.perform(get("/api/v1/tenants/{tenant}/devices/{id}", b.tenant(), claim.get("deviceId").asText()).with(actor(b.owner())))
            .andExpect(status().isForbidden());
        mvc.perform(delete("/api/v1/tenants/{tenant}/enrollments/{id}", b.tenant(), ticket.get("id").asText()).with(actor(b.owner())))
            .andExpect(status().isForbidden());
    }

    @Test void cancellationPreventsClaimAndPendingCredentialActivation() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket);
        mvc.perform(delete("/api/v1/tenants/{tenant}/enrollments/{id}", scope.tenant(), ticket.get("id").asText()).with(actor(scope.owner())))
            .andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/tenants/{tenant}/enrollments/{id}/confirm", scope.tenant(), ticket.get("id").asText())
            .with(actor(scope.owner())).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("pairingCode", claim.get("pairingCode").asText()))))
            .andExpect(status().isConflict());
    }

    @Test void lostRotationResponseCanBeCancelledWithoutLosingOldCredential() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket); confirm(scope, ticket, claim);
        String auth = "Bearer " + claim.get("credential").asText();
        var response = mvc.perform(post("/api/v1/device-api/credentials/rotate").header("Authorization", auth))
            .andExpect(status().isOk()).andReturn().getResponse();
        String abandoned = mapper.readTree(response.getContentAsString()).get("credential").asText();
        mvc.perform(post("/api/v1/device-api/credentials/rotate").header("Authorization", auth)).andExpect(status().isConflict());
        mvc.perform(post("/api/v1/device-api/credentials/rotation/cancel").header("Authorization", auth))
            .andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/device-api/credentials/activate").header("Authorization", "Bearer " + abandoned))
            .andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", auth)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, false))).andExpect(status().isOk());
        mvc.perform(post("/api/v1/device-api/credentials/rotate").header("Authorization", auth)).andExpect(status().isOk());
    }

    @Test void staleAndUnknownCapabilitiesNeverBecomeVerifiedSupport() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket); confirm(scope, ticket, claim);
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", "Bearer " + claim.get("credential").asText())
            .contentType(MediaType.APPLICATION_JSON).content("{\"sequence\":1,\"agentVersion\":\"1\",\"capabilities\":["
                + "{\"key\":\"usage.report\",\"reportedSupported\":true,\"grantStatus\":\"GRANTED\"},"
                + "{\"key\":\"vendor.secret_privilege\",\"reportedSupported\":true,\"grantStatus\":\"GRANTED\"}]}"))
            .andExpect(status().isOk());
        database.update("UPDATE device_capabilities SET checked_at=0 WHERE capability_key='usage.report' AND device_id=?",
            claim.get("deviceId").asText());
        var response = mvc.perform(get("/api/v1/tenants/{tenant}/devices/{id}/capabilities", scope.tenant(), claim.get("deviceId").asText())
            .with(actor(scope.owner()))).andExpect(status().isOk()).andReturn().getResponse();
        var items = mapper.readTree(response.getContentAsString()).get("items");
        for (var item : items) {
            assertThat(item.get("effectiveSupported").asBoolean()).isFalse();
            if (item.get("key").asText().equals("usage.report")) assertThat(item.get("status").asText()).isEqualTo("STALE");
            if (item.get("key").asText().equals("vendor.secret_privilege")) assertThat(item.get("status").asText()).isEqualTo("UNKNOWN");
        }
    }

    @Test void proofPurposeNonceAndExpirationAreBoundToEnrollment() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var key = new ECKeyGenerator(Curve.P_256).generate();
        List<java.util.function.Consumer<JWTClaimsSet.Builder>> mutations = List.of(
            builder -> builder.audience("another-purpose"), builder -> builder.claim("nonce", "not-this-ticket"),
            builder -> builder.expirationTime(Date.from(Instant.now().minusSeconds(120))),
            builder -> builder.subject(UUID.randomUUID().toString()));
        for (var mutation : mutations) {
            mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON)
                .content(claimPayload(ticket, key, key, mutation))).andExpect(status().isForbidden());
        }
        var privatePayload = (com.fasterxml.jackson.databind.node.ObjectNode) mapper.readTree(claimPayload(ticket, key, key));
        privatePayload.put("publicKeyJwk", key.toJSONString());
        mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(privatePayload.toString()))
            .andExpect(status().isForbidden());
        claim(ticket);
    }

    @Test void concurrentClaimsCreateExactlyOneRegistration() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var key = new ECKeyGenerator(Curve.P_256).generate();
        String payload = claimPayload(ticket, key, key);
        var executor = java.util.concurrent.Executors.newFixedThreadPool(2);
        var start = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.Callable<Integer> request = () -> {
            start.await();
            return mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(payload))
                .andReturn().getResponse().getStatus();
        };
        try {
            var first = executor.submit(request); var second = executor.submit(request); start.countDown();
            assertThat(List.of(first.get(10, java.util.concurrent.TimeUnit.SECONDS), second.get(10, java.util.concurrent.TimeUnit.SECONDS)))
                .containsExactlyInAnyOrder(201, 409);
        } finally { executor.shutdownNow(); }
        assertThat(database.queryForObject("SELECT COUNT(*) FROM devices WHERE tenant_id=?", Integer.class, scope.tenant())).isEqualTo(1);
    }

    @Test void expiredCredentialAndExpiredRotationCannotAuthenticate() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket); confirm(scope, ticket, claim);
        String original = "Bearer " + claim.get("credential").asText();
        var rotation = mvc.perform(post("/api/v1/device-api/credentials/rotate").header("Authorization", original))
            .andExpect(status().isOk()).andReturn().getResponse();
        var next = mapper.readTree(rotation.getContentAsString());
        database.update("UPDATE device_credential_rotations SET expires_at=0 WHERE new_id=?", next.get("credentialId").asText());
        mvc.perform(post("/api/v1/device-api/credentials/activate").header("Authorization", "Bearer " + next.get("credential").asText()))
            .andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/device-api/credentials/rotate").header("Authorization", original)).andExpect(status().isOk());
        database.update("UPDATE device_credentials SET expires_at=0 WHERE registration_id=?", claim.get("registrationId").asText());
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", original)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, false))).andExpect(status().isUnauthorized());
    }

    @Test void staleMfaAndChildRoleCannotCreateEnrollment() throws Exception {
        var scope = scope();
        var stale = jwt().jwt(token -> token.subject(scope.owner()).claim("auth_time", 1L).claim("amr", List.of("pwd", "otp")));
        mvc.perform(post("/api/v1/tenants/{tenant}/enrollments", scope.tenant()).with(stale)
            .contentType(MediaType.APPLICATION_JSON).content(enrollmentPayload(scope, "BYOD"))).andExpect(status().isUnauthorized());
        String childName = "fleet-child-" + UUID.randomUUID();
        var invite = mvc.perform(post("/api/v1/tenants/{tenant}/invitations", scope.tenant()).with(actor(scope.owner()))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("recipientEmail", childName + "@example.test",
                "role", "CHILD", "subjectId", scope.subject())))).andExpect(status().isCreated()).andReturn().getResponse();
        String inviteToken = mapper.readTree(invite.getContentAsString()).get("token").asText();
        mvc.perform(post("/api/v1/invitations/accept").with(actor(childName)).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("token", inviteToken)))).andExpect(status().isOk());
        mvc.perform(post("/api/v1/tenants/{tenant}/enrollments", scope.tenant()).with(actor(childName))
            .contentType(MediaType.APPLICATION_JSON).content(enrollmentPayload(scope, "BYOD"))).andExpect(status().isForbidden());
        var ticket = ticket(scope); var claim = claim(ticket);
        mvc.perform(get("/api/v1/tenants/{tenant}/devices/{id}", scope.tenant(), claim.get("deviceId").asText()).with(actor(childName)))
            .andExpect(status().isOk());
        mvc.perform(post("/api/v1/tenants/{tenant}/enrollments/{id}/confirm", scope.tenant(), ticket.get("id").asText()).with(actor(childName))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("pairingCode", claim.get("pairingCode").asText()))))
            .andExpect(status().isForbidden());
    }

    @Test void staleHeartbeatAndDuplicateCapabilityKeysAreRejected() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var claim = claim(ticket); confirm(scope, ticket, claim);
        String auth = "Bearer " + claim.get("credential").asText();
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", auth)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(2, false))).andExpect(status().isOk());
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", auth)
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, false))).andExpect(status().isConflict());
        var payload = (com.fasterxml.jackson.databind.node.ObjectNode) mapper.readTree(heartbeat(3, false));
        var capabilities = (com.fasterxml.jackson.databind.node.ArrayNode) payload.get("capabilities");
        capabilities.add(capabilities.get(0).deepCopy());
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", auth)
            .contentType(MediaType.APPLICATION_JSON).content(payload.toString())).andExpect(status().isBadRequest());
    }

    @Test void lostClaimResponseCanOnlyBeRecoveredByOriginalKeyBeforeConfirmation() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var key = new ECKeyGenerator(Curve.P_256).generate();
        var response = mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(claimPayload(ticket, key, key)))
            .andExpect(status().isCreated()).andReturn().getResponse();
        var first = mapper.readTree(response.getContentAsString());
        var other = new ECKeyGenerator(Curve.P_256).generate();
        var wrongKey = recoveryPayload(ticket, other);
        mvc.perform(post("/api/v1/enrollment-claims/recover").contentType(MediaType.APPLICATION_JSON).content(wrongKey))
            .andExpect(status().isForbidden());
        String payload = recoveryPayload(ticket, key);
        var recoveredResponse = mvc.perform(post("/api/v1/enrollment-claims/recover").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isOk()).andReturn().getResponse();
        var recovered = mapper.readTree(recoveredResponse.getContentAsString());
        assertThat(recovered.get("registrationId").asText()).isEqualTo(first.get("registrationId").asText());
        assertThat(recovered.get("credential").asText()).isNotEqualTo(first.get("credential").asText());
        mvc.perform(post("/api/v1/enrollment-claims/recover").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isConflict());
        confirm(scope, ticket, recovered);
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", "Bearer " + first.get("credential").asText())
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, false))).andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/device-api/heartbeats").header("Authorization", "Bearer " + recovered.get("credential").asText())
            .contentType(MediaType.APPLICATION_JSON).content(heartbeat(1, false))).andExpect(status().isOk());
        mvc.perform(post("/api/v1/enrollment-claims/recover").contentType(MediaType.APPLICATION_JSON).content(recoveryPayload(ticket, key)))
            .andExpect(status().isConflict());
    }

    @Test void pendingRecoveryCannotResetPairingFailuresOrContinueWithoutBound() throws Exception {
        var scope = scope(); var ticket = ticket(scope); var key = new ECKeyGenerator(Curve.P_256).generate();
        mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(claimPayload(ticket, key, key)))
            .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/tenants/{tenant}/enrollments/{id}/confirm", scope.tenant(), ticket.get("id").asText())
            .with(actor(scope.owner())).contentType(MediaType.APPLICATION_JSON).content("{\"pairingCode\":\"ZZZZZZZZ\"}"))
            .andExpect(status().isForbidden());
        for (int attempt = 0; attempt < 3; attempt++) {
            mvc.perform(post("/api/v1/enrollment-claims/recover").contentType(MediaType.APPLICATION_JSON).content(recoveryPayload(ticket, key)))
                .andExpect(status().isOk());
        }
        mvc.perform(post("/api/v1/enrollment-claims/recover").contentType(MediaType.APPLICATION_JSON).content(recoveryPayload(ticket, key)))
            .andExpect(status().isConflict());
        assertThat(database.queryForObject("SELECT pairing_failures FROM device_enrollments WHERE id=?", Integer.class, ticket.get("id").asText()))
            .isEqualTo(1);
    }

    private String recoveryPayload(JsonNode ticket, ECKey key) throws Exception {
        var payload = (com.fasterxml.jackson.databind.node.ObjectNode) mapper.readTree(claimPayload(ticket, key, key,
            builder -> builder.audience("ai-manager:enrollment-recover")));
        payload.remove(List.of("displayName", "osVersion"));
        return payload.toString();
    }

    private record Scope(String owner, String tenant, String subject) {}
}
