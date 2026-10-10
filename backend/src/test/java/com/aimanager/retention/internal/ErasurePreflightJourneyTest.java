package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    properties = {
      "spring.datasource.url=${ERASURE_TEST_DATABASE_URL:jdbc:h2:mem:erasure_preflight;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${ERASURE_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${ERASURE_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false",
      "manager.report-jobs.worker.enabled=false",
      "manager.diagnostic-packages.worker.enabled=false"
    })
@AutoConfigureMockMvc
class ErasurePreflightJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper json;
  String tenant, subject, owner, path;

  RequestPostProcessor actor(String id, boolean mfa) {
    return jwt()
        .jwt(
            j ->
                j.subject(id)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", mfa ? List.of("pwd", "otp") : List.of("pwd")));
  }

  @BeforeEach
  void fixture() {
    tenant = UUID.randomUUID().toString();
    subject = UUID.randomUUID().toString();
    owner = "erasure-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at,version)"
            + " VALUES(?,?,'FAMILY','UTC',?,0)",
        tenant,
        "private tenant",
        System.currentTimeMillis());
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,version)"
            + " VALUES(?,?,?,'OWNER',0)",
        tenant,
        owner,
        ActorKeys.key(owner));
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at,version)"
            + " VALUES(?,?,'private nickname','AGE_7_12',?,0)",
        tenant,
        subject,
        System.currentTimeMillis());
    path = "/api/v1/tenants/" + tenant + "/subjects/" + subject + "/erasure-preflight";
  }

  @Test
  void ownerGetsExplicitNonExecutablePreflightWithoutPersonalContent() throws Exception {
    var response =
        mvc.perform(get(path).with(actor(owner, true)))
            .andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(jsonPath("subjectId").value(subject))
            .andExpect(jsonPath("subjectVersion").value(0))
            .andExpect(jsonPath("executionAvailable").value(false))
            .andExpect(jsonPath("readyToErase").value(false))
            .andExpect(jsonPath("counts.devices").value(0))
            .andExpect(jsonPath("blockers[0]").value("ERASURE_EXECUTION_UNAVAILABLE"))
            .andReturn()
            .getResponse()
            .getContentAsString();
    assertFalse(response.contains("private nickname"));
    assertFalse(response.contains("private tenant"));
    var body = json.readTree(response);
    assertTrue(body.path("catalog").path("storeCount").asInt() > 70);
    assertTrue(body.path("catalog").path("sha256").asText().matches("[0-9a-f]{64}"));
    assertEquals(
        1,
        db.queryForObject(
            "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                + " action='SUBJECT_ERASURE_PREFLIGHT_VIEWED'",
            Integer.class,
            tenant));
    assertEquals(
        "private nickname",
        db.queryForObject(
            "SELECT nickname FROM subjects WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            subject));
  }

  @Test
  void passwordOnlyAndOldMfaCannotInspectDeletionScope() throws Exception {
    mvc.perform(get(path).with(actor(owner, false)))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("errorCode").value("REAUTH_REQUIRED"));
    mvc.perform(
            get(path)
                .with(
                    jwt()
                        .jwt(
                            j ->
                                j.subject(owner)
                                    .claim(
                                        "auth_time",
                                        Instant.now().minusSeconds(900).getEpochSecond())
                                    .claim("amr", List.of("pwd", "otp")))))
        .andExpect(status().isUnauthorized());
  }

  @Test
  void otherTenantAndUnknownSubjectsHaveSameDeniedResult() throws Exception {
    mvc.perform(get(path).with(actor("outsider", true)))
        .andExpect(status().isForbidden())
        .andExpect(jsonPath("errorCode").value("SCOPE_DENIED"));
    mvc.perform(get(path.replace(subject, UUID.randomUUID().toString())).with(actor(owner, true)))
        .andExpect(status().isForbidden())
        .andExpect(jsonPath("errorCode").value("SCOPE_DENIED"));
  }

  @Test
  void delegatedRolesAndRevokedOwnerCannotPrepareWholeSubjectErasure() throws Exception {
    for (String role : List.of("GUARDIAN", "TEACHER", "CHILD", "AUDITOR")) {
      db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, tenant);
      mvc.perform(get(path).with(actor(owner, true))).andExpect(status().isForbidden());
    }
    db.update(
        "UPDATE tenant_members SET role='OWNER',revoked_at=? WHERE tenant_id=?",
        java.sql.Timestamp.from(Instant.now()),
        tenant);
    mvc.perform(get(path).with(actor(owner, true))).andExpect(status().isForbidden());
  }

  @Test
  void archivedSubjectCanBeInspectedWithoutBeingRestored() throws Exception {
    db.update(
        "UPDATE subjects SET archived_at=?,version=4 WHERE tenant_id=? AND id=?",
        System.currentTimeMillis(),
        tenant,
        subject);
    mvc.perform(get(path).with(actor(owner, true)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("subjectArchived").value(true))
        .andExpect(jsonPath("subjectVersion").value(4));
    assertNotNull(
        db.queryForObject(
            "SELECT archived_at FROM subjects WHERE tenant_id=? AND id=?",
            Long.class,
            tenant,
            subject));
  }

  @Test
  void unknownStorageAndNewColumnsFailClosedUntilReviewed() throws Exception {
    db.execute("CREATE TABLE erasure_unreviewed_store(id VARCHAR(36), payload TEXT)");
    try {
      mvc.perform(get(path).with(actor(owner, true)))
          .andExpect(status().isServiceUnavailable())
          .andExpect(jsonPath("errorCode").value("ERASURE_SCHEMA_REVIEW_REQUIRED"));
    } finally {
      db.execute("DROP TABLE erasure_unreviewed_store");
    }
    db.execute("ALTER TABLE subjects ADD COLUMN erasure_unreviewed_note TEXT");
    try {
      mvc.perform(get(path).with(actor(owner, true)))
          .andExpect(status().isServiceUnavailable())
          .andExpect(jsonPath("errorCode").value("ERASURE_SCHEMA_REVIEW_REQUIRED"));
    } finally {
      db.execute("ALTER TABLE subjects DROP COLUMN erasure_unreviewed_note");
    }
    mvc.perform(get(path).with(actor(owner, true))).andExpect(status().isOk());
  }

  @Test
  void pendingClaimIsIncludedButExpiredAndCompletedEnrollmentAreNot() throws Exception {
    long now = System.currentTimeMillis();
    for (String state : List.of("PENDING_CLAIM", "COMPLETED", "EXPIRED")) {
      db.update(
          "INSERT INTO"
              + " device_enrollments(tenant_id,id,subject_id,creator_actor_id,platform,requested_mode,token_hash,state,created_at,expires_at)"
              + " VALUES(?,?,?,?,'ANDROID','BYOD',?,?,?,?)",
          tenant,
          UUID.randomUUID().toString(),
          subject,
          owner,
          UUID.randomUUID().toString(),
          state,
          now,
          state.equals("EXPIRED") ? now - 1 : now + 60000);
    }
    mvc.perform(get(path).with(actor(owner, true)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("counts.pendingEnrollments").value(1))
        .andExpect(
            jsonPath("blockers")
                .value(org.hamcrest.Matchers.hasItem("PENDING_DEVICE_ENROLLMENTS")));
  }

  String device(String subjectId, String state) {
    String id = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'private device name','ANDROID','14',?,'{}',?,?)",
        tenant,
        id,
        subjectId,
        id,
        state,
        UUID.randomUUID().toString(),
        System.currentTimeMillis());
    return id;
  }

  @Test
  void registrationAndCredentialCountsRemainInSubjectScope() throws Exception {
    long now = System.currentTimeMillis();
    String active = device(subject, "ACTIVE"), revoked = device(subject, "REVOKED");
    String other = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at,version) VALUES(?,?,'other"
            + " subject','AGE_13_17',?,0)",
        tenant,
        other,
        now);
    device(other, "ACTIVE");
    for (int i = 0; i < 3; i++) {
      db.update(
          "INSERT INTO"
              + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at,revoked_at)"
              + " VALUES(?,?,?,?,?,?,?,?,?)",
          UUID.randomUUID().toString(),
          tenant,
          active,
          active,
          UUID.randomUUID().toString(),
          i != 2,
          now,
          i == 1 ? now - 1 : now + 60000,
          i == 2 ? now : null);
    }
    String child = "child-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id,version)"
            + " VALUES(?,?,?,'CHILD',?,0)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    var response =
        mvc.perform(get(path).with(actor(owner, true)))
            .andExpect(status().isOk())
            .andExpect(jsonPath("counts.devices").value(2))
            .andExpect(jsonPath("counts.activeRegistrations").value(1))
            .andExpect(jsonPath("counts.activeCredentials").value(1))
            .andExpect(jsonPath("counts.linkedMembers").value(1))
            .andExpect(jsonPath("counts.devicesWithCleanupReport").value(0))
            .andExpect(
                jsonPath("notices")
                    .value(org.hamcrest.Matchers.hasItem("DEVICE_CLEANUP_REPORTS_ARE_UNVERIFIED")))
            .andReturn()
            .getResponse()
            .getContentAsString();
    assertFalse(response.contains("private device name"));
    assertFalse(response.contains(other));
    assertFalse(response.contains(child));
    assertEquals(
        "REVOKED",
        db.queryForObject(
            "SELECT state FROM devices WHERE tenant_id=? AND id=?", String.class, tenant, revoked));
  }

  @Test
  void organizationAdministratorCanInspectCurrentOrganizationScope() throws Exception {
    db.update("UPDATE tenants SET kind='ORGANIZATION' WHERE id=?", tenant);
    db.update("UPDATE tenant_members SET role='ORG_ADMIN' WHERE tenant_id=?", tenant);
    mvc.perform(get(path).with(actor(owner, true))).andExpect(status().isOk());
  }

  @Test
  void cleanupHeadMustReferToSameRegistrationAndReportsRemainUnverified() throws Exception {
    String target = device(subject, "REVOKED");
    String operation = UUID.randomUUID().toString();
    long now = System.currentTimeMillis();
    db.update(
        "INSERT INTO"
            + " deprovision_operations(tenant_id,id,device_id,registration_id,command_id,key_thumbprint,compact_jws,command_hash,state,local_evidence,issued_at,absolute_not_after,updated_at,version)"
            + " VALUES(?,?,?,?,?,'fixture','fixture','fixture','CLEANUP_REPORTED','DEVICE_REPORT_UNVERIFIED',?,?,?,0)",
        tenant,
        operation,
        target,
        UUID.randomUUID().toString(),
        UUID.randomUUID().toString(),
        now,
        now + 60000,
        now);
    db.update(
        "INSERT INTO deprovision_heads(tenant_id,device_id,registration_id,operation_id)"
            + " VALUES(?,?,?,?)",
        tenant,
        target,
        target,
        operation);
    mvc.perform(get(path).with(actor(owner, true)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("counts.devicesWithCleanupReport").value(0));
    db.update(
        "UPDATE deprovision_operations SET registration_id=? WHERE tenant_id=? AND id=?",
        target,
        tenant,
        operation);
    mvc.perform(get(path).with(actor(owner, true)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("counts.devicesWithCleanupReport").value(1))
        .andExpect(jsonPath("readyToErase").value(false))
        .andExpect(
            jsonPath("notices")
                .value(org.hamcrest.Matchers.hasItem("DEVICE_CLEANUP_REPORTS_ARE_UNVERIFIED")));
  }
}
