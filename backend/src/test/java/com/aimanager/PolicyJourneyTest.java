package com.aimanager;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
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

/** Real HTTP, SQL, transactions and immutable snapshots. Fleet fixtures do not certify system execution. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:policy;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true", "springdoc.api-docs.enabled=true"
})
@AutoConfigureMockMvc
class PolicyJourneyTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper mapper;
    @Autowired JdbcTemplate database;
    @MockitoBean JwtDecoder decoder;

    private RequestPostProcessor actor(String name) {
        return jwt().jwt(t -> t.subject(name).claim("auth_time", Instant.now().getEpochSecond())
            .claim("amr", List.of("pwd", "otp"))).authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    }

    private Scope scope() throws Exception {
        String owner = "policy-" + UUID.randomUUID();
        String tenant = body(mvc.perform(post("/api/v1/tenants").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String subject = body(mvc.perform(post("/api/v1/tenants/{t}/subjects", tenant).with(actor(owner))
            .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"小明\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
        String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
        database.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
            + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)", tenant, device, subject, registration, "测试设备", Instant.now().toEpochMilli());
        return new Scope(owner, tenant, subject, device);
    }
    private JsonNode body(String text) throws Exception { return mapper.readTree(text); }
    private String path(Scope s) { return "/api/v1/tenants/" + s.tenant(); }
    private JsonNode app(Scope s, String packageName) throws Exception {
        return body(mvc.perform(post(path(s) + "/applications").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("displayName", "应用", "platform", "ANDROID", "packageName", packageName,
                "profile", "PRIMARY", "signingDigests", List.of("a".repeat(64))))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    }
    private JsonNode draft(Scope s) throws Exception {
        return body(mvc.perform(post(path(s) + "/policies").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"学习规则\",\"kind\":\"POLICY\",\"rules\":[]}"))
            .andExpect(status().isCreated()).andExpect(header().string("ETag", "\"0\""))
            .andReturn().getResponse().getContentAsString());
    }
    private JsonNode edit(Scope s, String id, String etag, List<?> rules) throws Exception {
        return body(mvc.perform(put(path(s) + "/policies/" + id).with(actor(s.owner())).header("If-Match", etag)
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("name", "学习规则", "rules", rules))))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
    }
    private Map<String, Object> rule(String id, String applicationId, String effect) {
        return Map.of("id", id, "kind", "APP_LAUNCH", "effect", effect, "applicationId", applicationId, "required", true);
    }
    private JsonNode preview(Scope s, JsonNode draft) throws Exception {
        return body(mvc.perform(post(path(s) + "/policies/" + draft.get("id").asText() + "/previews").with(actor(s.owner()))
            .header("If-Match", "\"" + draft.get("revision").asLong() + "\"")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("deviceIds", List.of(s.device())))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    }

    @Test void applicationIdentityIsScopedAndUnverifiedRatherThanInstalled() throws Exception {
        var s = scope(); var application = app(s, "org.example.reader");
        assertThat(application.get("evidenceStatus").asText()).isEqualTo("ADMIN_DECLARED");
        mvc.perform(post(path(s) + "/applications").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("displayName", "同应用", "platform", "ANDROID", "packageName", "org.example.reader",
                "profile", "PRIMARY", "signingDigests", List.of("a".repeat(64))))))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("APPLICATION_IDENTITY_EXISTS"));
        mvc.perform(get(path(s) + "/applications").with(actor("stranger"))).andExpect(status().isForbidden());
    }

    @Test void draftRequiresStrongVersionAndRejectsForeignApplication() throws Exception {
        var s = scope(); var d = draft(s); var a = app(s, "org.example.game");
        var updated = edit(s, d.get("id").asText(), "\"0\"", List.of(rule("game", a.get("id").asText(), "DENY")));
        assertThat(updated.get("revision").asLong()).isEqualTo(1);
        String payload = mapper.writeValueAsString(Map.of("name", "覆盖", "rules", List.of()));
        mvc.perform(put(path(s) + "/policies/" + d.get("id").asText()).with(actor(s.owner())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isPreconditionFailed());
        mvc.perform(put(path(s) + "/policies/" + d.get("id").asText()).with(actor(s.owner()))
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().is(428));
        var foreign = scope(); var other = app(foreign, "org.example.other");
        mvc.perform(put(path(s) + "/policies/" + d.get("id").asText()).with(actor(s.owner())).header("If-Match", "\"1\"")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("name", "外租户", "rules",
                List.of(rule("other", other.get("id").asText(), "DENY"))))))
            .andExpect(status().isForbidden());
    }

    @Test void previewExplainsDenyPrecedenceWithoutReportingApplied() throws Exception {
        var s = scope(); var a = app(s, "org.example.game"); var d = draft(s);
        d = edit(s, d.get("id").asText(), "\"0\"", List.of(rule("allow", a.get("id").asText(), "ALLOW"), rule("deny", a.get("id").asText(), "DENY")));
        var p = preview(s, d);
        assertThat(p.get("phase").asText()).isEqualTo("PREVIEW");
        assertThat(p.get("enforceable").asBoolean()).isFalse();
        var evaluation = p.get("targets").get(0).get("rules").get(0);
        assertThat(evaluation.get("predictedEffect").asText()).isEqualTo("DENY");
        assertThat(evaluation.get("effectiveEffect").isNull()).isTrue();
        assertThat(evaluation.get("status").asText()).isEqualTo("UNSUPPORTED");
        assertThat(evaluation.get("reasonCode").asText()).isEqualTo("MANAGED_REGISTRATION_REQUIRED");
    }

    @Test void emergencyRecoveryCannotBeBlockedAndSpecialAccessCannotMasqueradeAsRuntimePermission() throws Exception {
        var s = scope(); var d = draft(s); var settings = app(s, "com.android.settings");
        String target = path(s) + "/policies/" + d.get("id").asText();
        mvc.perform(put(target).with(actor(s.owner())).header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("name", "限制", "rules", List.of(rule("settings", settings.get("id").asText(), "DENY"))))))
            .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.errorCode").value("SAFETY_BASELINE_PROTECTED"));
        var r = Map.of("id", "overlay", "kind", "RUNTIME_PERMISSION", "effect", "DENY", "required", true,
            "applicationId", settings.get("id").asText(), "permission", "android.permission.SYSTEM_ALERT_WINDOW");
        mvc.perform(put(target).with(actor(s.owner())).header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("name", "权限", "rules", List.of(r)))))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("NOT_RUNTIME_PERMISSION"));
    }

    @Test void scheduleIsValidatedAndEvaluatesCrossMidnight() throws Exception {
        var s = scope();
        String input = "{\"name\":\"晚间\",\"definition\":{\"timeZone\":\"Asia/Shanghai\",\"weekly\":[{\"day\":\"MONDAY\",\"start\":\"22:00\",\"end\":\"01:00\"}],\"exceptions\":[]}}";
        var schedule = body(mvc.perform(post(path(s) + "/schedules").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON).content(input))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        mvc.perform(get(path(s) + "/schedules/" + schedule.get("id").asText() + "/evaluation")
            .with(actor(s.owner())).param("at", "2026-10-05T16:30:00Z"))
            .andExpect(status().isOk()).andExpect(jsonPath("$.allowed").value(true))
            .andExpect(jsonPath("$.currentUntil").value("2026-10-05T17:00:00Z"));
        mvc.perform(post(path(s) + "/schedules").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON)
            .content(input.replace("Asia/Shanghai", "unknown/zone")))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("INVALID_TIME_ZONE"));
    }

    @Test void publishRequiresReviewedSnapshotAndNeverClaimsEnforcementOnByod() throws Exception {
        var s = scope(); var a = app(s, "org.example.game"); var d = draft(s);
        d = edit(s, d.get("id").asText(), "\"0\"", List.of(rule("deny", a.get("id").asText(), "DENY")));
        var p = preview(s, d); String target = path(s) + "/policies/" + d.get("id").asText() + "/publications";
        var enforce = Map.of("previewId", p.get("id").asText(), "previewHash", p.get("hash").asText(), "mode", "ENFORCE");
        mvc.perform(post(target).with(actor(s.owner())).header("If-Match", "\"1\"").header("Idempotency-Key", "enforce")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(enforce)))
            .andExpect(status().isUnprocessableEntity()).andExpect(jsonPath("$.errorCode").value("REQUIRED_RULE_UNSUPPORTED"));
        var configure = Map.of("previewId", p.get("id").asText(), "previewHash", p.get("hash").asText(), "mode", "CONFIGURE_ONLY");
        String payload = mapper.writeValueAsString(configure);
        var result = body(mvc.perform(post(target).with(actor(s.owner())).header("If-Match", "\"1\"").header("Idempotency-Key", "save")
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isCreated())
            .andExpect(jsonPath("$.state").value("CONFIGURED_NOT_ENFORCED")).andReturn().getResponse().getContentAsString());
        var repeated = body(mvc.perform(post(target).with(actor(s.owner())).header("If-Match", "\"1\"").header("Idempotency-Key", "save")
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        assertThat(repeated).isEqualTo(result);
        assertThat(database.queryForObject("SELECT COUNT(*) FROM policy_versions WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(1);
        assertThat(database.queryForObject("SELECT COUNT(*) FROM policy_outbox WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(1);
    }

    @Test void deviceRevocationInvalidatesPreviewBeforePublication() throws Exception {
        var s = scope(); var d = draft(s); var p = preview(s, d);
        mvc.perform(post(path(s) + "/devices/" + s.device() + "/revoke").with(actor(s.owner()))).andExpect(status().isNoContent());
        mvc.perform(post(path(s) + "/policies/" + d.get("id").asText() + "/publications").with(actor(s.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "revoked").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("previewId", p.get("id").asText(), "previewHash", p.get("hash").asText(), "mode", "CONFIGURE_ONLY"))))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("PREVIEW_STALE"));
        assertThat(database.queryForObject("SELECT COUNT(*) FROM policy_versions WHERE tenant_id=?", Integer.class, s.tenant())).isZero();
    }

    @Test void childCannotEditOrReadOtherChildrenPolicyDrafts() throws Exception {
        var s = scope(); var d = draft(s); String child = "child-" + UUID.randomUUID();
        database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,'CHILD',?)",
            s.tenant(), child, ActorKeys.key(child), s.subject());
        mvc.perform(get(path(s) + "/policies/" + d.get("id").asText()).with(actor(child))).andExpect(status().isForbidden());
        mvc.perform(put(path(s) + "/policies/" + d.get("id").asText()).with(actor(child)).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"越权\",\"rules\":[]}"))
            .andExpect(status().isForbidden());
    }

    private JsonNode configure(Scope s, JsonNode d, JsonNode p, String key) throws Exception {
        return body(mvc.perform(post(path(s) + "/policies/" + d.get("id").asText() + "/publications").with(actor(s.owner()))
            .header("If-Match", "\"" + d.get("revision").asLong() + "\"").header("Idempotency-Key", key)
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("previewId", p.get("id").asText(),
                "previewHash", p.get("hash").asText(), "mode", "CONFIGURE_ONLY"))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
    }

    @Test void templateCopyAndRollbackPreserveHistoricalVersion() throws Exception {
        var s = scope(); var a = app(s, "org.example.game");
        var template = body(mvc.perform(post(path(s) + "/policies").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("name", "模板", "kind", "TEMPLATE", "rules", List.of(rule("game", a.get("id").asText(), "DENY"))))))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        var d = body(mvc.perform(post(path(s) + "/policies/" + template.get("id").asText() + "/copies").with(actor(s.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "template-copy").contentType(MediaType.APPLICATION_JSON)
            .content("{\"name\":\"我的规则\"}")).andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        var operation = configure(s, d, preview(s, d), "first");
        edit(s, template.get("id").asText(), "\"0\"", List.of());
        edit(s, d.get("id").asText(), "\"0\"", List.of());
        String versionPath = path(s) + "/policies/" + d.get("id").asText() + "/versions/" + operation.get("versionId").asText();
        mvc.perform(get(versionPath).with(actor(s.owner()))).andExpect(status().isOk())
            .andExpect(jsonPath("$.snapshot.sourceRules[0].effect").value("DENY"));
        var restored = body(mvc.perform(post(versionPath + "/rollback-drafts").with(actor(s.owner())).header("If-Match", "\"1\"").header("Idempotency-Key", "rollback")
            .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"恢复版本\"}"))
            .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
        assertThat(restored.get("sourceVersionId").asText()).isEqualTo(operation.get("versionId").asText());
        assertThat(restored.get("id").asText()).isEqualTo(d.get("id").asText());
        assertThat(restored.get("revision").asLong()).isEqualTo(2);
        assertThat(restored.get("rules").get(0).get("effect").asText()).isEqualTo("DENY");
        var newOperation = configure(s, restored, preview(s, restored), "restored");
        assertThat(newOperation.get("versionId").asText()).isNotEqualTo(operation.get("versionId").asText());
        assertThat(newOperation.get("sequence").asLong()).isEqualTo(2);
        assertThat(newOperation.get("state").asText()).isEqualTo("CONFIGURED_NOT_ENFORCED");
    }

    @Test void expiredTamperedAndEditedPreviewsCannotPublish() throws Exception {
        var s = scope(); var d = draft(s); var p = preview(s, d);
        String target = path(s) + "/policies/" + d.get("id").asText() + "/publications";
        String payload = mapper.writeValueAsString(Map.of("previewId", p.get("id").asText(), "previewHash", "0".repeat(64), "mode", "CONFIGURE_ONLY"));
        mvc.perform(post(target).with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "hash")
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isConflict());
        payload = mapper.writeValueAsString(Map.of("previewId", p.get("id").asText(), "previewHash", p.get("hash").asText(), "mode", "CONFIGURE_ONLY"));
        database.update("UPDATE policy_previews SET expires_at=0 WHERE tenant_id=? AND id=?", s.tenant(), p.get("id").asText());
        mvc.perform(post(target).with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "expired")
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isConflict());
        var fresh = preview(s, d); edit(s, d.get("id").asText(), "\"0\"", List.of());
        mvc.perform(post(target).with(actor(s.owner())).header("If-Match", "\"1\"").header("Idempotency-Key", "edited")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("previewId", fresh.get("id").asText(),
                "previewHash", fresh.get("hash").asText(), "mode", "CONFIGURE_ONLY"))))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("PREVIEW_STALE"));
    }

    @Test void capabilityEvidenceChangeMakesReviewedSnapshotStale() throws Exception {
        var s = scope(); var d = draft(s); var p = preview(s, d);
        database.update("INSERT INTO device_capabilities(tenant_id,device_id,capability_key,reported_supported,grant_status,checked_at) VALUES(?,?,?,true,'GRANTED',?)",
            s.tenant(), s.device(), "app.launch_block", Instant.now().toEpochMilli());
        mvc.perform(post(path(s) + "/policies/" + d.get("id").asText() + "/publications").with(actor(s.owner()))
            .header("If-Match", "\"0\"").header("Idempotency-Key", "changed-cap").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("previewId", p.get("id").asText(), "previewHash", p.get("hash").asText(), "mode", "CONFIGURE_ONLY"))))
            .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("PREVIEW_STALE"));
    }

    @Test void cachedPublicationStillRequiresActiveMembershipAndRecentMfa() throws Exception {
        var s = scope(); var d = draft(s); var p = preview(s, d); var result = configure(s, d, p, "retry");
        String target = path(s) + "/policies/" + d.get("id").asText() + "/publications";
        String payload = mapper.writeValueAsString(Map.of("previewId", p.get("id").asText(), "previewHash", p.get("hash").asText(), "mode", "CONFIGURE_ONLY"));
        var stale = jwt().jwt(t -> t.subject(s.owner()).claim("auth_time", 1L).claim("amr", List.of("pwd", "otp")));
        mvc.perform(post(target).with(stale).header("If-Match", "\"0\"").header("Idempotency-Key", "retry")
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isUnauthorized());
        mvc.perform(post(target).with(actor(s.owner())).header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON).content(payload))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_REQUIRED"));
        database.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?", s.tenant(), ActorKeys.key(s.owner()));
        mvc.perform(post(target).with(actor(s.owner())).header("If-Match", "\"0\"").header("Idempotency-Key", "retry")
            .contentType(MediaType.APPLICATION_JSON).content(payload)).andExpect(status().isForbidden());
        assertThat(result.get("state").asText()).isEqualTo("CONFIGURED_NOT_ENFORCED");
    }

    @Test void duplicateTargetsAndUnusedFieldsFailBeforePreviewOrEdit() throws Exception {
        var s = scope(); var d = draft(s); var a = app(s, "org.example.reader");
        mvc.perform(post(path(s) + "/policies/" + d.get("id").asText() + "/previews").with(actor(s.owner()))
            .header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(Map.of("deviceIds", List.of(s.device(), s.device())))))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("DUPLICATE_DEVICE_TARGET"));
        var r = new java.util.HashMap<>(rule("game", a.get("id").asText(), "DENY")); r.put("seconds", 60);
        mvc.perform(put(path(s) + "/policies/" + d.get("id").asText()).with(actor(s.owner())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("name", "错误字段", "rules", List.of(r)))))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("UNUSED_RULE_FIELD"));
    }

    @Test void quotaConflictsChooseSmallerLimitAndRetainRecoveryExemptions() throws Exception {
        var s = scope(); var d = draft(s);
        var rules = List.of(Map.of("id", "one", "kind", "DAILY_QUOTA", "effect", "LIMIT", "required", true, "seconds", 600),
            Map.of("id", "two", "kind", "DAILY_QUOTA", "effect", "LIMIT", "required", false, "seconds", 1200));
        d = edit(s, d.get("id").asText(), "\"0\"", rules); var p = preview(s, d);
        assertThat(p.get("targets").get(0).get("rules").size()).isEqualTo(1);
        assertThat(p.get("targets").get(0).get("rules").get(0).get("seconds").asLong()).isEqualTo(600);
        assertThat(p.get("targets").get(0).get("rules").get(0).get("required").asBoolean()).isTrue();
        assertThat(p.get("snapshot").get("protectedPackageExemptions").toString()).contains("com.android.settings", "com.aimanager.device");
    }

    @Test void independentScheduleConstraintsDoNotCollapseIntoOneAllow() throws Exception {
        var s = scope(); var d = draft(s); var rules = new java.util.ArrayList<Map<String, Object>>();
        for (int hour : List.of(7, 9)) {
            String input = "{\"name\":\"时段\",\"definition\":{\"timeZone\":\"UTC\",\"weekly\":[{\"day\":\"MONDAY\",\"start\":\"0" + hour
                + ":00\",\"end\":\"12:00\"}],\"exceptions\":[]}}";
            var plan = body(mvc.perform(post(path(s) + "/schedules").with(actor(s.owner())).contentType(MediaType.APPLICATION_JSON).content(input))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
            rules.add(Map.of("id", "window-" + hour, "kind", "TIME_WINDOW", "effect", "ALLOW", "required", true, "scheduleId", plan.get("id").asText()));
        }
        d = edit(s, d.get("id").asText(), "\"0\"", rules); var p = preview(s, d);
        assertThat(p.get("targets").get(0).get("rules").size()).isEqualTo(2);
        assertThat(p.get("snapshot").get("schedules").size()).isEqualTo(2);
    }

    @Test void fractionalNumbersStringBooleansAndDuplicateJsonKeysAreRejected() throws Exception {
        var s = scope(); var d = draft(s); String target = path(s) + "/policies/" + d.get("id").asText();
        String base = "{\"name\":\"额度\",\"rules\":[{\"id\":\"quota\",\"kind\":\"DAILY_QUOTA\",\"effect\":\"LIMIT\",\"required\":true,\"seconds\":60}]}";
        for (var payload : List.of(base.replace("\"seconds\":60", "\"seconds\":60.9"), base.replace("\"required\":true", "\"required\":\"false\""),
            base.replace("\"effect\":\"LIMIT\"", "\"effect\":\"LIMIT\",\"effect\":\"DENY\""))) {
            mvc.perform(put(target).with(actor(s.owner())).header("If-Match", "\"0\"").contentType(MediaType.APPLICATION_JSON).content(payload))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("MALFORMED_REQUEST"));
        }
    }

    @Test void publicationHistoryIsChronologicalAndCursorRemainsTenantScoped() throws Exception {
        var s = scope(); var d = draft(s); var p = preview(s, d);
        var first = configure(s, d, p, "first"); configure(s, d, p, "second");
        String target = path(s) + "/policies/" + d.get("id").asText() + "/versions";
        var history = body(mvc.perform(get(target).with(actor(s.owner())).param("limit", "1"))
            .andExpect(status().isOk()).andReturn().getResponse().getContentAsString());
        assertThat(history.get("items").get(0).get("sequence").asLong()).isEqualTo(2);
        mvc.perform(get(target).with(actor(s.owner())).param("limit", "1").param("cursor", history.get("nextCursor").asText()))
            .andExpect(status().isOk()).andExpect(jsonPath("$.items[0].id").value(first.get("versionId").asText()));
        var other = scope(); var od = draft(other); var foreign = configure(other, od, preview(other, od), "foreign");
        mvc.perform(get(target).with(actor(s.owner())).param("cursor", foreign.get("versionId").asText())).andExpect(status().isForbidden());
    }

    @Test void concurrentPublishersAllocateDistinctSequencesAndAtomicEvents() throws Exception {
        var s = scope(); var d = draft(s); var p = preview(s, d); String other = "guardian-" + UUID.randomUUID();
        database.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')", s.tenant(), other, ActorKeys.key(other));
        String target = path(s) + "/policies/" + d.get("id").asText() + "/publications";
        String payload = mapper.writeValueAsString(Map.of("previewId", p.get("id").asText(), "previewHash", p.get("hash").asText(), "mode", "CONFIGURE_ONLY"));
        var start = new java.util.concurrent.CountDownLatch(1);
        var executor = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            java.util.concurrent.Callable<JsonNode> first = () -> { start.await(); return body(mvc.perform(post(target).with(actor(s.owner()))
                .header("If-Match", "\"0\"").header("Idempotency-Key", "one").contentType(MediaType.APPLICATION_JSON).content(payload))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()); };
            java.util.concurrent.Callable<JsonNode> second = () -> { start.await(); return body(mvc.perform(post(target).with(actor(other))
                .header("If-Match", "\"0\"").header("Idempotency-Key", "two").contentType(MediaType.APPLICATION_JSON).content(payload))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()); };
            var f1 = executor.submit(first); var f2 = executor.submit(second); start.countDown();
            assertThat(List.of(f1.get(10, java.util.concurrent.TimeUnit.SECONDS).get("sequence").asLong(),
                f2.get(10, java.util.concurrent.TimeUnit.SECONDS).get("sequence").asLong())).containsExactlyInAnyOrder(1L, 2L);
        } finally { executor.shutdownNow(); }
        assertThat(database.queryForObject("SELECT COUNT(*) FROM policy_outbox WHERE tenant_id=?", Integer.class, s.tenant())).isEqualTo(2);
    }
    private record Scope(String owner, String tenant, String subject, String device) {}
    @Test void openApiDescribesSeparateDeviceAndManagementAuthentication() throws Exception {
        mvc.perform(get("/v3/api-docs").with(actor("docs-reader"))).andExpect(status().isOk())
            .andExpect(jsonPath("$.openapi").value("3.1.0"))
            .andExpect(jsonPath("$.paths['/api/v1/device-api/application-inventory'].post.security[0].deviceBearer").isArray())
            .andExpect(jsonPath("$.paths['/api/v1/tenants/{tenantId}/policies/{policyId}/publications'].post").exists());
    }
    @Test void referencesRequireCanonicalUuidToKeepCompiledDocumentsConsistent() throws Exception {
        var s = scope(); var d = draft(s);
        var r = rule("app", "A0000000-0000-0000-0000-000000000001", "DENY");
        mvc.perform(put(path(s) + "/policies/" + d.get("id").asText()).with(actor(s.owner())).header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("name", "规范引用", "rules", List.of(r)))))
            .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("VALIDATION_FAILED"));
    }
}
