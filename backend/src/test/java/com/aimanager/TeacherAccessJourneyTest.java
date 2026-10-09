package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.audit.AuditService;
import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.*;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.*;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.*;

/**
 * Real HTTP/SQL domains; JWT and active BYOD devices are explicit local fixtures, not IdP/OS proof.
 */
@SpringBootTest(
    properties = {
      "spring.datasource.url=${TEACHER_ACCESS_TEST_DATABASE_URL:jdbc:h2:mem:teacher-access;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${TEACHER_ACCESS_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${TEACHER_ACCESS_TEST_DATABASE_PASSWORD:}",
      "manager.approval.expiry-job.enabled=false",
      "manager.quota.materialization-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false"
    })
@AutoConfigureMockMvc
@Import(TeacherAccessJourneyTest.TimeConfiguration.class)
class TeacherAccessJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired TestClock clock;
  @MockitoSpyBean JdbcTemplate db;
  @MockitoSpyBean AuditService audit;
  @MockitoBean JwtDecoder decoder;

  @BeforeEach
  void time() {
    clock.set(Instant.parse("2026-10-09T02:00:00Z"));
  }

  RequestPostProcessor actor(String id) {
    return jwt()
        .jwt(
            t ->
                t.subject(id)
                    .claim("email", id + "@example.test")
                    .claim("email_verified", true)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  JsonNode body(ResultActions action) throws Exception {
    return json.readTree(action.andReturn().getResponse().getContentAsString());
  }

  ResultActions postAs(String path, String actor, Object body, String key, Long version)
      throws Exception {
    var request = post(path).with(actor(actor)).contentType(MediaType.APPLICATION_JSON);
    if (body != null) request.content(json.writeValueAsBytes(body));
    if (key != null) request.header("Idempotency-Key", key);
    if (version != null) request.header("If-Match", "\"" + version + "\"");
    return mvc.perform(request);
  }

  String create(String path, String actor, Object body) throws Exception {
    return body(postAs(path, actor, body, UUID.randomUUID().toString(), null)
            .andExpect(status().isCreated()))
        .path("id")
        .asText();
  }

  record Scope(
      String tenant,
      String owner,
      String teacher,
      String peer,
      String child,
      String subject,
      String otherSubject,
      String classroom,
      String secondClass,
      String device,
      String otherDevice,
      String app,
      String secondApp,
      String policy,
      String version) {
    String root() {
      return "/api/v1/tenants/" + tenant;
    }

    String requests() {
      return root() + "/access-requests";
    }
  }

  Scope scope() throws Exception {
    String owner = "teacher-owner-" + UUID.randomUUID();
    String tenant =
        create(
            "/api/v1/tenants",
            owner,
            Map.of("name", "机构申请", "kind", "ORGANIZATION", "timeZone", "UTC"));
    String root = "/api/v1/tenants/" + tenant;
    String subject =
        create(root + "/subjects", owner, Map.of("nickname", "一班学生", "ageBand", "AGE_7_12"));
    String other =
        create(root + "/subjects", owner, Map.of("nickname", "二班学生", "ageBand", "AGE_7_12"));
    String classroom = create(root + "/classes", owner, Map.of("name", "一班"));
    String second = create(root + "/classes", owner, Map.of("name", "二班"));
    postAs(
            root + "/classes/" + classroom + "/students",
            owner,
            Map.of("subjectId", subject),
            "add",
            0L)
        .andExpect(status().isOk());
    postAs(
            root + "/classes/" + second + "/students",
            owner,
            Map.of("subjectId", other),
            "add-second",
            0L)
        .andExpect(status().isOk());
    String teacher = teacher(root, owner, List.of(classroom));
    String peer = teacher(root, owner, List.of(classroom));
    String child = "request-child-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    String device = device(tenant, subject), otherDevice = device(tenant, other);
    String app = application(root, owner, "org.example.lesson"),
        secondApp = application(root, owner, "org.example.practice");
    String schedule =
        create(
            root + "/schedules",
            owner,
            Map.of(
                "name",
                "课程时间",
                "definition",
                Map.of(
                    "timeZone",
                    "UTC",
                    "weekly",
                    List.of(Map.of("day", "MONDAY", "start", "09:00", "end", "10:00")),
                    "exceptions",
                    List.of())));
    String policy =
        create(
            root + "/policies",
            owner,
            Map.of(
                "name",
                "课堂应用",
                "kind",
                "POLICY",
                "rules",
                List.of(
                    Map.of(
                        "id",
                        "lesson",
                        "kind",
                        "APP_LAUNCH",
                        "effect",
                        "DENY",
                        "applicationId",
                        app,
                        "required",
                        true),
                    Map.of(
                        "id",
                        "practice",
                        "kind",
                        "APP_LAUNCH",
                        "effect",
                        "DENY",
                        "applicationId",
                        secondApp,
                        "required",
                        true),
                    Map.of(
                        "id",
                        "window",
                        "kind",
                        "TIME_WINDOW",
                        "effect",
                        "ALLOW",
                        "scheduleId",
                        schedule,
                        "required",
                        true),
                    Map.of(
                        "id",
                        "quota",
                        "kind",
                        "DAILY_QUOTA",
                        "effect",
                        "LIMIT",
                        "applicationId",
                        app,
                        "seconds",
                        600,
                        "required",
                        true))));
    String version = publish(root, owner, policy, device);
    return new Scope(
        tenant,
        owner,
        teacher,
        peer,
        child,
        subject,
        other,
        classroom,
        second,
        device,
        otherDevice,
        app,
        secondApp,
        policy,
        version);
  }

  String teacher(String root, String owner, List<String> classes) throws Exception {
    String who = "teacher-" + UUID.randomUUID();
    var invitation =
        body(
            postAs(
                    root + "/invitations",
                    owner,
                    Map.of(
                        "recipientEmail",
                        who + "@example.test",
                        "role",
                        "TEACHER",
                        "classIds",
                        classes),
                    null,
                    null)
                .andExpect(status().isCreated()));
    postAs(
            "/api/v1/invitations/accept",
            who,
            Map.of("token", invitation.path("token").asText()),
            null,
            null)
        .andExpect(status().isOk());
    return who;
  }

  String application(String root, String owner, String pkg) throws Exception {
    return create(
        root + "/applications",
        owner,
        Map.of(
            "displayName",
            pkg,
            "platform",
            "ANDROID",
            "packageName",
            pkg,
            "profile",
            "PRIMARY",
            "signingDigests",
            List.of("a".repeat(64))));
  }

  String device(String tenant, String subject) {
    String id = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'机构设备','ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,
        id,
        subject,
        UUID.randomUUID().toString(),
        clock.millis());
    return id;
  }

  String publish(String root, String owner, String policy, String device) throws Exception {
    var preview =
        body(
            postAs(
                    root + "/policies/" + policy + "/previews",
                    owner,
                    Map.of("deviceIds", List.of(device)),
                    null,
                    0L)
                .andExpect(status().isCreated()));
    return body(postAs(
                root + "/policies/" + policy + "/publications",
                owner,
                Map.of(
                    "previewId",
                    preview.path("id").asText(),
                    "previewHash",
                    preview.path("hash").asText(),
                    "mode",
                    "CONFIGURE_ONLY"),
                UUID.randomUUID().toString(),
                0L)
            .andExpect(status().isCreated()))
        .path("versionId")
        .asText();
  }

  Map<String, Object> input(Scope s, boolean second) {
    return Map.of(
        "deviceId",
        s.device(),
        "policyId",
        s.policy(),
        "baseVersionId",
        s.version(),
        "applicationId",
        second ? s.secondApp() : s.app(),
        "ruleIds",
        List.of(second ? "practice" : "lesson", "window"),
        "requestedWindowSeconds",
        600,
        "reason",
        "本人的课堂申请理由");
  }

  JsonNode request(Scope s, String who, boolean second, String key) throws Exception {
    return body(
        postAs(s.requests(), who, input(s, second), key, null).andExpect(status().isCreated()));
  }

  JsonNode approve(Scope s, JsonNode request, String key) throws Exception {
    return body(
        postAs(
                s.requests() + "/" + request.path("id").asText() + "/decisions",
                s.owner(),
                Map.of("decision", "APPROVE", "grantedWindowSeconds", 300),
                key,
                0L)
            .andExpect(status().isOk()));
  }

  ResultActions remove(Scope s, String classroom, long version) throws Exception {
    return mvc.perform(
        delete(s.root() + "/classes/" + classroom + "/students/" + s.subject())
            .with(actor(s.owner()))
            .header("If-Match", "\"" + version + "\"")
            .header("Idempotency-Key", UUID.randomUUID()));
  }

  String state(Scope s, JsonNode request) {
    return db.queryForObject(
        "SELECT state FROM access_requests WHERE tenant_id=? AND id=?",
        String.class,
        s.tenant(),
        request.path("id").asText());
  }

  @Test
  void optionsAreScopedAndContainOnlySupportedRuleIdentities() throws Exception {
    var s = scope();
    var page =
        body(
            mvc.perform(
                    get(s.requests() + "/options")
                        .param("deviceId", s.device())
                        .with(actor(s.teacher())))
                .andExpect(status().isOk()));
    assertThat(page.path("items").size()).isEqualTo(1);
    var option = page.path("items").get(0);
    assertThat(option.path("baseVersionId").asText()).isEqualTo(s.version());
    assertThat(option.path("commonRules").get(0).path("id").asText()).isEqualTo("window");
    assertThat(option.path("applications").size()).isEqualTo(2);
    assertThat(option.toString())
        .doesNotContain("quota", "targets", "signingDigests", "scheduleId", s.otherDevice());
    mvc.perform(
            get(s.requests() + "/options")
                .param("deviceId", s.otherDevice())
                .with(actor(s.teacher())))
        .andExpect(status().isForbidden());
    mvc.perform(
            get(s.requests() + "/options")
                .param("deviceId", "not-a-device")
                .with(actor(s.teacher())))
        .andExpect(status().isBadRequest());
    mvc.perform(
            get(s.requests() + "/options")
                .param("deviceId", s.device())
                .param("limit", "101")
                .with(actor(s.teacher())))
        .andExpect(status().isBadRequest());
    mvc.perform(get(s.requests() + "/options").with(actor(s.teacher())))
        .andExpect(status().isBadRequest());
    mvc.perform(
            get(s.requests() + "/options")
                .param("deviceId", s.device())
                .param("cursor", "bad-cursor")
                .with(actor(s.teacher())))
        .andExpect(status().isBadRequest());
    for (String path :
        List.of("/policies", "/members", "/devices/" + s.device() + "/application-inventory"))
      mvc.perform(get(s.root() + path).with(actor(s.teacher()))).andExpect(status().isForbidden());
  }

  @Test
  void reasonsAndDeliveryMetadataBelongOnlyToTheExactRequester() throws Exception {
    var s = scope();
    var r = request(s, s.teacher(), false, "create");
    assertThat(request(s, s.teacher(), false, "create")).isEqualTo(r);
    for (String who : List.of(s.peer(), s.child())) {
      mvc.perform(get(s.requests()).with(actor(who)))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.items.length()").value(0));
      for (String suffix : List.of("", "/delivery", "/documents"))
        mvc.perform(get(s.requests() + "/" + r.path("id").asText() + suffix).with(actor(who)))
            .andExpect(status().isForbidden());
    }
    mvc.perform(get(s.requests() + "/" + r.path("id").asText()).with(actor(s.teacher())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.reason").value("本人的课堂申请理由"));
    mvc.perform(get(s.requests()).with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='ACCESS_REQUEST_CREATED'",
                Integer.class,
                s.tenant()))
        .isEqualTo(1);
    var child = request(s, s.child(), true, "child-create");
    mvc.perform(get(s.requests() + "/" + child.path("id").asText()).with(actor(s.teacher())))
        .andExpect(status().isForbidden());
  }

  @Test
  void cancellationRequiresOwnPendingVersionAndTeacherCannotDecide() throws Exception {
    var s = scope();
    var r = request(s, s.teacher(), false, "create");
    String path = s.requests() + "/" + r.path("id").asText();
    postAs(path + "/cancel", s.peer(), null, "foreign", 0L).andExpect(status().isForbidden());
    postAs(path + "/cancel", s.teacher(), null, "no-version", null)
        .andExpect(status().isPreconditionRequired());
    postAs(path + "/cancel", s.teacher(), null, "stale", 1L)
        .andExpect(status().isPreconditionFailed());
    postAs(
            path + "/decisions",
            s.teacher(),
            Map.of("decision", "APPROVE", "grantedWindowSeconds", 60),
            "decide",
            0L)
        .andExpect(status().isForbidden());
    postAs(path + "/revoke", s.teacher(), null, "revoke", 0L).andExpect(status().isForbidden());
    var cancelled =
        body(postAs(path + "/cancel", s.teacher(), null, "cancel", 0L).andExpect(status().isOk()));
    assertThat(cancelled.path("state").asText()).isEqualTo("CANCELLED");
    assertThat(
            body(
                postAs(path + "/cancel", s.teacher(), null, "cancel", 0L)
                    .andExpect(status().isOk())))
        .isEqualTo(cancelled);
    postAs(s.requests(), s.teacher(), input(s, false), "again", null)
        .andExpect(status().isTooManyRequests());
  }

  @Test
  void rosterRemovalInvalidatesBeforeCommitAndOldJwtOrCacheCannotReviveIt() throws Exception {
    var s = scope();
    var r = request(s, s.teacher(), false, "create");
    remove(s, s.classroom(), 1).andExpect(status().isOk());
    assertThat(state(s, r)).isEqualTo("INVALIDATED");
    postAs(s.requests(), s.teacher(), input(s, false), "create", null)
        .andExpect(status().isForbidden());
    mvc.perform(get(s.requests() + "/" + r.path("id").asText()).with(actor(s.teacher())))
        .andExpect(status().isForbidden());
    postAs(
            s.root() + "/classes/" + s.classroom() + "/students",
            s.owner(),
            Map.of("subjectId", s.subject()),
            "restore",
            2L)
        .andExpect(status().isOk());
    var replay = request(s, s.teacher(), false, "create");
    assertThat(replay.path("state").asText()).isEqualTo("INVALIDATED");
    assertThat(replay.path("version").asLong()).isEqualTo(1);
  }

  @Test
  void approvedScopeLossProducesWithdrawalAndApprovalReplayReturnsCurrentFacts() throws Exception {
    var s = scope();
    var r = request(s, s.teacher(), false, "create");
    var approved = approve(s, r, "approve");
    remove(s, s.classroom(), 1).andExpect(status().isOk());
    assertThat(state(s, r)).isEqualTo("REVOKED");
    var replay = approve(s, r, "approve");
    assertThat(replay.path("state").asText()).isEqualTo("REVOKED");
    assertThat(replay.path("absoluteNotAfter")).isEqualTo(approved.path("absoluteNotAfter"));
    mvc.perform(
            get(s.requests() + "/" + r.path("id").asText() + "/delivery").with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.action").value("REMOVE_ACCESS_WINDOW"));
  }

  @Test
  void anotherAssignedClassPreservesAuthorityUntilTheLastClassIsArchived() throws Exception {
    var s = scope();
    postAs(
            s.root() + "/classes/" + s.secondClass() + "/students",
            s.owner(),
            Map.of("subjectId", s.subject()),
            "second",
            1L)
        .andExpect(status().isOk());
    var teacher = teacher(s.root(), s.owner(), List.of(s.classroom(), s.secondClass()));
    var r = request(s, teacher, false, "create");
    approve(s, r, "approve");
    remove(s, s.classroom(), 1).andExpect(status().isOk());
    assertThat(state(s, r)).isEqualTo("APPROVED_PENDING_DELIVERY");
    postAs(s.root() + "/classes/" + s.secondClass() + "/archive", s.owner(), null, "archive", 2L)
        .andExpect(status().isOk());
    assertThat(state(s, r)).isEqualTo("REVOKED");
  }

  @Test
  void transferRevokesOnlyTeachersWhoLoseAllApplicableClasses() throws Exception {
    var s = scope();
    var retained = teacher(s.root(), s.owner(), List.of(s.classroom(), s.secondClass()));
    var lost = request(s, s.teacher(), false, "lost");
    var keep = request(s, retained, true, "keep");
    postAs(
            s.root() + "/classes/" + s.classroom() + "/students/" + s.subject() + "/transfer",
            s.owner(),
            Map.of("targetClassId", s.secondClass(), "targetVersion", 1),
            "transfer",
            1L)
        .andExpect(status().isOk());
    assertThat(state(s, lost)).isEqualTo("INVALIDATED");
    assertThat(state(s, keep)).isEqualTo("PENDING");
  }

  @Test
  void expiredRequestsAndDecisionsReplayCurrentStateWithoutExtendingDeadlines() throws Exception {
    var s = scope();
    var r = request(s, s.teacher(), false, "create");
    var approved = approve(s, r, "approve");
    clock.set(clock.instant().plusSeconds(301));
    var replay = request(s, s.teacher(), false, "create");
    assertThat(replay.path("state").asText()).isEqualTo("EXPIRED");
    assertThat(replay.path("absoluteNotAfter")).isEqualTo(approved.path("absoluteNotAfter"));
    assertThat(approve(s, r, "approve").path("state").asText()).isEqualTo("EXPIRED");
  }

  @Test
  void memberScopeChangeInvalidatesPriorClassRequestsAndPreventsSelfApproval() throws Exception {
    var s = scope();
    var r = request(s, s.teacher(), false, "create");
    mvc.perform(
            patch(s.root() + "/members/" + ActorKeys.key(s.teacher()) + "/access")
                .with(actor(s.owner()))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "promote")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"role\":\"ORG_ADMIN\",\"classIds\":[]}"))
        .andExpect(status().isOk());
    assertThat(state(s, r)).isEqualTo("INVALIDATED");
    postAs(
            s.requests() + "/" + r.path("id").asText() + "/decisions",
            s.teacher(),
            Map.of("decision", "DENY"),
            "self",
            1L)
        .andExpect(status().isForbidden())
        .andExpect(jsonPath("$.errorCode").value("ACCESS_SELF_DECISION_FORBIDDEN"));
  }

  @Test
  void creationAndRosterRemovalSerializeOnTheCurrentTeacherMembership() throws Exception {
    var s = scope();
    var ready = new CountDownLatch(2);
    var go = new CountDownLatch(1);
    var executor = Executors.newFixedThreadPool(2);
    try {
      var creating =
          executor.submit(
              () -> {
                ready.countDown();
                go.await();
                return postAs(s.requests(), s.teacher(), input(s, false), "racing-create", null)
                    .andReturn()
                    .getResponse()
                    .getStatus();
              });
      var removing =
          executor.submit(
              () -> {
                ready.countDown();
                go.await();
                return remove(s, s.classroom(), 1).andReturn().getResponse().getStatus();
              });
      assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
      go.countDown();
      assertThat(creating.get(20, TimeUnit.SECONDS)).isIn(201, 403);
      assertThat(removing.get(20, TimeUnit.SECONDS)).isEqualTo(200);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM access_requests WHERE tenant_id=? AND state IN"
                      + " ('PENDING','APPROVED_PENDING_DELIVERY')",
                  Integer.class,
                  s.tenant()))
          .isZero();
    } finally {
      go.countDown();
      executor.shutdownNow();
    }
  }

  @Test
  @SuppressWarnings({"unchecked", "rawtypes"})
  void multiTeacherScopeLossAndListingUseOneRequestLockOrder() throws Exception {
    AuditService auditTarget =
        org.springframework.test.util.AopTestUtils.getUltimateTargetObject(audit);
    var s = scope();
    var teachers = new ArrayList<>(List.of(s.teacher(), s.peer()));
    teachers.sort(Comparator.comparing(ActorKeys::key));
    var high = request(s, teachers.get(0), false, "high");
    var low = request(s, teachers.get(1), true, "low");
    String highId = "ffffffff-ffff-ffff-ffff-ffffffffffff",
        lowId = "00000000-0000-0000-0000-000000000001";
    db.update(
        "UPDATE access_requests SET id=? WHERE tenant_id=? AND id=?",
        highId,
        s.tenant(),
        high.path("id").asText());
    db.update(
        "UPDATE access_requests SET id=? WHERE tenant_id=? AND id=?",
        lowId,
        s.tenant(),
        low.path("id").asText());
    String reader = "reader-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'AUDITOR')",
        s.tenant(),
        reader,
        ActorKeys.key(reader));
    var invalidationStarted = new CountDownLatch(1);
    var listingStarted = new CountDownLatch(1);
    var firstRowLocked = new CountDownLatch(1);
    var once = new AtomicBoolean();
    var executor = Executors.newFixedThreadPool(2);
    doAnswer(
            invocation -> {
              String sql = invocation.getArgument(0);
              boolean first =
                  Thread.currentThread().getName().equals("teacher-list-lock-order")
                      && sql.contains("AND id=?")
                      && sql.endsWith("FOR UPDATE")
                      && ((Object[]) invocation.getRawArguments()[2])[1].equals(lowId);
              if (first) listingStarted.countDown();
              var value = invocation.callRealMethod();
              if (first) firstRowLocked.countDown();
              return value;
            })
        .when(db)
        .query(anyString(), any(RowMapper.class), any(Object[].class));
    doAnswer(
            invocation -> {
              if ("ACCESS_ORGANIZATION_SCOPE_INVALIDATED".equals(invocation.getArgument(2))
                  && once.compareAndSet(false, true)) {
                invalidationStarted.countDown();
                if (!listingStarted.await(5, TimeUnit.SECONDS))
                  throw new IllegalStateException("List did not reach request lock");
                // Old grouped locks let the reader acquire lowId, then deadlock at highId. The
                // whole-event
                // lock holds both before audit; the reader remains blocked until invalidation
                // commits.
                firstRowLocked.await(500, TimeUnit.MILLISECONDS);
              }
              return invocation.callRealMethod();
            })
        .when(auditTarget)
        .record(anyString(), anyString(), anyString(), anyString());
    try {
      var removing =
          executor.submit(() -> remove(s, s.classroom(), 1).andReturn().getResponse().getStatus());
      assertThat(invalidationStarted.await(10, TimeUnit.SECONDS)).isTrue();
      var listing =
          executor.submit(
              () -> {
                Thread.currentThread().setName("teacher-list-lock-order");
                return mvc.perform(get(s.requests()).with(actor(reader)))
                    .andReturn()
                    .getResponse()
                    .getStatus();
              });
      assertThat(removing.get(20, TimeUnit.SECONDS)).isEqualTo(200);
      assertThat(listing.get(20, TimeUnit.SECONDS)).isEqualTo(200);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM access_requests WHERE tenant_id=? AND state='INVALIDATED'",
                  Integer.class,
                  s.tenant()))
          .isEqualTo(2);
    } finally {
      listingStarted.countDown();
      executor.shutdownNow();
      reset(db, auditTarget);
    }
  }

  @TestConfiguration
  static class TimeConfiguration {
    @Bean
    @Primary
    TestClock teacherClock() {
      return new TestClock();
    }
  }

  static class TestClock extends Clock {
    private final AtomicReference<Instant> time =
        new AtomicReference<>(Instant.parse("2026-10-09T02:00:00Z"));

    void set(Instant value) {
      time.set(value);
    }

    @Override
    public ZoneId getZone() {
      return ZoneOffset.UTC;
    }

    @Override
    public Clock withZone(ZoneId zone) {
      return Clock.fixed(instant(), zone);
    }

    @Override
    public Instant instant() {
      return time.get();
    }
  }
}
