package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

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

@SpringBootTest(
    properties = {
      "spring.datasource.url=${MEMBER_TEST_DATABASE_URL:jdbc:h2:mem:member_access;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${MEMBER_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${MEMBER_TEST_DATABASE_PASSWORD:}",
      "spring.flyway.enabled=true"
    })
@AutoConfigureMockMvc
@org.springframework.context.annotation.Import(MemberAccessJourneyTest.FailureConfiguration.class)
class MemberAccessJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  @Autowired FailureListener failure;

  @org.springframework.boot.test.context.TestConfiguration
  static class FailureConfiguration {
    @org.springframework.context.annotation.Bean
    FailureListener failureListener() {
      return new FailureListener();
    }
  }

  static class FailureListener {
    volatile String tenant;

    @org.springframework.context.event.EventListener
    @org.springframework.core.annotation.Order(1000)
    public void on(com.aimanager.tenant.MembershipAccessChanged event) {
      if (event.tenantId().equals(tenant))
        throw new IllegalStateException("Intent cleanup verification failure");
    }
  }

  @Test
  void cleanupFailureRollsBackMembershipHistoryAndPendingInvitations() throws Exception {
    var s = space("ORGANIZATION");
    String admin = "ops-" + UUID.randomUUID();
    join(s, admin, "ORG_ADMIN", null);
    invite(s, admin, "recipient-" + UUID.randomUUID(), "AUDITOR", null);
    failure.tenant = s.id();
    try {
      mvc.perform(
              patch(s.access(admin))
                  .with(actor(s.owner()))
                  .with(csrf())
                  .header("If-Match", "\"0\"")
                  .contentType(MediaType.APPLICATION_JSON)
                  .content("{\"role\":\"AUDITOR\"}"))
          .andExpect(status().isInternalServerError());
    } finally {
      failure.tenant = null;
    }
    mvc.perform(get(s.access(admin)).with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(0))
        .andExpect(jsonPath("$.role").value("ORG_ADMIN"));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM membership_access_changes WHERE tenant_id=?",
                Integer.class,
                s.id()))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM member_invitations WHERE tenant_id=? AND consumed_at IS NULL"
                    + " AND revoked_at IS NULL",
                Integer.class,
                s.id()))
        .isEqualTo(1);
  }

  @Test
  void hashedRemovalUsesVersionAndCannotRevokeARejoinedMembershipOnRetry() throws Exception {
    var s = space("FAMILY");
    String member = "provider/user-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'AUDITOR')",
        s.id(),
        member,
        ActorKeys.key(member));
    mvc.perform(delete(s.access(member)).with(actor(s.owner())).with(csrf()))
        .andExpect(status().isPreconditionRequired());
    var request =
        delete(s.access(member))
            .with(actor(s.owner()))
            .with(csrf())
            .header("If-Match", "\"0\"")
            .header("Idempotency-Key", "remove");
    mvc.perform(request).andExpect(status().isNoContent());
    mvc.perform(request).andExpect(status().isNoContent());
    db.update(
        "UPDATE tenant_members SET revoked_at=NULL,version=version+1 WHERE tenant_id=? AND"
            + " actor_key=?",
        s.id(),
        ActorKeys.key(member));
    mvc.perform(request).andExpect(status().isNoContent());
    mvc.perform(get(s.access(member)).with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(2));
    mvc.perform(
            delete(s.access(member))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "new-remove"))
        .andExpect(status().isPreconditionFailed());
  }

  @Test
  void exactIdentityCleanupPreservesAnotherActorDespiteCaseInsensitiveCollation() throws Exception {
    var s = space("ORGANIZATION");
    String lower = "ops-" + UUID.randomUUID(), upper = lower.toUpperCase();
    String scope = subject(s);
    join(s, lower, "ORG_ADMIN", null);
    join(s, upper, "ORG_ADMIN", null);
    String own = invite(s, lower, "first-" + UUID.randomUUID(), "AUDITOR", null),
        other = invite(s, upper, "second-" + UUID.randomUUID(), "AUDITOR", null);
    var tickets = new java.util.HashMap<String, String>();
    for (String who : List.of(lower, upper))
      tickets.put(
          who,
          json.readTree(
                  mvc.perform(
                          post(s.root() + "/enrollments")
                              .with(actor(who))
                              .with(csrf())
                              .contentType(MediaType.APPLICATION_JSON)
                              .content(
                                  json.writeValueAsBytes(
                                      Map.of(
                                          "subjectId",
                                          scope,
                                          "platform",
                                          "ANDROID",
                                          "requestedMode",
                                          "BYOD"))))
                      .andExpect(status().isCreated())
                      .andReturn()
                      .getResponse()
                      .getContentAsString())
              .path("id")
              .asText());
    mvc.perform(
            patch(s.access(lower))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"AUDITOR\"}"))
        .andExpect(status().isOk());
    assertThat(
            db.queryForObject(
                "SELECT state FROM device_enrollments WHERE tenant_id=? AND id=?",
                String.class,
                s.id(),
                tickets.get(lower)))
        .isEqualTo("CANCELLED");
    assertThat(
            db.queryForObject(
                "SELECT state FROM device_enrollments WHERE tenant_id=? AND id=?",
                String.class,
                s.id(),
                tickets.get(upper)))
        .isEqualTo("PENDING_CLAIM");
    var invites =
        db.queryForList(
            "SELECT inviter_actor_id,revoked_at FROM member_invitations WHERE tenant_id=? AND"
                + " consumed_at IS NULL",
            s.id());
    assertThat(invites).hasSize(2);
    for (var row : invites)
      assertThat(row.get("revoked_at") != null)
          .isEqualTo(lower.equals(row.get("inviter_actor_id")));
    assertThat(own).isNotEqualTo(other);
  }

  @Test
  void concurrentEditsHaveOneWinnerAndHistoryPaginatesNewestFirst() throws Exception {
    var s = space("ORGANIZATION");
    String member = "teacher-" + UUID.randomUUID();
    String first = subject(s), second = subject(s), third = subject(s);
    join(s, member, "TEACHER", first);
    var executor = java.util.concurrent.Executors.newFixedThreadPool(2);
    var start = new java.util.concurrent.CountDownLatch(1);
    try {
      var futures = new java.util.ArrayList<java.util.concurrent.Future<Integer>>();
      for (String target : List.of(second, third))
        futures.add(
            executor.submit(
                () -> {
                  start.await();
                  return mvc.perform(
                          patch(s.access(member))
                              .with(actor(s.owner()))
                              .with(csrf())
                              .header("If-Match", "\"0\"")
                              .contentType(MediaType.APPLICATION_JSON)
                              .content(
                                  json.writeValueAsBytes(
                                      Map.of("role", "TEACHER", "subjectId", target))))
                      .andReturn()
                      .getResponse()
                      .getStatus();
                }));
      start.countDown();
      assertThat(
              List.of(
                  futures.get(0).get(20, java.util.concurrent.TimeUnit.SECONDS),
                  futures.get(1).get(20, java.util.concurrent.TimeUnit.SECONDS)))
          .containsExactlyInAnyOrder(200, 412);
    } finally {
      executor.shutdownNow();
    }
    var current =
        json.readTree(
            mvc.perform(get(s.access(member)).with(actor(s.owner())))
                .andReturn()
                .getResponse()
                .getContentAsString());
    mvc.perform(
            patch(s.access(member))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsBytes(
                        Map.of(
                            "role", "TEACHER", "subjectId", current.path("subjectId").asText()))))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(1));
    mvc.perform(
            patch(s.access(member))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"AUDITOR\"}"))
        .andExpect(status().isOk());
    var page =
        json.readTree(
            mvc.perform(get(s.access(member) + "-history?limit=1").with(actor(s.owner())))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[0].memberVersion").value(2))
                .andReturn()
                .getResponse()
                .getContentAsString());
    mvc.perform(
            get(s.access(member) + "-history?limit=1&cursor=" + page.path("nextCursor").asText())
                .with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].memberVersion").value(1))
        .andExpect(jsonPath("$.nextCursor").isEmpty());
    mvc.perform(
            get(s.access(s.owner()) + "-history?cursor=" + page.path("nextCursor").asText())
                .with(actor(s.owner())))
        .andExpect(status().isBadRequest());
  }

  @Test
  void demotionAndRejoinNeverReviveOldInvitationOrPairing() throws Exception {
    var s = space("ORGANIZATION");
    String admin = "ops-" + UUID.randomUUID(), recipient = "recipient-" + UUID.randomUUID();
    String scope = subject(s);
    join(s, admin, "ORG_ADMIN", null);
    String token = invite(s, admin, recipient, "AUDITOR", null);
    var ticket =
        json.readTree(
            mvc.perform(
                    post(s.root() + "/enrollments")
                        .with(actor(admin))
                        .with(csrf())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            json.writeValueAsBytes(
                                Map.of(
                                    "subjectId",
                                    scope,
                                    "platform",
                                    "ANDROID",
                                    "requestedMode",
                                    "BYOD"))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    mvc.perform(
            patch(s.access(admin))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"AUDITOR\"}"))
        .andExpect(status().isOk());
    assertThat(
            db.queryForObject(
                "SELECT state FROM device_enrollments WHERE tenant_id=? AND id=?",
                String.class,
                s.id(),
                ticket.path("id").asText()))
        .isEqualTo("CANCELLED");
    mvc.perform(
            patch(s.access(admin))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"ORG_ADMIN\"}"))
        .andExpect(status().isOk());
    mvc.perform(
            post("/api/v1/invitations/accept")
                .with(actor(recipient))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("token", token))))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("INVITATION_UNAVAILABLE"));
    String second = invite(s, admin, recipient, "AUDITOR", null);
    mvc.perform(delete(s.root() + "/members/" + admin).with(actor(s.owner())).with(csrf()))
        .andExpect(status().isNoContent());
    join(s, admin, "ORG_ADMIN", null);
    mvc.perform(
            post("/api/v1/invitations/accept")
                .with(actor(recipient))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("token", second))))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("INVITATION_UNAVAILABLE"));
  }

  @Test
  void accessHistoryKeepsRoleAndScopeDiffsWithoutDuplicateReplay() throws Exception {
    var s = space("FAMILY");
    String member = "adult-" + UUID.randomUUID();
    join(s, member, "GUARDIAN", null);
    var request =
        patch(s.access(member))
            .with(actor(s.owner()))
            .with(csrf())
            .header("If-Match", "\"0\"")
            .header("Idempotency-Key", "history")
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"role\":\"AUDITOR\"}");
    mvc.perform(request).andExpect(status().isOk());
    mvc.perform(request).andExpect(status().isOk());
    mvc.perform(get(s.access(member) + "-history").with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1))
        .andExpect(jsonPath("$.items[0].previousRole").value("GUARDIAN"))
        .andExpect(jsonPath("$.items[0].role").value("AUDITOR"))
        .andExpect(jsonPath("$.items[0].memberVersion").value(1));
    mvc.perform(get(s.access(member) + "-history").with(actor(member)))
        .andExpect(status().isForbidden());
  }

  @Test
  void olderClaimsCannotOverwriteNewIdentityOrChangeAccessVersion() throws Exception {
    var s = space("FAMILY");
    String member = "adult-" + UUID.randomUUID();
    join(s, member, "GUARDIAN", null);
    Instant base = Instant.now();
    var newer =
        jwt()
            .jwt(
                t ->
                    t.subject(member)
                        .issuedAt(base)
                        .claim("name", "新姓名")
                        .claim("email", "verified@example.test")
                        .claim("email_verified", true));
    mvc.perform(get("/api/v1/me").with(newer)).andExpect(status().isOk());
    mvc.perform(
            get("/api/v1/me")
                .with(
                    jwt()
                        .jwt(
                            t ->
                                t.subject(member)
                                    .issuedAt(base.minusSeconds(20))
                                    .claim("name", "旧姓名")
                                    .claim("email", "old@example.test")
                                    .claim("email_verified", true))))
        .andExpect(status().isOk());
    var rows =
        json.readTree(
                mvc.perform(get(s.root() + "/members").with(actor(s.owner())))
                    .andReturn()
                    .getResponse()
                    .getContentAsString())
            .path("items");
    for (JsonNode row : rows)
      if (row.path("actorId").asText().equals(member)) {
        assertThat(row.path("displayName").asText()).isEqualTo("新姓名");
        assertThat(row.path("verifiedEmail").asText()).isEqualTo("verified@example.test");
      }
    mvc.perform(get(s.access(member)).with(actor(s.owner())))
        .andExpect(header().string("ETag", "\"0\""));
    mvc.perform(
            get("/api/v1/me")
                .with(
                    jwt()
                        .jwt(
                            t ->
                                t.subject(member)
                                    .issuedAt(base.plusSeconds(1))
                                    .claim("name", "新姓名")
                                    .claim("email", "unverified@example.test")
                                    .claim("email_verified", false))))
        .andExpect(status().isOk());
    var after =
        json.readTree(
                mvc.perform(get(s.root() + "/members").with(actor(s.owner())))
                    .andReturn()
                    .getResponse()
                    .getContentAsString())
            .path("items");
    for (JsonNode row : after)
      if (row.path("actorId").asText().equals(member))
        assertThat(row.path("verifiedEmail").isNull()).isTrue();
  }

  @Test
  void roleChangeExpiresOnlyAttributableAndLegacyPreviews() throws Exception {
    var s = space("FAMILY");
    String member = "adult-" + UUID.randomUUID();
    join(s, member, "GUARDIAN", null);
    String policy = UUID.randomUUID().toString();
    long future = System.currentTimeMillis() + 3600000;
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'范围规则','FAMILY','[]',1,1)",
        s.id(),
        policy);
    String own = UUID.randomUUID().toString(),
        other = UUID.randomUUID().toString(),
        legacy = UUID.randomUUID().toString();
    for (String id : List.of(own, other, legacy))
      db.update(
          "INSERT INTO"
              + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at,creator_actor_key)"
              + " VALUES(?,?,?,0,?,'{}',1,?,?)",
          s.id(),
          id,
          policy,
          "a".repeat(64),
          future,
          id.equals(legacy) ? null : ActorKeys.key(id.equals(own) ? member : s.owner()));
    mvc.perform(
            patch(s.access(member))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"AUDITOR\"}"))
        .andExpect(status().isOk());
    for (String id : List.of(own, legacy))
      assertThat(
              db.queryForObject(
                  "SELECT expires_at FROM policy_previews WHERE tenant_id=? AND id=?",
                  Long.class,
                  s.id(),
                  id))
          .isLessThan(future);
    assertThat(
            db.queryForObject(
                "SELECT expires_at FROM policy_previews WHERE tenant_id=? AND id=?",
                Long.class,
                s.id(),
                other))
        .isEqualTo(future);
  }

  RequestPostProcessor actor(String id) {
    return actor(id, true, true);
  }

  RequestPostProcessor actor(String id, boolean adult, boolean mfa) {
    return jwt()
        .jwt(
            t ->
                t.subject(id)
                    .issuedAt(Instant.now().minusSeconds(2))
                    .claim("name", "成员 " + id)
                    .claim("email", id + "@example.test")
                    .claim("email_verified", true)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", mfa ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(
            new SimpleGrantedAuthority(adult ? "SCOPE_tenant:create" : "SCOPE_profile:read"));
  }

  record Space(String id, String owner) {
    String root() {
      return "/api/v1/tenants/" + id;
    }

    String access(String who) {
      return root() + "/members/" + ActorKeys.key(who) + "/access";
    }
  }

  Space space(String kind) throws Exception {
    String owner = "owner-" + UUID.randomUUID();
    var r =
        mvc.perform(
                post("/api/v1/tenants")
                    .with(actor(owner))
                    .with(csrf())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(
                        json.writeValueAsBytes(
                            Map.of("name", "成员权限", "kind", kind, "timeZone", "UTC"))))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse();
    return new Space(json.readTree(r.getContentAsString()).path("id").asText(), owner);
  }

  String subject(Space s) throws Exception {
    var r =
        mvc.perform(
                post(s.root() + "/subjects")
                    .with(actor(s.owner()))
                    .with(csrf())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("{\"nickname\":\"范围档案\",\"ageBand\":\"AGE_7_12\"}"))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse();
    return json.readTree(r.getContentAsString()).path("id").asText();
  }

  String invite(Space s, String inviter, String who, String role, String subject) throws Exception {
    var body = new java.util.HashMap<String, Object>();
    body.put("recipientEmail", who + "@example.test");
    body.put("role", role);
    if (subject != null) body.put("subjectId", subject);
    var r =
        mvc.perform(
                post(s.root() + "/invitations")
                    .with(actor(inviter))
                    .with(csrf())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(json.writeValueAsBytes(body)))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse();
    return json.readTree(r.getContentAsString()).path("token").asText();
  }

  void join(Space s, String who, String role, String subject) throws Exception {
    String token = invite(s, s.owner(), who, role, subject);
    mvc.perform(
            post("/api/v1/invitations/accept")
                .with(actor(who, !role.equals("CHILD"), true))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("token", token))))
        .andExpect(status().isOk());
  }

  @Test
  void adminCanChangeAdultRoleWithStrongVersionAndOldJwtLosesWriteAccess() throws Exception {
    var s = space("FAMILY");
    String member = "adult-" + UUID.randomUUID();
    join(s, member, "GUARDIAN", null);
    mvc.perform(get(s.access(member)).with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(header().string("ETag", "\"0\""))
        .andExpect(jsonPath("$.role").value("GUARDIAN"))
        .andExpect(jsonPath("$.verifiedEmail").doesNotExist());
    var change =
        patch(s.access(member))
            .with(actor(s.owner()))
            .with(csrf())
            .header("If-Match", "\"0\"")
            .header("Idempotency-Key", "change")
            .contentType(MediaType.APPLICATION_JSON)
            .content("{\"role\":\"AUDITOR\"}");
    mvc.perform(change)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(1))
        .andExpect(jsonPath("$.role").value("AUDITOR"));
    mvc.perform(change).andExpect(status().isOk()).andExpect(jsonPath("$.version").value(1));
    mvc.perform(
            post(s.root() + "/subjects")
                .with(actor(member))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"nickname\":\"禁止\",\"ageBand\":\"AGE_7_12\"}"))
        .andExpect(status().isForbidden());
    mvc.perform(get(s.root() + "/audit-events").with(actor(member))).andExpect(status().isOk());
    mvc.perform(
            patch(s.access(member))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"GUARDIAN\"}"))
        .andExpect(status().isPreconditionFailed());
  }

  @Test
  void ownerAndAdultClassificationCannotBeReassignedByRoleEditor() throws Exception {
    var s = space("FAMILY");
    String child = "child-" + UUID.randomUUID(), adult = "adult-" + UUID.randomUUID();
    String scope = subject(s);
    join(s, child, "CHILD", scope);
    join(s, adult, "GUARDIAN", null);
    mvc.perform(
            patch(s.access(s.owner()))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"GUARDIAN\"}"))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("OWNER_TRANSFER_REQUIRED"));
    mvc.perform(
            patch(s.access(child))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"GUARDIAN\"}"))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.errorCode").value("MEMBER_CLASS_CHANGE_REQUIRES_INVITATION"));
    mvc.perform(
            patch(s.access(adult))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("role", "CHILD", "subjectId", scope))))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.errorCode").value("MEMBER_CLASS_CHANGE_REQUIRES_INVITATION"));
    mvc.perform(
            patch(s.access(adult))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"OWNER\"}"))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.errorCode").value("ROLE_NOT_APPLICABLE"));
  }

  @Test
  void organizationRoleAndSubjectScopeRulesAreAppliedToChanges() throws Exception {
    var s = space("ORGANIZATION");
    String admin = "admin-" + UUID.randomUUID(), teacher = "teacher-" + UUID.randomUUID();
    String first = subject(s), second = subject(s);
    join(s, admin, "ORG_ADMIN", null);
    join(s, teacher, "TEACHER", first);
    mvc.perform(
            patch(s.access(teacher))
                .with(actor(admin))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"ORG_ADMIN\"}"))
        .andExpect(status().isForbidden());
    mvc.perform(
            patch(s.access(admin))
                .with(actor(admin))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"AUDITOR\"}"))
        .andExpect(status().isForbidden());
    mvc.perform(
            patch(s.access(teacher))
                .with(actor(s.owner()))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"TEACHER\"}"))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.errorCode").value("SUBJECT_SCOPE_REQUIRED"));
    mvc.perform(
            patch(s.access(teacher))
                .with(actor(admin))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("role", "TEACHER", "subjectId", second))))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.subjectId").value(second))
        .andExpect(jsonPath("$.version").value(1));
  }

  @Test
  void editsRequireCurrentManagementPermissionRecentMfaAndExplicitVersion() throws Exception {
    var s = space("FAMILY");
    String member = "g-" + UUID.randomUUID();
    join(s, member, "GUARDIAN", null);
    mvc.perform(get(s.access(member)).with(actor(member))).andExpect(status().isForbidden());
    mvc.perform(
            patch(s.access(member))
                .with(actor(s.owner(), true, false))
                .with(csrf())
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"AUDITOR\"}"))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    mvc.perform(
            patch(s.access(member))
                .with(actor(s.owner()))
                .with(csrf())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"AUDITOR\"}"))
        .andExpect(status().isPreconditionRequired());
    var other = space("FAMILY");
    mvc.perform(get(other.access(member)).with(actor(other.owner())))
        .andExpect(status().isForbidden());
  }

  @Test
  void membersHaveSignedIdentityDisplayButChildEmailIsNotShared() throws Exception {
    var s = space("FAMILY");
    String adult = "g-" + UUID.randomUUID(), child = "c-" + UUID.randomUUID();
    join(s, adult, "GUARDIAN", null);
    join(s, child, "CHILD", subject(s));
    var body =
        json.readTree(
            mvc.perform(get(s.root() + "/members").with(actor(s.owner())))
                .andExpect(status().isOk())
                .andReturn()
                .getResponse()
                .getContentAsString());
    for (JsonNode row : body.path("items")) {
      String who = row.path("actorId").asText();
      assertThat(row.path("displayName").asText()).isEqualTo("成员 " + who);
      if (who.equals(child)) assertThat(row.path("verifiedEmail").isNull()).isTrue();
      else assertThat(row.path("verifiedEmail").asText()).isEqualTo(who + "@example.test");
    }
  }
}
