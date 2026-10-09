package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

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

@SpringBootTest(
    properties = {
      "spring.datasource.url=${OWNERSHIP_TEST_DATABASE_URL:jdbc:h2:mem:ownership;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${OWNERSHIP_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${OWNERSHIP_TEST_DATABASE_PASSWORD:}",
      "spring.flyway.enabled=true"
    })
@AutoConfigureMockMvc
@org.springframework.context.annotation.Import(
    OwnershipTransferJourneyTest.FailureConfiguration.class)
class OwnershipTransferJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  @Autowired FailureListener failureListener;
  @Autowired org.springframework.transaction.PlatformTransactionManager transactions;

  @org.springframework.boot.test.context.TestConfiguration(proxyBeanMethods = false)
  static class FailureConfiguration {
    @org.springframework.context.annotation.Bean
    FailureListener ownershipFailureListener() {
      return new FailureListener();
    }
  }

  static class FailureListener {
    volatile String failTenant;
    volatile OwnershipBarrier barrier;

    @org.springframework.context.event.EventListener
    @org.springframework.core.annotation.Order(-300)
    public void beforeCleanup(com.aimanager.tenant.OwnershipTransferred event) {
      var waiting = barrier;
      if (waiting != null && waiting.tenant().equals(event.tenantId())) {
        waiting.entered().countDown();
        try {
          if (!waiting.proceed().await(10, java.util.concurrent.TimeUnit.SECONDS))
            throw new IllegalStateException("Barrier timeout");
        } catch (InterruptedException e) {
          Thread.currentThread().interrupt();
          throw new IllegalStateException(e);
        }
      }
    }

    @org.springframework.context.event.EventListener
    @org.springframework.core.annotation.Order(1000)
    public void onTransfer(com.aimanager.tenant.OwnershipTransferred event) {
      if (event.tenantId().equals(failTenant))
        throw new IllegalStateException("Test downstream failure");
    }
  }

  record OwnershipBarrier(
      String tenant,
      java.util.concurrent.CountDownLatch entered,
      java.util.concurrent.CountDownLatch proceed) {}

  @Test
  void unrelatedPolicyTransactionCanFinishWhileTransferWaitsForPreview() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    String policy = UUID.randomUUID().toString(), preview = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'并发规则','FAMILY','[]',1,1)",
        f.id(),
        policy);
    db.update(
        "INSERT INTO"
            + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at)"
            + " VALUES(?,?,?,0,?,'{}',1,?)",
        f.id(),
        preview,
        policy,
        "a".repeat(64),
        System.currentTimeMillis() + 3600000);
    var entered = new java.util.concurrent.CountDownLatch(1);
    var proceed = new java.util.concurrent.CountDownLatch(1);
    var previewLocked = new java.util.concurrent.CountDownLatch(1);
    failureListener.barrier = new OwnershipBarrier(f.id(), entered, proceed);
    var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
    try {
      var other =
          pool.submit(
              () ->
                  new org.springframework.transaction.support.TransactionTemplate(transactions)
                      .execute(
                          status -> {
                            db.queryForList(
                                "SELECT id FROM policy_previews WHERE tenant_id=? AND id=? FOR"
                                    + " UPDATE",
                                f.id(),
                                preview);
                            previewLocked.countDown();
                            try {
                              if (!entered.await(10, java.util.concurrent.TimeUnit.SECONDS))
                                throw new IllegalStateException("Transfer did not enter cleanup");
                            } catch (InterruptedException e) {
                              Thread.currentThread().interrupt();
                              throw new IllegalStateException(e);
                            }
                            proceed.countDown();
                            // Real MySQL FK checking takes a shared parent lock during this
                            // ordinary audit insert.
                            db.update(
                                "INSERT INTO"
                                    + " audit_events(tenant_id,id,actor_id,action,resource_id,correlation_id,occurred_at)"
                                    + " VALUES(?,?,?,?,?,?,?)",
                                f.id(),
                                UUID.randomUUID().toString(),
                                "independent-guardian",
                                "POLICY_PREVIEW_REVIEWED",
                                preview,
                                UUID.randomUUID().toString(),
                                System.currentTimeMillis());
                            return true;
                          }));
      assertThat(previewLocked.await(10, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
      var transfer =
          pool.submit(
              () ->
                  mvc.perform(
                          post(path(f, p) + "/accept")
                              .with(actor(f.target()))
                              .with(csrf())
                              .header("If-Match", "\"0\""))
                      .andReturn()
                      .getResponse()
                      .getStatus());
      assertThat(other.get(20, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
      assertThat(transfer.get(20, java.util.concurrent.TimeUnit.SECONDS)).isEqualTo(200);
    } finally {
      proceed.countDown();
      failureListener.barrier = null;
      pool.shutdownNow();
    }
    role(f, f.target(), "OWNER");
  }

  @Test
  void listenerFailureRollsBackBothRolesTenantVersionAndTransfer() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    failureListener.failTenant = f.id();
    try {
      mvc.perform(
              post(path(f, p) + "/accept")
                  .with(actor(f.target()))
                  .with(csrf())
                  .header("If-Match", "\"0\""))
          .andExpect(status().isInternalServerError());
    } finally {
      failureListener.failTenant = null;
    }
    role(f, f.owner(), "OWNER");
    role(f, f.target(), "GUARDIAN");
    assertThat(db.queryForObject("SELECT version FROM tenants WHERE id=?", Long.class, f.id()))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT state FROM ownership_transfers WHERE tenant_id=? AND id=?",
                String.class,
                f.id(),
                p.path("id").asText()))
        .isEqualTo("PENDING");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='OWNERSHIP_TRANSFER_ACCEPTED'",
                Integer.class,
                f.id()))
        .isZero();
  }

  @Test
  void onlyCurrentOwnerMayStartAndTargetMustBeEligibleWithStrongVersion() throws Exception {
    var f = family("FAMILY");
    for (String caller : List.of(f.target(), "stranger"))
      mvc.perform(
              post(f.root() + "/ownership-transfers")
                  .with(actor(caller))
                  .with(csrf())
                  .header("If-Match", "\"0\"")
                  .contentType(MediaType.APPLICATION_JSON)
                  .content(json.writeValueAsBytes(Map.of("targetActorId", f.target()))))
          .andExpect(status().isForbidden());
    mvc.perform(
            post(f.root() + "/ownership-transfers")
                .with(actor(f.owner(), true, false))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("targetActorId", f.target()))))
        .andExpect(status().isUnauthorized());
    mvc.perform(
            post(f.root() + "/ownership-transfers")
                .with(actor(f.owner()))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("targetActorId", f.target()))))
        .andExpect(status().isPreconditionRequired());
    for (String target : List.of(f.owner(), "missing-member"))
      mvc.perform(
              post(f.root() + "/ownership-transfers")
                  .with(actor(f.owner()))
                  .with(csrf())
                  .header("If-Match", "\"0\"")
                  .contentType(MediaType.APPLICATION_JSON)
                  .content(json.writeValueAsBytes(Map.of("targetActorId", target))))
          .andExpect(status().isBadRequest())
          .andExpect(jsonPath("$.errorCode").value("OWNERSHIP_TARGET_INELIGIBLE"));
  }

  @Test
  void replayConflictAndCrossTenantIdsDoNotExposeOrChangeTransfer() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    var other = family("FAMILY");
    mvc.perform(
            get(other.root() + "/ownership-transfers/" + p.path("id").asText())
                .with(actor(other.owner())))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(f.root() + "/ownership-transfers")
                .with(actor(f.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "start")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("targetActorId", f.owner()))))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
    mvc.perform(get(f.root() + "/ownership-transfers?limit=0").with(actor(f.owner())))
        .andExpect(status().isBadRequest());
    db.update("UPDATE ownership_transfers SET expires_at=1 WHERE tenant_id=?", f.id());
    mvc.perform(get(path(f, p)).with(actor(f.target())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("EXPIRED"))
        .andExpect(header().string("ETag", "\"1\""));
    mvc.perform(get(path(f, p)).with(actor(f.target())))
        .andExpect(status().isOk())
        .andExpect(header().string("ETag", "\"1\""));
  }

  RequestPostProcessor actor(String id) {
    return actor(id, true, true);
  }

  RequestPostProcessor actor(String id, boolean adult, boolean mfa) {
    return jwt()
        .jwt(
            t ->
                t.subject(id)
                    .claim("email", id + "@example.test")
                    .claim("email_verified", true)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", mfa ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(
            new SimpleGrantedAuthority(adult ? "SCOPE_tenant:create" : "SCOPE_profile:read"));
  }

  record Family(String id, String owner, String target) {
    String root() {
      return "/api/v1/tenants/" + id;
    }
  }

  Family family(String kind) throws Exception {
    String owner = "o-" + UUID.randomUUID(), target = "t-" + UUID.randomUUID();
    var result =
        mvc.perform(
                post("/api/v1/tenants")
                    .with(actor(owner))
                    .with(csrf())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(
                        json.writeValueAsBytes(
                            Map.of("name", "交接家庭", "kind", kind, "timeZone", "Asia/Shanghai"))))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse();
    var f =
        new Family(json.readTree(result.getContentAsString()).path("id").asText(), owner, target);
    join(f, target, kind.equals("FAMILY") ? "GUARDIAN" : "ORG_ADMIN");
    return f;
  }

  void join(Family f, String target, String role) throws Exception {
    var invited =
        mvc.perform(
                post(f.root() + "/invitations")
                    .with(actor(f.owner()))
                    .with(csrf())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(
                        json.writeValueAsBytes(
                            Map.of("recipientEmail", target + "@example.test", "role", role))))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse();
    mvc.perform(
            post("/api/v1/invitations/accept")
                .with(actor(target))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsBytes(
                        Map.of(
                            "token",
                            json.readTree(invited.getContentAsString()).path("token").asText()))))
        .andExpect(status().isOk());
  }

  JsonNode start(Family f) throws Exception {
    return json.readTree(
        mvc.perform(
                post(f.root() + "/ownership-transfers")
                    .with(actor(f.owner()))
                    .with(csrf())
                    .header("If-Match", "\"0\"")
                    .header("Idempotency-Key", "start")
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(json.writeValueAsBytes(Map.of("targetActorId", f.target()))))
            .andExpect(status().isCreated())
            .andExpect(header().string("ETag", "\"0\""))
            .andExpect(jsonPath("$.state").value("PENDING"))
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  String path(Family f, JsonNode proposal) {
    return f.root() + "/ownership-transfers/" + proposal.path("id").asText();
  }

  void role(Family f, String who, String expected) throws Exception {
    mvc.perform(get(f.root() + "/membership").with(actor(who)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.role").value(expected));
  }

  @Test
  void bothAdultsConfirmAndOldJwtImmediatelyLosesOwnerPowers() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    role(f, f.owner(), "OWNER");
    role(f, f.target(), "GUARDIAN");
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.target()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "accept"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("ACCEPTED"))
        .andExpect(header().string("ETag", "\"1\""));
    role(f, f.owner(), "GUARDIAN");
    role(f, f.target(), "OWNER");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND role='OWNER' AND"
                    + " revoked_at IS NULL",
                Integer.class,
                f.id()))
        .isEqualTo(1);
    mvc.perform(get(f.root() + "/members").with(actor(f.owner())))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.target()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "accept"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(1));
    assertThat(db.queryForObject("SELECT version FROM tenants WHERE id=?", Long.class, f.id()))
        .isZero();
    assertThat(
            db.queryForList(
                "SELECT version FROM tenant_members WHERE tenant_id=? ORDER BY actor_key",
                Long.class,
                f.id()))
        .containsExactly(1L, 1L);
  }

  @Test
  void recipientRequiresRecentMfaAdultQualificationAndCorrectIdentity() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.owner()))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.target(), false, true))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.target(), true, false))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    role(f, f.owner(), "OWNER");
  }

  @Test
  void unrelatedMemberCannotSeeTransferAndDeclineKeepsOriginalOwner() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    String other = "a-" + UUID.randomUUID();
    join(f, other, "AUDITOR");
    mvc.perform(get(path(f, p)).with(actor(other))).andExpect(status().isForbidden());
    mvc.perform(get(f.root() + "/ownership-transfers").with(actor(other)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(0));
    mvc.perform(get(f.root() + "/ownership-transfers").with(actor(f.target())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1));
    mvc.perform(
            post(path(f, p) + "/decline")
                .with(actor(f.target()))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("DECLINED"));
    role(f, f.owner(), "OWNER");
  }

  @Test
  void expiredProposalCannotChangeRolesAndIsPersistedAsExpired() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    db.update("UPDATE ownership_transfers SET expires_at=1 WHERE tenant_id=?", f.id());
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.target()))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("EXPIRED"));
    role(f, f.owner(), "OWNER");
    assertThat(
            db.queryForObject(
                "SELECT state FROM ownership_transfers WHERE tenant_id=?", String.class, f.id()))
        .isEqualTo("EXPIRED");
  }

  @Test
  void tenantEditInvalidatesProposal() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    mvc.perform(
            patch(f.root())
                .with(actor(f.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"新名称\",\"timeZone\":\"UTC\"}"))
        .andExpect(status().isOk());
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.target()))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("INVALIDATED"))
        .andExpect(jsonPath("$.reason").value("TENANT_CHANGED"));
    role(f, f.owner(), "OWNER");
  }

  @Test
  void removeAndRejoinCannotReviveOldConsent() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    mvc.perform(delete(f.root() + "/members/" + f.target()).with(actor(f.owner())).with(csrf()))
        .andExpect(status().isNoContent());
    join(f, f.target(), "GUARDIAN");
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.target()))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("INVALIDATED"))
        .andExpect(jsonPath("$.reason").value("MEMBERSHIP_CHANGED"));
    role(f, f.owner(), "OWNER");
  }

  @Test
  void pendingProposalIsUniqueAndCanBeCancelled() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    mvc.perform(
            post(f.root() + "/ownership-transfers")
                .with(actor(f.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("targetActorId", f.target()))))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("OWNERSHIP_TRANSFER_PENDING"));
    mvc.perform(
            post(path(f, p) + "/cancel")
                .with(actor(f.owner()))
                .with(csrf())
                .header("If-Match", "\"9\""))
        .andExpect(status().isPreconditionFailed());
    mvc.perform(
            post(path(f, p) + "/cancel")
                .with(actor(f.owner()))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("CANCELLED"));
    role(f, f.owner(), "OWNER");
  }

  @Test
  void organizationFormerOwnerBecomesAdmin() throws Exception {
    var f = family("ORGANIZATION");
    var p = start(f);
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.target()))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.formerOwnerRole").value("ORG_ADMIN"));
    role(f, f.owner(), "ORG_ADMIN");
    role(f, f.target(), "OWNER");
  }

  @Test
  void concurrentAcceptAndCancelHaveExactlyOneWinner() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
    var gate = new java.util.concurrent.CountDownLatch(1);
    try {
      var accept =
          pool.submit(
              () -> {
                gate.await();
                return mvc.perform(
                        post(path(f, p) + "/accept")
                            .with(actor(f.target()))
                            .with(csrf())
                            .header("If-Match", "\"0\""))
                    .andReturn()
                    .getResponse()
                    .getStatus();
              });
      var cancel =
          pool.submit(
              () -> {
                gate.await();
                return mvc.perform(
                        post(path(f, p) + "/cancel")
                            .with(actor(f.owner()))
                            .with(csrf())
                            .header("If-Match", "\"0\""))
                    .andReturn()
                    .getResponse()
                    .getStatus();
              });
      gate.countDown();
      int a = accept.get(20, java.util.concurrent.TimeUnit.SECONDS),
          c = cancel.get(20, java.util.concurrent.TimeUnit.SECONDS);
      assertThat(a == 200 ^ c == 200).isTrue();
      assertThat(List.of(a, c)).allMatch(s -> s == 200 || s == 403 || s == 412);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND role='OWNER' AND"
                      + " revoked_at IS NULL",
                  Integer.class,
                  f.id()))
          .isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM ownership_heads WHERE tenant_id=? AND pending_transfer_id"
                      + " IS NOT NULL",
                  Integer.class,
                  f.id()))
          .isZero();
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void transferCancelsFormerOwnerSensitiveIntentAndRetainsPublishedEvidence() throws Exception {
    var f = family("FAMILY");
    var p = start(f);
    String tenant = f.id(), hash = com.aimanager.identity.ActorKeys.key(f.owner());
    long future = System.currentTimeMillis() + 3600000;
    // Explicit persisted business fixtures; this test exercises transaction listeners, not native
    // execution.
    String subject = UUID.randomUUID().toString(),
        device = UUID.randomUUID().toString(),
        registration = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,?,'AGE_7_12',?)",
        tenant,
        subject,
        "交接验证",
        System.currentTimeMillis());
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'等待设备','ANDROID','test','AWAITING_CONFIRMATION','{}',?,1)",
        tenant,
        device,
        subject,
        registration,
        hash);
    String enrollment = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " device_enrollments(tenant_id,id,subject_id,creator_actor_id,platform,requested_mode,token_hash,state,created_at,expires_at,device_id,pairing_hash)"
            + " VALUES(?,?,?,?,'ANDROID','BYOD',?,'AWAITING_CONFIRMATION',1,?,?,?)",
        tenant,
        enrollment,
        subject,
        f.owner(),
        com.aimanager.identity.ActorKeys.key(enrollment),
        future,
        device,
        hash);
    db.update(
        "INSERT INTO"
            + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
            + " VALUES(?,?,?,?,?,FALSE,1,?)",
        UUID.randomUUID().toString(),
        tenant,
        device,
        registration,
        com.aimanager.identity.ActorKeys.key(registration),
        future);
    String policy = UUID.randomUUID().toString(),
        preview = UUID.randomUUID().toString(),
        published = UUID.randomUUID().toString(),
        version = UUID.randomUUID().toString(),
        app = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'交接规则','FAMILY','[]',1,1)",
        tenant,
        policy);
    for (String id : List.of(preview, published))
      db.update(
          "INSERT INTO"
              + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at)"
              + " VALUES(?,?,?,0,?,'{}',1,?)",
          tenant,
          id,
          policy,
          hash,
          future);
    db.update(
        "INSERT INTO"
            + " policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at)"
            + " VALUES(?,?,?,0,1,?,?,'CONFIGURE_ONLY','{}',1)",
        tenant,
        version,
        policy,
        published,
        hash);
    db.update(
        "INSERT INTO application_definitions(tenant_id,id,identity_hash,definition_json)"
            + " VALUES(?,?,?,'{}')",
        tenant,
        app,
        hash);
    String request = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " access_requests(tenant_id,id,subject_id,device_id,registration_id,policy_id,base_version_id,base_sequence,application_id,rule_ids_json,requester_actor_id,requester_actor_key,requested_window_seconds,state,request_expires_at,granted_window_seconds,issued_at,absolute_not_after,approver_actor_id,approver_actor_key,created_at,updated_at)"
            + " VALUES(?,?,?,?,?,?,?,1,?,'[]',?,?,60,'APPROVED_PENDING_DELIVERY',?,60,1,?,?,?,1,1)",
        tenant,
        request,
        subject,
        UUID.randomUUID().toString(),
        UUID.randomUUID().toString(),
        policy,
        version,
        app,
        f.target(),
        com.aimanager.identity.ActorKeys.key(f.target()),
        future,
        future,
        f.owner(),
        hash);
    String exit = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " deprovision_previews(tenant_id,id,device_id,registration_id,device_version,actor_key,preview_hash,expires_at)"
            + " VALUES(?,?,?,?,0,?,?,?)",
        tenant,
        exit,
        device,
        registration,
        hash,
        hash,
        future);
    mvc.perform(
            post(f.root() + "/invitations")
                .with(actor(f.owner()))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"recipientEmail\":\"pending@example.test\",\"role\":\"GUARDIAN\"}"))
        .andExpect(status().isCreated());
    mvc.perform(
            post(path(f, p) + "/accept")
                .with(actor(f.target()))
                .with(csrf())
                .header("If-Match", "\"0\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("ACCEPTED"));
    assertThat(
            db.queryForObject(
                "SELECT state FROM device_enrollments WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                enrollment))
        .isEqualTo("CANCELLED");
    assertThat(
            db.queryForObject(
                "SELECT state FROM devices WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                device))
        .isEqualTo("REVOKED");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM device_credentials WHERE tenant_id=? AND revoked_at IS NULL",
                Integer.class,
                tenant))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT expires_at FROM policy_previews WHERE tenant_id=? AND id=?",
                Long.class,
                tenant,
                preview))
        .isLessThan(future);
    assertThat(
            db.queryForObject(
                "SELECT expires_at FROM policy_previews WHERE tenant_id=? AND id=?",
                Long.class,
                tenant,
                published))
        .isEqualTo(future);
    assertThat(
            db.queryForObject(
                "SELECT expires_at FROM deprovision_previews WHERE tenant_id=? AND id=?",
                Long.class,
                tenant,
                exit))
        .isLessThan(future);
    assertThat(
            db.queryForObject(
                "SELECT state FROM access_requests WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                request))
        .isEqualTo("REVOKED");
    assertThat(
            db.queryForObject(
                "SELECT reason_code FROM access_requests WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                request))
        .isEqualTo("OWNERSHIP_CHANGED");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM member_invitations WHERE tenant_id=? AND consumed_at IS NULL"
                    + " AND revoked_at IS NULL",
                Integer.class,
                tenant))
        .isZero();
  }
}
