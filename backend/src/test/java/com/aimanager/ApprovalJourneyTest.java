package com.aimanager;

import com.aimanager.identity.ActorKeys;
import com.aimanager.approval.ApprovalMaintenance;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
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

/** Real controllers, SQL, scope, policy and audit. Device fixture is BYOD, not execution evidence. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:approval;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true",
    "manager.approval.expiry-job.enabled=false"
})
@AutoConfigureMockMvc
@Import(ApprovalJourneyTest.TimeConfiguration.class)
class ApprovalJourneyTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate database;
    @Autowired TestClock clock;
    @Autowired(required = false) ApprovalMaintenance maintenance;
    @MockitoBean JwtDecoder decoder;
    @BeforeEach void resetTime() { clock.set(Instant.parse("2026-10-09T02:00:00Z")); }
    private RequestPostProcessor actor(String name) {
        return jwt().jwt(t -> t.subject(name).claim("auth_time", clock.instant().getEpochSecond()).claim("amr", List.of("pwd", "otp")))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }
    private JsonNode body(String text) throws Exception { return mapper.readTree(text); }
    private String path(Scope s) { return "/api/v1/tenants/" + s.tenant() + "/access-requests"; }
    private Scope scope() throws Exception {
        String owner = "approval-owner-" + UUID.randomUUID(), child = "approval-child-" + UUID.randomUUID();
        String tenant = body(mvc.perform(post("/api/v1/tenants").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String subject = body(mvc.perform(post("/api/v1/tenants/" + tenant + "/subjects").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,'CHILD',?)",
            tenant, child, ActorKeys.key(child), subject);
        String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
        database.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)", tenant, device, subject, registration, "设备", clock.millis());
        String application = body(mvc.perform(post("/api/v1/tenants/" + tenant + "/applications").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("displayName", "游戏", "platform", "ANDROID", "packageName", "org.example.game",
                "profile", "PRIMARY", "signingDigests", List.of("a".repeat(64))))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String policy = body(mvc.perform(post("/api/v1/tenants/" + tenant + "/policies").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("name", "游戏规则", "kind", "POLICY", "rules", List.of(
                Map.of("id", "game", "kind", "APP_LAUNCH", "effect", "DENY", "applicationId", application, "required", true))))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        var s = new Scope(owner, child, tenant, subject, device, registration, application, policy, null);
        String version = publish(s).get("versionId").asText();
        return new Scope(owner, child, tenant, subject, device, registration, application, policy, version);
    }
    private JsonNode publish(Scope s) throws Exception {
        String policyPath = "/api/v1/tenants/" + s.tenant() + "/policies/" + s.policy();
        var preview = body(mvc.perform(post(policyPath + "/previews").with(actor(s.owner())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("deviceIds", List.of(s.device())))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        return body(mvc.perform(post(policyPath + "/publications").with(actor(s.owner())).header("If-Match", "\"0\"")
            .header("Idempotency-Key", UUID.randomUUID()).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("previewId", preview.get("id").asText(), "previewHash", preview.get("hash").asText(), "mode", "CONFIGURE_ONLY"))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    }
    private Map<String, Object> input(Scope s) {
        return Map.of("deviceId", s.device(), "policyId", s.policy(), "baseVersionId", s.version(), "applicationId", s.application(),
            "ruleIds", List.of("game"), "requestedWindowSeconds", 600, "reason", "想和同学一起玩一会");
    }
    private JsonNode request(Scope s, String key) throws Exception {
        return body(mvc.perform(post(path(s)).with(actor(s.child())).header("Idempotency-Key", key)
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(input(s))))
            .andExpect(status().isCreated()).andExpect(header().string("ETag", "\"0\""))
            .andReturn().getResponse().getContentAsString());
    }
    private JsonNode approve(Scope s, JsonNode request, String key) throws Exception {
        return body(mvc.perform(post(path(s) + "/" + request.get("id").asText() + "/decisions").with(actor(s.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON)
            .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":300}"))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }

    @Test void childRequestIsScopedAndReplaysWithoutDuplicatesOrReasonInAudit() throws Exception {
        var s = scope(); var first = request(s, "request"); var repeat = request(s, "request");
        assertThat(repeat).isEqualTo(first);
        assertThat(first.get("state").asText()).isEqualTo("PENDING");
        assertThat(first.get("registrationId").asText()).isEqualTo(s.registration());
        assertThat(database.queryForObject("SELECT COUNT(*) FROM access_requests WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(1);
        assertThat(database.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='ACCESS_REQUEST_CREATED'", Integer.class, s.tenant())).isEqualTo(1);
        mvc.perform(get(path(s)).with(actor(s.child()))).andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(1));
        var other = scope();
        mvc.perform(post(path(s)).with(actor(s.child())).header("Idempotency-Key", "foreign").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(input(other)))).andExpect(status().isForbidden());
        mvc.perform(get(path(s)).with(actor(other.owner()))).andExpect(status().isForbidden());
    }
    @Test void approvalIsBoundedAndNeverReportsActualUnlock() throws Exception {
        var s = scope(); var r = request(s, "create"); var approved = approve(s, r, "approve");
        assertThat(approved.get("state").asText()).isEqualTo("APPROVED_PENDING_DELIVERY");
        assertThat(approved.get("executionState").asText()).isEqualTo("NOT_ENFORCED");
        assertThat(approved.get("absoluteNotAfter").asLong()).isEqualTo(Instant.parse("2026-10-09T02:05:00Z").toEpochMilli());
        assertThat(approved.get("grantedWindowSeconds").asLong()).isEqualTo(300);
        assertThat(approved.has("approverId")).isFalse();
        assertThat(approved.get("version").asLong()).isEqualTo(1);
        assertThat(approve(s, r, "approve")).isEqualTo(approved);
        clock.set(Instant.parse("2026-10-09T02:05:00Z"));
        mvc.perform(get(path(s) + "/" + r.get("id").asText()).with(actor(s.child())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("EXPIRED"));
    }
    @Test void childCannotDecideAndParentNeedsRecentMfaAndStrongVersion() throws Exception {
        var s = scope(); var r = request(s, "create"); String target = path(s) + "/" + r.get("id").asText() + "/decisions";
        mvc.perform(post(target).with(actor(s.child())).header("If-Match", "\"0\"").header("Idempotency-Key", "child")
            .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"DENY\"}"))
            .andExpect(status().isForbidden());
        mvc.perform(post(target).with(jwt().jwt(t -> t.subject(s.owner()))).header("If-Match", "\"0\"").header("Idempotency-Key", "no-mfa")
            .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"DENY\"}"))
            .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
        mvc.perform(post(target).with(actor(s.owner())).header("Idempotency-Key", "no-etag").contentType(MediaType.APPLICATION_JSON)
            .content("{\"decision\":\"DENY\"}")).andExpect(status().is(428));
        approve(s, r, "approve");
        mvc.perform(post(target).with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "changed")
            .contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"DENY\"}"))
            .andExpect(status().isPreconditionFailed());
    }
    @Test void requestCannotOutliveDeadlineOrIgnoreNewPolicyBaseline() throws Exception {
        var s = scope(); var r = request(s, "create"); publish(s);
        mvc.perform(get(path(s) + "/" + r.get("id").asText()).with(actor(s.child())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("INVALIDATED"))
            .andExpect(jsonPath("$.reasonCode").value("BASELINE_CHANGED"));
        var fresh = scope(); var waiting = request(fresh, "create"); clock.set(clock.instant().plusSeconds(1800));
        mvc.perform(post(path(fresh) + "/" + waiting.get("id").asText() + "/decisions").with(actor(fresh.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "late").contentType(MediaType.APPLICATION_JSON)
            .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":60}"))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("ACCESS_REQUEST_NOT_PENDING"));
    }
    @Test void cancelDenyAndRevokeHaveDifferentSemanticsAndImmutableDecision() throws Exception {
        var s = scope(); var r = request(s, "create"); String resource = path(s) + "/" + r.get("id").asText();
        mvc.perform(post(resource + "/cancel").with(actor(s.child())).header("If-Match", "\"0\"").header("Idempotency-Key", "cancel"))
            .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("CANCELLED"));
        var deniedScope = scope(); var denied = request(deniedScope, "create");
        mvc.perform(post(path(deniedScope) + "/" + denied.get("id").asText() + "/decisions").with(actor(deniedScope.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "deny").contentType(MediaType.APPLICATION_JSON)
            .content("{\"decision\":\"DENY\",\"reasonCode\":\"NOT_NOW\"}"))
            .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("DENIED"));
        var revokedScope = scope(); var revoked = request(revokedScope, "create"); approve(revokedScope, revoked, "approve");
        mvc.perform(post(path(revokedScope) + "/" + revoked.get("id").asText() + "/revoke").with(actor(revokedScope.owner()))
            .header("If-Match", "\"1\"").header("Idempotency-Key", "revoke"))
            .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("REVOKED"))
            .andExpect(jsonPath("$.executionState").value("NOT_ENFORCED"));
        assertThat(database.queryForObject("SELECT COUNT(*) FROM access_request_decisions WHERE tenant_id=?", Integer.class, revokedScope.tenant())).isEqualTo(1);
    }
    @Test void pendingDuplicatesCooldownAndPayloadConflictsAreControlled() throws Exception {
        var s = scope(); var r = request(s, "same");
        mvc.perform(post(path(s)).with(actor(s.child())).header("Idempotency-Key", "different").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(input(s))))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("ACCESS_REQUEST_PENDING"));
        var changed = new HashMap<>(input(s)); changed.put("requestedWindowSeconds", 601);
        mvc.perform(post(path(s)).with(actor(s.child())).header("Idempotency-Key", "same").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(changed))).andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
        mvc.perform(post(path(s) + "/" + r.get("id").asText() + "/cancel").with(actor(s.child())).header("If-Match", "\"0\"")
            .header("Idempotency-Key", "cancel")).andExpect(status().isOk());
        mvc.perform(post(path(s)).with(actor(s.child())).header("Idempotency-Key", "too-soon").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(input(s))))
            .andExpect(status().isTooManyRequests()).andExpect(jsonPath("$.errorCode").value("ACCESS_REQUEST_COOLDOWN"));
        clock.set(clock.instant().plusSeconds(60)); request(s, "later");
    }
    @Test void approverRevocationCannotReadCachedDecisionAndMalformedScopeCannotIssueGrant() throws Exception {
        var s = scope(); var r = request(s, "create"); approve(s, r, "approve");
        database.update("UPDATE tenant_members SET revoked_at=? WHERE tenant_id=? AND actor_key=?", java.sql.Timestamp.from(clock.instant()), s.tenant(), ActorKeys.key(s.owner()));
        mvc.perform(post(path(s) + "/" + r.get("id").asText() + "/decisions").with(actor(s.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "approve").contentType(MediaType.APPLICATION_JSON)
            .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":300}"))
            .andExpect(status().isForbidden());
        var fresh = scope(); var invalid = new HashMap<>(input(fresh)); invalid.put("ruleIds", List.of("missing"));
        mvc.perform(post(path(fresh)).with(actor(fresh.child())).header("Idempotency-Key", "missing").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(invalid))).andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("EXCEPTION_RULE_INVALID"));
        invalid = new HashMap<>(input(fresh)); invalid.put("approved", true);
        mvc.perform(post(path(fresh)).with(actor(fresh.child())).header("Idempotency-Key", "forged").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(invalid))).andExpect(status().isBadRequest());
        assertThat(database.queryForObject("SELECT COUNT(*) FROM access_requests WHERE tenant_id=?", Integer.class, fresh.tenant())).isZero();
    }
    @Test void deviceRevocationAndSubjectArchiveInvalidateApprovalAuthority() throws Exception {
        var s = scope(); var r = request(s, "create"); approve(s, r, "approve");
        mvc.perform(post("/api/v1/tenants/" + s.tenant() + "/devices/" + s.device() + "/revoke").with(actor(s.owner())))
            .andExpect(status().isNoContent());
        mvc.perform(get(path(s) + "/" + r.get("id").asText()).with(actor(s.child())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("REVOKED"))
            .andExpect(jsonPath("$.reasonCode").value("DEVICE_REGISTRATION_INACTIVE"));
        assertThat(database.queryForObject("SELECT state FROM access_requests WHERE tenant_id=? AND id=?", String.class, s.tenant(), r.get("id").asText())).isEqualTo("REVOKED");
        var fresh = scope(); var waiting = request(fresh, "create");
        mvc.perform(post("/api/v1/tenants/" + fresh.tenant() + "/subjects/" + fresh.subject() + "/archive").with(actor(fresh.owner()))
            .header("If-Match", "\"0\"")).andExpect(status().isNoContent());
        mvc.perform(get(path(fresh) + "/" + waiting.get("id").asText()).with(actor(fresh.child())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("INVALIDATED"))
            .andExpect(jsonPath("$.reasonCode").value("SUBJECT_ARCHIVED"));
        mvc.perform(post(path(fresh)).with(actor(fresh.child())).header("Idempotency-Key", "archived").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(input(fresh)))).andExpect(status().isForbidden());
    }
    @Test void expiryIsPersistedWithNewRevisionAndCorrelatedAuditRatherThanReusingStrongEtag() throws Exception {
        var s = scope(); var r = request(s, "create"); approve(s, r, "approve"); clock.set(clock.instant().plusSeconds(300));
        var expired = mvc.perform(get(path(s) + "/" + r.get("id").asText()).with(actor(s.child())))
            .andExpect(status().isOk()).andExpect(header().string("ETag", "\"2\""))
            .andExpect(jsonPath("$.state").value("EXPIRED")).andReturn().getResponse();
        assertThat(database.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND resource_id=? AND action='ACCESS_REQUEST_EXPIRED'",
            Integer.class, s.tenant(), r.get("id").asText())).isEqualTo(1);
        assertThat(database.queryForObject("SELECT correlation_id FROM audit_events WHERE tenant_id=? AND resource_id=? AND action='ACCESS_REQUEST_EXPIRED'",
            String.class, s.tenant(), r.get("id").asText())).isEqualTo(expired.getHeader("X-Correlation-Id"));
        mvc.perform(get(path(s) + "/" + r.get("id").asText()).with(actor(s.child())))
            .andExpect(status().isOk()).andExpect(header().string("ETag", "\"2\""));
    }
    @Test void selectedRulesAndWindowBoundsCannotBeForgedOrConvertQuotaIntoPermission() throws Exception {
        var s = scope(); var r = request(s, "create");
        mvc.perform(post(path(s) + "/" + r.get("id").asText() + "/decisions").with(actor(s.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "too-long").contentType(MediaType.APPLICATION_JSON)
            .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":601}"))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("GRANT_EXCEEDS_REQUEST"));
        mvc.perform(post(path(s) + "/" + r.get("id").asText() + "/decisions").with(actor(s.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "unused-field").contentType(MediaType.APPLICATION_JSON)
            .content("{\"decision\":\"DENY\",\"grantedWindowSeconds\":1}"))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("INVALID_DENIAL_FIELDS"));
        var duplicate = new HashMap<>(input(s)); duplicate.put("ruleIds", List.of("game", "game"));
        mvc.perform(post(path(s)).with(actor(s.child())).header("Idempotency-Key", "duplicate-rules").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(duplicate))).andExpect(status().isBadRequest());
        mvc.perform(post(path(s)).with(actor(s.owner())).header("Idempotency-Key", "adult-forgery").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(input(s)))).andExpect(status().isForbidden());
        var fresh = scope(); var quota = Map.of("id", "quota", "kind", "DAILY_QUOTA", "effect", "LIMIT", "applicationId", fresh.application(), "seconds", 60, "required", true);
        var draft = body(mvc.perform(put("/api/v1/tenants/" + fresh.tenant() + "/policies/" + fresh.policy()).with(actor(fresh.owner()))
            .header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("name", "额度", "rules", List.of(quota)))))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        String policyPath = "/api/v1/tenants/" + fresh.tenant() + "/policies/" + fresh.policy();
        var preview = body(mvc.perform(post(policyPath + "/previews").with(actor(fresh.owner())).header("If-Match", "\"1\"")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("deviceIds", List.of(fresh.device())))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        var publication = body(mvc.perform(post(policyPath + "/publications").with(actor(fresh.owner())).header("If-Match", "\"1\"")
            .header("Idempotency-Key", "quota").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("previewId", preview.get("id").asText(), "previewHash", preview.get("hash").asText(), "mode", "CONFIGURE_ONLY"))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        var invalid = new HashMap<>(input(fresh)); invalid.put("baseVersionId", publication.get("versionId").asText()); invalid.put("ruleIds", List.of("quota"));
        mvc.perform(post(path(fresh)).with(actor(fresh.child())).header("Idempotency-Key", "quota-is-not-window").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(invalid))).andExpect(status().isUnprocessableEntity())
            .andExpect(jsonPath("$.errorCode").value("EXCEPTION_KIND_UNSUPPORTED"));
        assertThat(draft.get("revision").asLong()).isEqualTo(1);
    }
    @Test void anotherChildInSameTenantCannotInspectOrCancelRequest() throws Exception {
        var s = scope(); var r = request(s, "create"); String other = "other-child-" + UUID.randomUUID(), subject = UUID.randomUUID().toString();
        database.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'另一个孩子','AGE_7_12',?)", s.tenant(), subject, clock.millis());
        database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,'CHILD',?)", s.tenant(), other, ActorKeys.key(other), subject);
        mvc.perform(get(path(s)).with(actor(other))).andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(0));
        mvc.perform(get(path(s) + "/" + r.get("id").asText()).with(actor(other))).andExpect(status().isForbidden());
        mvc.perform(post(path(s) + "/" + r.get("id").asText() + "/cancel").with(actor(other)).header("If-Match", "\"0\"")
            .header("Idempotency-Key", "foreign-cancel")).andExpect(status().isForbidden());
    }
    @Test void dueJobPersistsExpiryInBoundedBatchesWithoutChangingImmutableDecisionOrExtendingTime() throws Exception {
        assertThat(maintenance).as("Production maintenance boundary must exist").isNotNull();
        clock.set(Instant.parse("2030-01-01T00:00:00Z"));
        maintenance.expireDue(1000); // Reconcile old independent fixtures before measuring this batch.
        var first = scope(); var one = request(first, "create"); approve(first, one, "approve");
        var second = scope(); var two = request(second, "create"); approve(second, two, "approve");
        clock.set(clock.instant().plusSeconds(300));
        assertThat(maintenance.expireDue(1)).isEqualTo(1);
        assertThat(maintenance.expireDue(1)).isEqualTo(1);
        assertThat(maintenance.expireDue(1)).isZero();
        assertThat(database.queryForObject("SELECT state FROM access_requests WHERE tenant_id=? AND id=?", String.class, first.tenant(), one.get("id").asText())).isEqualTo("EXPIRED");
        assertThat(database.queryForObject("SELECT absolute_not_after FROM access_request_decisions WHERE tenant_id=?", Long.class, first.tenant()))
            .isEqualTo(Instant.parse("2030-01-01T00:05:00Z").toEpochMilli());
    }
    @Test void simultaneousIndependentGuardiansProduceOnlyOneDecisionAndOneGrant() throws Exception {
        var s = scope(); var r = request(s, "create"); String guardian = "guardian-" + UUID.randomUUID();
        database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')", s.tenant(), guardian, ActorKeys.key(guardian));
        var ready = new java.util.concurrent.CountDownLatch(2); var go = new java.util.concurrent.CountDownLatch(1);
        var executor = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            var a = executor.submit(() -> { ready.countDown(); go.await(); return mvc.perform(post(path(s) + "/" + r.get("id").asText() + "/decisions")
                .with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "one").contentType(MediaType.APPLICATION_JSON)
                .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":60}")).andReturn().getResponse().getStatus(); });
            var b = executor.submit(() -> { ready.countDown(); go.await(); return mvc.perform(post(path(s) + "/" + r.get("id").asText() + "/decisions")
                .with(actor(guardian)).header("If-Match", "\"0\"").header("Idempotency-Key", "two").contentType(MediaType.APPLICATION_JSON)
                .content("{\"decision\":\"DENY\"}")).andReturn().getResponse().getStatus(); });
            assertThat(ready.await(5, java.util.concurrent.TimeUnit.SECONDS)).isTrue(); go.countDown();
            assertThat(List.of(a.get(15, java.util.concurrent.TimeUnit.SECONDS), b.get(15, java.util.concurrent.TimeUnit.SECONDS)))
                .containsExactlyInAnyOrder(200, 412);
        } finally { go.countDown(); executor.shutdownNow(); }
        assertThat(database.queryForObject("SELECT COUNT(*) FROM access_request_decisions WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(1);
        assertThat(database.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action IN ('ACCESS_REQUEST_APPROVED','ACCESS_REQUEST_DENIED')", Integer.class, s.tenant())).isEqualTo(1);
    }
    @Test void actualMembershipRevocationImmediatelyInvalidatesGrantAndRejoiningCannotResurrectIt() throws Exception {
        var s = scope(); var r = request(s, "create"); String guardian = "delegated-" + UUID.randomUUID();
        database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')", s.tenant(), guardian, ActorKeys.key(guardian));
        mvc.perform(post(path(s) + "/" + r.get("id").asText() + "/decisions").with(actor(guardian)).header("If-Match", "\"0\"")
            .header("Idempotency-Key", "approve").contentType(MediaType.APPLICATION_JSON).content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":60}"))
            .andExpect(status().isOk());
        mvc.perform(delete("/api/v1/tenants/" + s.tenant() + "/members/" + guardian).with(actor(s.owner())))
            .andExpect(status().isNoContent());
        assertThat(database.queryForObject("SELECT state FROM access_requests WHERE tenant_id=? AND id=?", String.class, s.tenant(), r.get("id").asText()))
            .isEqualTo("REVOKED");
        database.update("UPDATE tenant_members SET revoked_at=NULL WHERE tenant_id=? AND actor_key=?", s.tenant(), ActorKeys.key(guardian));
        mvc.perform(get(path(s) + "/" + r.get("id").asText()).with(actor(s.child())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("REVOKED"))
            .andExpect(jsonPath("$.reasonCode").value("APPROVER_SCOPE_LOST"));
    }
    @Test void reassignedDeviceCannotReceiveAnApprovalBoundToItsPreviousChild() throws Exception {
        var s = scope(); var r = request(s, "create"); String subject = UUID.randomUUID().toString();
        database.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'新使用者','AGE_7_12',?)", s.tenant(), subject, clock.millis());
        database.update("UPDATE devices SET subject_id=? WHERE tenant_id=? AND id=?", subject, s.tenant(), s.device());
        mvc.perform(post(path(s) + "/" + r.get("id").asText() + "/decisions").with(actor(s.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "stale-child").contentType(MediaType.APPLICATION_JSON)
            .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":60}"))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("ACCESS_TARGET_CHANGED"));
        assertThat(database.queryForObject("SELECT COUNT(*) FROM access_request_decisions WHERE tenant_id=?", Integer.class, s.tenant())).isZero();
    }
    @Test void changedRequesterSubjectScopeCannotKeepItsPreviouslyApprovedWindow() throws Exception {
        var s = scope(); var r = request(s, "create"); approve(s, r, "approve"); String subject = UUID.randomUUID().toString();
        database.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'另一个主体','AGE_7_12',?)", s.tenant(), subject, clock.millis());
        database.update("UPDATE tenant_members SET subject_id=? WHERE tenant_id=? AND actor_key=?", subject, s.tenant(), ActorKeys.key(s.child()));
        mvc.perform(get(path(s) + "/" + r.get("id").asText()).with(actor(s.owner())))
            .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("REVOKED"))
            .andExpect(jsonPath("$.reasonCode").value("REQUESTER_SCOPE_LOST"));
    }
    private record Scope(String owner, String child, String tenant, String subject, String device, String registration,
                         String application, String policy, String version) {}
    @TestConfiguration static class TimeConfiguration { @Bean @Primary TestClock approvalClock() { return new TestClock(); } }
    static class TestClock extends Clock {
        private final AtomicReference<Instant> now = new AtomicReference<>(Instant.parse("2026-10-09T02:00:00Z"));
        void set(Instant time) { now.set(time); }
        @Override public ZoneId getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(ZoneId zone) { return Clock.fixed(instant(), zone); }
        @Override public Instant instant() { return now.get(); }
    }
}
