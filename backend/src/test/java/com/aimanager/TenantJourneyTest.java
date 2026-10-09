package com.aimanager;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.http.MediaType;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import java.time.Instant;
import java.util.List;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Runs the actual HTTP, authorization, transaction and database layers; only issuer is external. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:journey;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "spring.flyway.enabled=true", "springdoc.api-docs.enabled=true"
})
@AutoConfigureMockMvc
class TenantJourneyTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate database;
    @MockitoBean JwtDecoder decoder;

    private RequestPostProcessor actor(String id, boolean canCreateTenant) {
        return jwt().jwt(token -> token.subject(id).claim("email", id + "@example.test")
            .claim("email_verified", true).claim("auth_time", Instant.now().getEpochSecond())
            .claim("amr", List.of("pwd", "otp"))).authorities(new SimpleGrantedAuthority(
            canCreateTenant ? "SCOPE_tenant:create" : "SCOPE_profile:read"));
    }

    private JsonNode createFamily(String owner) throws Exception {
        var response = mvc.perform(post("/api/v1/tenants").with(actor(owner, true)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse();
        return mapper.readTree(response.getContentAsString());
    }

    @Test void adultCreatesFamilyAndChildWithAudit() throws Exception {
        var tenantId = createFamily("owner-a").get("id").asText();
        mvc.perform(post("/api/v1/tenants/{id}/subjects", tenantId).with(actor("owner-a", true)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"小明\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andExpect(jsonPath("$.nickname").value("小明"));
        mvc.perform(get("/api/v1/tenants/{id}/subjects", tenantId).with(actor("owner-a", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(1));
        mvc.perform(get("/api/v1/tenants/{id}/audit-events", tenantId).with(actor("owner-a", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(2));
    }

    @Test void strangerCannotReadOrMutateTenant() throws Exception {
        var id = createFamily("owner-b").get("id").asText();
        mvc.perform(get("/api/v1/tenants/{id}/subjects", id).with(actor("stranger", true)))
            .andExpect(status().isForbidden()).andExpect(jsonPath("$.errorCode").value("SCOPE_DENIED"));
        mvc.perform(post("/api/v1/tenants/{id}/subjects", id).with(actor("stranger", true)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"越权\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isForbidden());
    }

    @Test void childCannotCreateTenant() throws Exception {
        mvc.perform(post("/api/v1/tenants").with(actor("child-token", false)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"越权家庭\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isForbidden());
    }

    @Test void invalidTimezoneIsRejected() throws Exception {
        mvc.perform(post("/api/v1/tenants").with(actor("owner-c", true)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"Unknown/Zone\"}"))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("INVALID_TIME_ZONE"));
    }

    @Test void anonymousCannotAccessManagementApis() throws Exception {
        mvc.perform(get("/api/v1/tenants")).andExpect(status().isUnauthorized());
    }

    @Test void tenantsListDoesNotLeakOtherFamilies() throws Exception {
        createFamily("isolated-owner");
        mvc.perform(get("/api/v1/tenants").with(actor("no-memberships", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(0));
    }

    @Test void emptyChildNicknameIsRejectedWithoutInsertingRecord() throws Exception {
        var id = createFamily("validation-owner").get("id").asText();
        mvc.perform(post("/api/v1/tenants/{id}/subjects", id).with(actor("validation-owner", true)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"   \",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("VALIDATION_FAILED"));
        mvc.perform(get("/api/v1/tenants/{id}/subjects", id).with(actor("validation-owner", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(0));
    }

    @Test void unrecognizedPrivilegeFieldIsNotSilentlyAccepted() throws Exception {
        mvc.perform(post("/api/v1/tenants").with(actor("mass-assignment-owner", true)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\",\"role\":\"PLATFORM_ADMIN\"}"))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("MALFORMED_REQUEST"));
    }

    @Test void revokedMembershipCannotUseStillValidJwt() throws Exception {
        var id = createFamily("revoked-owner").get("id").asText();
        database.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_id=?",
            id, "revoked-owner");
        mvc.perform(get("/api/v1/tenants/{id}/subjects", id).with(actor("revoked-owner", true)))
            .andExpect(status().isForbidden());
    }

    @Test void childSeesOnlyAssignedSubjectAndCannotAddAnother() throws Exception {
        var id = createFamily("scope-owner").get("id").asText();
        var response = mvc.perform(post("/api/v1/tenants/{id}/subjects", id).with(actor("scope-owner", true)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"本人\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse();
        var subjectId = mapper.readTree(response.getContentAsString()).get("id").asText();
        mvc.perform(post("/api/v1/tenants/{id}/subjects", id).with(actor("scope-owner", true)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"其他孩子\",\"ageBand\":\"AGE_13_17\"}"))
            .andExpect(status().isCreated());
        var invitationResponse = mvc.perform(post("/api/v1/tenants/{id}/invitations", id).with(actor("scope-owner", true))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(java.util.Map.of(
                "recipientEmail", "assigned-child@example.test", "role", "CHILD", "subjectId", subjectId))))
            .andExpect(status().isCreated()).andReturn().getResponse();
        var childToken = mapper.readTree(invitationResponse.getContentAsString()).get("token").asText();
        mvc.perform(post("/api/v1/invitations/accept").with(actor("assigned-child", false))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(java.util.Map.of("token", childToken))))
            .andExpect(status().isOk());
        mvc.perform(get("/api/v1/tenants/{id}/subjects", id).with(actor("assigned-child", false)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(1))
            .andExpect(jsonPath("$.items[0].nickname").value("本人"));
        mvc.perform(post("/api/v1/tenants/{id}/subjects", id).with(actor("assigned-child", false)).with(csrf())
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"越权\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isForbidden());
    }

    private JsonNode invite(String tenantId, String owner, String email, String role) throws Exception {
        var response = mvc.perform(post("/api/v1/tenants/{id}/invitations", tenantId).with(actor(owner, true))
            .contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(java.util.Map.of("recipientEmail", email, "role", role))))
            .andExpect(status().isCreated()).andReturn().getResponse();
        return mapper.readTree(response.getContentAsString());
    }

    @Test void invitationAcceptanceAndMemberRevocationAreEffective() throws Exception {
        var id = createFamily("inviting-owner").get("id").asText();
        var token = invite(id, "inviting-owner", "co-parent@example.test", "GUARDIAN").get("token").asText();
        mvc.perform(post("/api/v1/invitations/accept").with(actor("co-parent", true))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(java.util.Map.of("token", token))))
            .andExpect(status().isOk());
        mvc.perform(get("/api/v1/tenants/{id}/subjects", id).with(actor("co-parent", true))).andExpect(status().isOk());
        mvc.perform(delete("/api/v1/tenants/{id}/members/{actor}", id, "co-parent").with(actor("inviting-owner", true)))
            .andExpect(status().isNoContent());
        mvc.perform(get("/api/v1/tenants/{id}/subjects", id).with(actor("co-parent", true))).andExpect(status().isForbidden());
        mvc.perform(post("/api/v1/invitations/accept").with(actor("co-parent", true))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(java.util.Map.of("token", token))))
            .andExpect(status().isConflict());
    }

    @Test void wrongRecipientCannotAcceptInvitation() throws Exception {
        var id = createFamily("email-owner").get("id").asText();
        var token = invite(id, "email-owner", "correct-parent@example.test", "GUARDIAN").get("token").asText();
        mvc.perform(post("/api/v1/invitations/accept").with(actor("other-parent", true))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(java.util.Map.of("token", token))))
            .andExpect(status().isForbidden());
    }

    @Test void expiredInvitationCannotCreateMembership() throws Exception {
        var id = createFamily("expiry-owner").get("id").asText();
        var invitation = invite(id, "expiry-owner", "late-parent@example.test", "GUARDIAN");
        database.update("UPDATE member_invitations SET expires_at=0 WHERE id=?", invitation.get("id").asText());
        mvc.perform(post("/api/v1/invitations/accept").with(actor("late-parent", true))
            .contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(java.util.Map.of("token", invitation.get("token").asText()))))
            .andExpect(status().isConflict());
    }

    @Test void revokedInviterCannotConferAuthorityThroughOldInvitation() throws Exception {
        var id = createFamily("old-inviter").get("id").asText();
        var token = invite(id, "old-inviter", "new-parent@example.test", "GUARDIAN").get("token").asText();
        database.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_id=?", id, "old-inviter");
        mvc.perform(post("/api/v1/invitations/accept").with(actor("new-parent", true))
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(java.util.Map.of("token", token))))
            .andExpect(status().isForbidden());
    }

    @Test void invitationRequiresRecentMfa() throws Exception {
        var id = createFamily("stepup-owner").get("id").asText();
        var stale = jwt().jwt(token -> token.subject("stepup-owner")
            .claim("auth_time", Instant.now().minusSeconds(3600).getEpochSecond()).claim("amr", List.of("pwd")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
        mvc.perform(post("/api/v1/tenants/{id}/invitations", id).with(stale)
            .contentType(MediaType.APPLICATION_JSON).content("{\"recipientEmail\":\"parent@example.test\",\"role\":\"GUARDIAN\"}"))
            .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    }

    @Test void ownerCannotBeRemovedBeforeExplicitOwnershipTransfer() throws Exception {
        var id = createFamily("protected-owner").get("id").asText();
        mvc.perform(delete("/api/v1/tenants/{id}/members/{actor}", id, "protected-owner").with(actor("protected-owner", true)))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("OWNER_TRANSFER_REQUIRED"));
    }

    @Test void familyCannotInviteInstitutionRole() throws Exception {
        var id = createFamily("role-owner").get("id").asText();
        mvc.perform(post("/api/v1/tenants/{id}/invitations", id).with(actor("role-owner", true))
            .contentType(MediaType.APPLICATION_JSON).content("{\"recipientEmail\":\"teacher@example.test\",\"role\":\"ORG_ADMIN\"}"))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("ROLE_NOT_APPLICABLE"));
    }

    @Test void retryingSubjectCreateIsIdempotentAndChangedPayloadConflicts() throws Exception {
        var id = createFamily("retry-owner").get("id").asText();
        String payload = "{\"nickname\":\"只创建一次\",\"ageBand\":\"AGE_7_12\"}";
        for (int attempt = 0; attempt < 2; attempt++) {
            mvc.perform(post("/api/v1/tenants/{id}/subjects", id).with(actor("retry-owner", true))
                .header("Idempotency-Key", "subject-request-1").contentType(MediaType.APPLICATION_JSON).content(payload))
                .andExpect(status().isCreated());
        }
        mvc.perform(get("/api/v1/tenants/{id}/subjects", id).with(actor("retry-owner", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(1));
        mvc.perform(post("/api/v1/tenants/{id}/subjects", id).with(actor("retry-owner", true))
            .header("Idempotency-Key", "subject-request-1").contentType(MediaType.APPLICATION_JSON)
            .content("{\"nickname\":\"不同请求\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
        mvc.perform(get("/api/v1/tenants/{id}/audit-events", id).with(actor("retry-owner", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(2));
    }

    @Test void retryingFamilyCreationReturnsSameResource() throws Exception {
        String payload = "{\"name\":\"重试家庭\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}";
        var first = mvc.perform(post("/api/v1/tenants").with(actor("retry-family-owner", true))
            .header("Idempotency-Key", "family-request-1").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        mvc.perform(post("/api/v1/tenants").with(actor("retry-family-owner", true))
            .header("Idempotency-Key", "family-request-1").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isCreated()).andExpect(content().json(first));
    }

    @Test void revokedMemberCannotRetrieveCachedIdempotentResponse() throws Exception {
        var id = createFamily("retry-revoked-owner").get("id").asText();
        String payload = "{\"nickname\":\"不能绕过撤销\",\"ageBand\":\"AGE_7_12\"}";
        mvc.perform(post("/api/v1/tenants/{id}/subjects", id).with(actor("retry-revoked-owner", true))
            .header("Idempotency-Key", "protected-response").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isCreated());
        database.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_id=?", id, "retry-revoked-owner");
        mvc.perform(post("/api/v1/tenants/{id}/subjects", id).with(actor("retry-revoked-owner", true))
            .header("Idempotency-Key", "protected-response").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isForbidden());
    }

    @Test void unknownApiRouteUsesNotFoundInsteadOfInternalError() throws Exception {
        mvc.perform(get("/api/v1/not-a-route").with(actor("routing-owner", true)))
            .andExpect(status().isNotFound()).andExpect(jsonPath("$.errorCode").value("RESOURCE_NOT_FOUND"));
    }

    @Test void otpAloneDoesNotCountAsMultiFactorAuthentication() throws Exception {
        var id = createFamily("otp-only-owner").get("id").asText();
        var singleFactor = jwt().jwt(token -> token.subject("otp-only-owner")
            .claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
        mvc.perform(post("/api/v1/tenants/{id}/invitations", id).with(singleFactor)
            .contentType(MediaType.APPLICATION_JSON).content("{\"recipientEmail\":\"parent@example.test\",\"role\":\"GUARDIAN\"}"))
            .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    }

    @Test void idempotencySerializesConcurrentFamilyCreation() throws Exception {
        var executor = java.util.concurrent.Executors.newFixedThreadPool(2);
        var start = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.Callable<String> request = () -> {
            start.await();
            return mvc.perform(post("/api/v1/tenants").with(actor("concurrent-owner", true))
                .header("Idempotency-Key", "concurrent-family").contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"并发家庭\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        };
        try {
            var first = executor.submit(request);
            var second = executor.submit(request);
            start.countDown();
            org.assertj.core.api.Assertions.assertThat(mapper.readTree(first.get(10, java.util.concurrent.TimeUnit.SECONDS)))
                .isEqualTo(mapper.readTree(second.get(10, java.util.concurrent.TimeUnit.SECONDS)));
        } finally {
            executor.shutdownNow();
        }
        mvc.perform(get("/api/v1/tenants").with(actor("concurrent-owner", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(1));
    }

    @Test void generatedContractDescribesImplementedRoutesUsingOpenApi31() throws Exception {
        mvc.perform(get("/v3/api-docs").with(actor("contract-reader", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.openapi").value("3.1.0"))
            .andExpect(jsonPath("$.paths['/api/v1/tenants'].post").exists())
            .andExpect(jsonPath("$.paths['/api/v1/tenants/{tenantId}/subjects'].get").exists())
            .andExpect(jsonPath("$.paths['/api/v1/enrollment-claims'].post.security").isEmpty())
            .andExpect(jsonPath("$.paths['/api/v1/device-api/heartbeats'].post.security[0].deviceBearer").exists());
    }

    @Test void caseInsensitiveDatabaseCollationCannotAliasOidcSubjects() throws Exception {
        database.execute("ALTER TABLE tenant_members ALTER COLUMN actor_id VARCHAR_IGNORECASE(255)");
        var id = createFamily("CaseSensitiveOwner").get("id").asText();
        mvc.perform(get("/api/v1/tenants/{id}/subjects", id).with(actor("casesensitiveowner", true)))
            .andExpect(status().isForbidden());
        mvc.perform(get("/api/v1/tenants").with(actor("casesensitiveowner", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(0));
    }

    @Test void idempotencyIdentityIsCaseSensitiveEvenWithCaseInsensitiveCollation() throws Exception {
        database.execute("ALTER TABLE idempotency_requests ALTER COLUMN actor_id VARCHAR_IGNORECASE(255)");
        String payload = "{\"name\":\"身份不能混同\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}";
        var first = mvc.perform(post("/api/v1/tenants").with(actor("CacheCaseOwner", true))
            .header("Idempotency-Key", "same-external-key").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        String firstId = mapper.readTree(first).get("id").asText();
        mvc.perform(post("/api/v1/tenants").with(actor("cachecaseowner", true))
            .header("Idempotency-Key", "same-external-key").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isCreated()).andExpect(jsonPath("$.id", org.hamcrest.Matchers.not(firstId)));
    }

    private JsonNode createSubject(String tenantId, String owner) throws Exception {
        var response = mvc.perform(post("/api/v1/tenants/{id}/subjects", tenantId).with(actor(owner, true))
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"原昵称\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse();
        return mapper.readTree(response.getContentAsString());
    }

    @Test void subjectUpdatesRequireVersionAndRejectStaleOverwrite() throws Exception {
        var tenantId = createFamily("edit-owner").get("id").asText();
        var subjectId = createSubject(tenantId, "edit-owner").get("id").asText();
        mvc.perform(get("/api/v1/tenants/{tenant}/subjects/{subject}", tenantId, subjectId).with(actor("edit-owner", true)))
            .andExpect(status().isOk()).andExpect(header().string("ETag", "\"0\""));
        String payload = "{\"nickname\":\"新昵称\",\"ageBand\":\"AGE_13_17\"}";
        mvc.perform(patch("/api/v1/tenants/{tenant}/subjects/{subject}", tenantId, subjectId).with(actor("edit-owner", true))
            .header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isOk()).andExpect(jsonPath("$.version").value(1)).andExpect(header().string("ETag", "\"1\""));
        mvc.perform(patch("/api/v1/tenants/{tenant}/subjects/{subject}", tenantId, subjectId).with(actor("edit-owner", true))
            .header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isPreconditionFailed()).andExpect(jsonPath("$.errorCode").value("RESOURCE_VERSION_CONFLICT"));
        mvc.perform(get("/api/v1/tenants/{tenant}/subjects/{subject}", tenantId, subjectId).with(actor("different-owner", true)))
            .andExpect(status().isForbidden());
    }

    @Test void subjectUpdateWithoutVersionIsRejected() throws Exception {
        var tenantId = createFamily("required-version-owner").get("id").asText();
        var subjectId = createSubject(tenantId, "required-version-owner").get("id").asText();
        mvc.perform(patch("/api/v1/tenants/{tenant}/subjects/{subject}", tenantId, subjectId)
            .with(actor("required-version-owner", true)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"nickname\":\"覆盖\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isPreconditionRequired()).andExpect(jsonPath("$.errorCode").value("VERSION_REQUIRED"));
    }

    @Test void archivingSubjectNeedsMfaAndDoesNotPretendToDeleteData() throws Exception {
        var tenantId = createFamily("archive-owner").get("id").asText();
        var subjectId = createSubject(tenantId, "archive-owner").get("id").asText();
        var weak = jwt().jwt(token -> token.subject("archive-owner").claim("auth_time", Instant.now().getEpochSecond())
            .claim("amr", List.of("pwd"))).authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
        mvc.perform(post("/api/v1/tenants/{tenant}/subjects/{subject}/archive", tenantId, subjectId).with(weak)
            .header("If-Match", "\"0\""))
            .andExpect(status().isUnauthorized());
        mvc.perform(post("/api/v1/tenants/{tenant}/subjects/{subject}/archive", tenantId, subjectId)
            .with(actor("archive-owner", true)).header("If-Match", "\"0\""))
            .andExpect(status().isNoContent());
        mvc.perform(get("/api/v1/tenants/{tenant}/subjects", tenantId).with(actor("archive-owner", true)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(0));
        org.assertj.core.api.Assertions.assertThat(database.queryForObject(
            "SELECT COUNT(*) FROM subjects WHERE tenant_id=? AND id=? AND archived_at IS NOT NULL", Integer.class,
            tenantId, subjectId)).isEqualTo(1);
    }

    @Test void revokedInvitationCannotBeAcceptedOrCancelledAcrossTenants() throws Exception {
        var tenantId = createFamily("cancel-owner").get("id").asText();
        var invitation = invite(tenantId, "cancel-owner", "cancelled-parent@example.test", "GUARDIAN");
        var otherId = createFamily("cancel-other-owner").get("id").asText();
        mvc.perform(delete("/api/v1/tenants/{tenant}/invitations/{invitation}", otherId, invitation.get("id").asText())
            .with(actor("cancel-other-owner", true))).andExpect(status().isForbidden());
        mvc.perform(delete("/api/v1/tenants/{tenant}/invitations/{invitation}", tenantId, invitation.get("id").asText())
            .with(actor("cancel-owner", true))).andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/invitations/accept").with(actor("cancelled-parent", true))
            .contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(java.util.Map.of("token", invitation.get("token").asText()))))
            .andExpect(status().isConflict());
    }

    @Test void piiAndSecretResponsesAreNotCacheable() throws Exception {
        mvc.perform(get("/api/v1/tenants").with(actor("cache-control-owner", true)))
            .andExpect(status().isOk()).andExpect(header().string("Cache-Control", org.hamcrest.Matchers.containsString("no-store")));
    }
}
