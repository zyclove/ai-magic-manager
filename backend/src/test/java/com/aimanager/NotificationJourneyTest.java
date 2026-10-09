package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.approval.AccessRequest;
import com.aimanager.approval.AccessRequestChanged;
import com.aimanager.approval.ApprovalMaintenance;
import com.aimanager.identity.ActorKeys;
import com.aimanager.notification.NotificationMaintenance;
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
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.annotation.*;
import org.springframework.context.event.EventListener;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Actual domain transactions and SQL. JWT and active device setup are isolated test fixtures. */
@SpringBootTest(
    properties = {
      "spring.datasource.url=${NOTIFICATION_TEST_DATABASE_URL:jdbc:h2:mem:notifications;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${NOTIFICATION_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${NOTIFICATION_TEST_DATABASE_PASSWORD:}",
      "manager.approval.expiry-job.enabled=false",
      "manager.quota.materialization-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false",
      "manager.notifications.retention-job.enabled=false"
    })
@AutoConfigureMockMvc
@Import(NotificationJourneyTest.TimeConfiguration.class)
class NotificationJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @Autowired TestClock clock;
  @Autowired ApprovalMaintenance maintenance;
  @Autowired NotificationMaintenance notificationMaintenance;
  @Autowired ApplicationEventPublisher events;
  @Autowired PlatformTransactionManager transactions;
  @Autowired AtomicBoolean notificationFault;
  @MockitoBean JwtDecoder decoder;

  @BeforeEach
  void resetTime() {
    clock.now.set(Instant.parse("2026-10-09T02:00:00Z"));
    notificationFault.set(false);
  }

  RequestPostProcessor actor(String name) {
    return jwt()
        .jwt(
            t ->
                t.subject(name)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  JsonNode body(ResultActions response) throws Exception {
    return json.readTree(response.andReturn().getResponse().getContentAsString());
  }

  ResultActions postAs(String path, String who, Object input, String key, Long version)
      throws Exception {
    var request = post(path).with(actor(who)).contentType(MediaType.APPLICATION_JSON);
    if (input != null) request.content(json.writeValueAsBytes(input));
    if (key != null) request.header("Idempotency-Key", key);
    if (version != null) request.header("If-Match", "\"" + version + "\"");
    return mvc.perform(request);
  }

  String create(String path, String who, Object input) throws Exception {
    return body(postAs(path, who, input, UUID.randomUUID().toString(), null)
            .andExpect(status().isCreated()))
        .path("id")
        .asText();
  }

  record Scope(
      String tenant,
      String owner,
      String child,
      String subject,
      String device,
      String application,
      String policy,
      String version) {
    String root() {
      return "/api/v1/tenants/" + tenant;
    }

    String requests() {
      return root() + "/access-requests";
    }

    String inbox() {
      return root() + "/notifications";
    }
  }

  Scope scope() throws Exception {
    return scope("FAMILY");
  }

  Scope scope(String kind) throws Exception {
    String owner = "notice-owner-" + UUID.randomUUID(), child = "notice-child-" + UUID.randomUUID();
    String tenant =
        create("/api/v1/tenants", owner, Map.of("name", "通知家庭", "kind", kind, "timeZone", "UTC"));
    String root = "/api/v1/tenants/" + tenant;
    String subject =
        create(root + "/subjects", owner, Map.of("nickname", "孩子", "ageBand", "AGE_7_12"));
    member(tenant, child, "CHILD", subject);
    String device = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,
        device,
        subject,
        UUID.randomUUID().toString(),
        "学习设备",
        clock.millis());
    String app =
        create(
            root + "/applications",
            owner,
            Map.of(
                "displayName",
                "阅读",
                "platform",
                "ANDROID",
                "packageName",
                "org.example.reader",
                "profile",
                "PRIMARY",
                "signingDigests",
                List.of("a".repeat(64))));
    String policy =
        create(
            root + "/policies",
            owner,
            Map.of(
                "name",
                "基础规则",
                "kind",
                "POLICY",
                "rules",
                List.of(
                    Map.of(
                        "id",
                        "reading",
                        "kind",
                        "APP_LAUNCH",
                        "applicationId",
                        app,
                        "effect",
                        "DENY",
                        "required",
                        true))));
    var preview =
        body(
            postAs(
                    root + "/policies/" + policy + "/previews",
                    owner,
                    Map.of("deviceIds", List.of(device)),
                    null,
                    0L)
                .andExpect(status().isCreated()));
    var version =
        body(
            postAs(
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
                .andExpect(status().isCreated()));
    return new Scope(
        tenant, owner, child, subject, device, app, policy, version.path("versionId").asText());
  }

  void member(String tenant, String name, String role, String subject) {
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,?,?)",
        tenant,
        name,
        ActorKeys.key(name),
        role,
        subject);
  }

  JsonNode request(Scope s, String key) throws Exception {
    return body(
        postAs(
                s.requests(),
                s.child(),
                Map.of(
                    "deviceId",
                    s.device(),
                    "policyId",
                    s.policy(),
                    "baseVersionId",
                    s.version(),
                    "applicationId",
                    s.application(),
                    "ruleIds",
                    List.of("reading"),
                    "requestedWindowSeconds",
                    600,
                    "reason",
                    "PRIVATE_CHILD_REASON"),
                key,
                null)
            .andExpect(status().isCreated()));
  }

  JsonNode inbox(Scope s, String who, String query) throws Exception {
    return body(mvc.perform(get(s.inbox() + query).with(actor(who))).andExpect(status().isOk()));
  }

  JsonNode approve(Scope s, JsonNode request) throws Exception {
    return body(
        postAs(
                s.requests() + "/" + request.path("id").asText() + "/decisions",
                s.owner(),
                Map.of("decision", "APPROVE", "grantedWindowSeconds", 300),
                "approve",
                0L)
            .andExpect(status().isOk()));
  }

  @Test
  void requestReplayProducesOnePrivateNoticeAndReadStateBelongsToCurrentActor() throws Exception {
    var s = scope();
    var created = request(s, "create");
    request(s, "create");
    var page = inbox(s, s.owner(), "?limit=20");
    assertThat(page.path("items").size()).isEqualTo(1);
    var item = page.path("items").get(0);
    String id = item.path("id").asText();
    assertThat(item.path("requestId").asText()).isEqualTo(created.path("id").asText());
    assertThat(item.path("state").asText()).isEqualTo("PENDING");
    assertThat(item.path("readAt").isNull()).isTrue();
    assertThat(page.toString())
        .doesNotContain("PRIVATE_CHILD_REASON", s.child(), "requesterActorKey");
    mvc.perform(get(s.inbox() + "/unread-count").with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.count").value(1));
    var first =
        body(
            mvc.perform(put(s.inbox() + "/" + id + "/read").with(actor(s.owner())))
                .andExpect(status().isOk()));
    clock.advance(3);
    var repeat =
        body(
            mvc.perform(put(s.inbox() + "/" + id + "/read").with(actor(s.owner())))
                .andExpect(status().isOk()));
    assertThat(repeat).isEqualTo(first);
    assertThat(inbox(s, s.owner(), "?unreadOnly=true").path("items").isEmpty()).isTrue();
    assertThat(inbox(s, s.child(), "?unreadOnly=true").path("items").size()).isEqualTo(1);
  }

  @Test
  void approvalRevocationAndExpiryAreVersionedFactsWithoutClaimingExecution() throws Exception {
    var s = scope();
    var request = request(s, "create");
    clock.advance(1);
    var approved = approve(s, request);
    assertThat(approved.path("executionState").asText()).isEqualTo("NOT_ENFORCED");
    clock.advance(1);
    postAs(
            s.requests() + "/" + request.path("id").asText() + "/revoke",
            s.owner(),
            null,
            "revoke",
            1L)
        .andExpect(status().isOk());
    var items = inbox(s, s.child(), "").path("items");
    assertThat(items.size()).isEqualTo(3);
    assertThat(items.get(0).path("state").asText()).isEqualTo("REVOKED");
    assertThat(items.get(1).path("state").asText()).isEqualTo("APPROVED_PENDING_DELIVERY");
    assertThat(items.get(0).path("requestVersion").asLong()).isEqualTo(2);
    var other = scope();
    request(other, "expiry");
    clock.advance(1801);
    maintenance.expireDue(1000);
    assertThat(inbox(other, other.child(), "").path("items").get(0).path("state").asText())
        .isEqualTo("EXPIRED");
  }

  @Test
  void cancellationAndDenialCreateTheirOwnNotificationVersions() throws Exception {
    var s = scope();
    var r = request(s, "cancel");
    clock.advance(1);
    postAs(s.requests() + "/" + r.path("id").asText() + "/cancel", s.child(), null, "cancel", 0L)
        .andExpect(status().isOk());
    assertThat(inbox(s, s.owner(), "").path("items").get(0).path("state").asText())
        .isEqualTo("CANCELLED");
    clock.advance(61);
    var next = request(s, "deny");
    clock.advance(1);
    postAs(
            s.requests() + "/" + next.path("id").asText() + "/decisions",
            s.owner(),
            Map.of("decision", "DENY"),
            "deny",
            0L)
        .andExpect(status().isOk());
    assertThat(inbox(s, s.child(), "").path("items").get(0).path("state").asText())
        .isEqualTo("DENIED");
  }

  @Test
  void paginationDoesNotSkipEqualTimestampsAndBatchReadOnlyMarksExplicitIds() throws Exception {
    var s = scope();
    approve(s, request(s, "create"));
    var first = inbox(s, s.owner(), "?limit=1");
    var second = inbox(s, s.owner(), "?limit=1&cursor=" + first.path("nextCursor").asText());
    var firstId = first.path("items").get(0).path("id").asText();
    var secondId = second.path("items").get(0).path("id").asText();
    assertThat(firstId).isNotEqualTo(secondId);
    assertThat(second.path("nextCursor").isNull()).isTrue();
    postAs(s.inbox() + "/read", s.owner(), Map.of("ids", List.of(firstId)), null, null)
        .andExpect(status().isOk());
    var unread = inbox(s, s.owner(), "?unreadOnly=true").path("items");
    assertThat(unread.size()).isEqualTo(1);
    assertThat(unread.get(0).path("id").asText()).isEqualTo(secondId);
  }

  @Test
  void privateScopeRevocationAndCaseDistinctActorsCannotReadOrMarkEachOthersNotices()
      throws Exception {
    var s = scope();
    request(s, "create");
    var id = inbox(s, s.owner(), "").path("items").get(0).path("id").asText();
    String peer = s.child().toUpperCase(Locale.ROOT);
    member(s.tenant(), peer, "CHILD", s.subject());
    assertThat(inbox(s, peer, "").path("items").isEmpty()).isTrue();
    mvc.perform(put(s.inbox() + "/" + id + "/read").with(actor(peer)))
        .andExpect(status().isForbidden());
    String auditor = "auditor-" + UUID.randomUUID();
    member(s.tenant(), auditor, "AUDITOR", null);
    mvc.perform(get(s.inbox()).with(actor(auditor))).andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",
        s.tenant(),
        ActorKeys.key(s.child()));
    mvc.perform(get(s.inbox()).with(actor(s.child()))).andExpect(status().isForbidden());
    mvc.perform(put(s.inbox() + "/" + id + "/read").with(actor(s.child())))
        .andExpect(status().isForbidden());
    mvc.perform(get(s.inbox())).andExpect(status().isUnauthorized());
  }

  @Test
  void mixedScopeBatchIsAtomicAndMalformedInputIsRejected() throws Exception {
    var s = scope();
    request(s, "create");
    var other = scope();
    request(other, "create");
    String own = inbox(s, s.owner(), "").path("items").get(0).path("id").asText();
    String foreign = inbox(other, other.owner(), "").path("items").get(0).path("id").asText();
    postAs(s.inbox() + "/read", s.owner(), Map.of("ids", List.of(own, foreign)), null, null)
        .andExpect(status().isForbidden());
    assertThat(inbox(s, s.owner(), "?unreadOnly=true").path("items").size()).isEqualTo(1);
    for (var ids : List.of(List.of(), List.of(own, own), List.of("not-a-uuid"))) {
      postAs(s.inbox() + "/read", s.owner(), Map.of("ids", ids), null, null)
          .andExpect(status().isBadRequest());
    }
    for (String query :
        List.of("?limit=0", "?limit=51", "?cursor=invalid", "?unreadOnly=invalid")) {
      mvc.perform(get(s.inbox() + query).with(actor(s.owner()))).andExpect(status().isBadRequest());
    }
  }

  @Test
  void expiredRetentionIsExcludedFromListAndUnreadCountWithoutDeletingApprovalHistory()
      throws Exception {
    var s = scope();
    var r = request(s, "create");
    assertThat(inbox(s, s.owner(), "").path("items").size()).isEqualTo(1);
    clock.advance(31 * 86400);
    assertThat(inbox(s, s.owner(), "").path("items").isEmpty()).isTrue();
    mvc.perform(get(s.inbox() + "/unread-count").with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.count").value(0));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM access_requests WHERE tenant_id=? AND id=?",
                Integer.class,
                s.tenant(),
                r.path("id").asText()))
        .isEqualTo(1);
  }

  @Test
  void repeatedDomainDeliveryDoesNotDuplicateOrResetPersonalReadState() throws Exception {
    var s = scope();
    var r = request(s, "create");
    String id = inbox(s, s.owner(), "").path("items").get(0).path("id").asText();
    mvc.perform(put(s.inbox() + "/" + id + "/read").with(actor(s.owner())))
        .andExpect(status().isOk());
    var event =
        new AccessRequestChanged(
            s.tenant(),
            r.path("id").asText(),
            s.subject(),
            s.device(),
            ActorKeys.key(s.child()),
            0,
            AccessRequest.State.PENDING,
            clock.millis());
    new TransactionTemplate(transactions)
        .executeWithoutResult(
            status -> {
              events.publishEvent(event);
              events.publishEvent(event);
            });
    assertThat(inbox(s, s.owner(), "").path("items").size()).isEqualTo(1);
    assertThat(inbox(s, s.owner(), "?unreadOnly=true").path("items").isEmpty()).isTrue();
  }

  @Test
  void concurrentReadRetriesCreateExactlyOnePersonalReceipt() throws Exception {
    var s = scope();
    request(s, "create");
    String id = inbox(s, s.owner(), "").path("items").get(0).path("id").asText();
    var pool = Executors.newFixedThreadPool(6);
    var ready = new CountDownLatch(6);
    var go = new CountDownLatch(1);
    try {
      var futures = new ArrayList<Future<JsonNode>>();
      for (int i = 0; i < 6; i++)
        futures.add(
            pool.submit(
                () -> {
                  ready.countDown();
                  go.await(10, TimeUnit.SECONDS);
                  return body(
                      mvc.perform(put(s.inbox() + "/" + id + "/read").with(actor(s.owner())))
                          .andExpect(status().isOk()));
                }));
      assertThat(ready.await(10, TimeUnit.SECONDS)).isTrue();
      go.countDown();
      var first = futures.get(0).get(15, TimeUnit.SECONDS);
      for (var future : futures) assertThat(future.get(15, TimeUnit.SECONDS)).isEqualTo(first);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM notification_reads WHERE tenant_id=? AND notification_id=?",
                  Integer.class,
                  s.tenant(),
                  id))
          .isEqualTo(1);
    } finally {
      go.countDown();
      pool.shutdownNow();
    }
  }

  @Test
  void repeatedDeliverySeesConcurrentCommitBeyondAnEarlierSnapshot() throws Exception {
    var s = scope();
    var r = request(s, "create");
    db.update("DELETE FROM notification_events WHERE tenant_id=?", s.tenant());
    var event =
        new AccessRequestChanged(
            s.tenant(),
            r.path("id").asText(),
            s.subject(),
            s.device(),
            ActorKeys.key(s.child()),
            0,
            AccessRequest.State.PENDING,
            clock.millis());
    var pool = Executors.newSingleThreadExecutor();
    try {
      new TransactionTemplate(transactions)
          .executeWithoutResult(
              status -> {
                assertThat(
                        db.queryForObject(
                            "SELECT COUNT(*) FROM notification_events WHERE tenant_id=?",
                            Integer.class,
                            s.tenant()))
                    .isZero();
                try {
                  pool.submit(
                          () ->
                              new TransactionTemplate(transactions)
                                  .executeWithoutResult(other -> events.publishEvent(event)))
                      .get(10, TimeUnit.SECONDS);
                } catch (Exception failure) {
                  throw new IllegalStateException(failure);
                }
                events.publishEvent(event);
              });
      assertThat(inbox(s, s.owner(), "").path("items").size()).isEqualTo(1);
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void teacherNoticesRequireOwnRequestAndCurrentStudentScope() throws Exception {
    var s = scope("ORGANIZATION");
    String teacher = "teacher-" + UUID.randomUUID();
    String peer = "teacher-peer-" + UUID.randomUUID();
    member(s.tenant(), teacher, "TEACHER", s.subject());
    member(s.tenant(), peer, "TEACHER", s.subject());
    var teaching =
        new Scope(
            s.tenant(),
            s.owner(),
            teacher,
            s.subject(),
            s.device(),
            s.application(),
            s.policy(),
            s.version());
    request(teaching, "create");
    String id = inbox(s, teacher, "").path("items").get(0).path("id").asText();
    assertThat(inbox(s, peer, "").path("items").isEmpty()).isTrue();
    String other =
        create(
            s.root() + "/subjects", s.owner(), Map.of("nickname", "其他学生", "ageBand", "AGE_7_12"));
    db.update(
        "UPDATE tenant_members SET subject_id=?,version=version+1 WHERE tenant_id=? AND"
            + " actor_key=?",
        other,
        s.tenant(),
        ActorKeys.key(teacher));
    assertThat(inbox(s, teacher, "").path("items").isEmpty()).isTrue();
    mvc.perform(put(s.inbox() + "/" + id + "/read").with(actor(teacher)))
        .andExpect(status().isForbidden());
  }

  @Test
  void failedTransactionalNotificationRollsBackRequestAuditAndIdempotencyBeforeSafeRetry()
      throws Exception {
    var s = scope();
    notificationFault.set(true);
    try {
      postAs(
              s.requests(),
              s.child(),
              Map.of(
                  "deviceId",
                  s.device(),
                  "policyId",
                  s.policy(),
                  "baseVersionId",
                  s.version(),
                  "applicationId",
                  s.application(),
                  "ruleIds",
                  List.of("reading"),
                  "requestedWindowSeconds",
                  600,
                  "reason",
                  "PRIVATE_CHILD_REASON"),
              "retry",
              null)
          .andExpect(status().isInternalServerError());
    } finally {
      notificationFault.set(false);
    }
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM access_requests WHERE tenant_id=?",
                Integer.class,
                s.tenant()))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM notification_events WHERE tenant_id=?",
                Integer.class,
                s.tenant()))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='ACCESS_REQUEST_CREATED'",
                Integer.class,
                s.tenant()))
        .isZero();
    request(s, "retry");
    assertThat(inbox(s, s.owner(), "").path("items").size()).isEqualTo(1);
  }

  @Test
  void boundedRetentionRemovesOnlyOldNoticesAndTheirReceipts() throws Exception {
    var old = scope();
    request(old, "create");
    String id = inbox(old, old.owner(), "").path("items").get(0).path("id").asText();
    mvc.perform(put(old.inbox() + "/" + id + "/read").with(actor(old.owner())))
        .andExpect(status().isOk());
    clock.advance(31 * 86400);
    var current = scope();
    request(current, "new");
    int removed = notificationMaintenance.purgeExpired(1);
    assertThat(removed).isLessThanOrEqualTo(1);
    for (int i = 0; i < 20 && notificationMaintenance.purgeExpired(50) > 0; i++) {}
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM notification_events WHERE tenant_id=?",
                Integer.class,
                old.tenant()))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM notification_reads WHERE tenant_id=?",
                Integer.class,
                old.tenant()))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM access_requests WHERE tenant_id=?",
                Integer.class,
                old.tenant()))
        .isEqualTo(1);
    assertThat(inbox(current, current.owner(), "").path("items").size()).isEqualTo(1);
  }

  @TestConfiguration
  static class TimeConfiguration {
    @Bean
    AtomicBoolean notificationFault() {
      return new AtomicBoolean();
    }

    @Bean
    FaultListener notificationFailure(AtomicBoolean notificationFault) {
      return new FaultListener(notificationFault);
    }

    @Bean
    @Primary
    TestClock notificationClock() {
      return new TestClock();
    }
  }

  static class FaultListener {
    private final AtomicBoolean fault;

    FaultListener(AtomicBoolean fault) {
      this.fault = fault;
    }

    @EventListener
    public void fail(AccessRequestChanged event) {
      if (fault.get()) throw new IllegalStateException("notification failure fixture");
    }
  }

  static class TestClock extends Clock {
    final AtomicReference<Instant> now =
        new AtomicReference<>(Instant.parse("2026-10-09T02:00:00Z"));

    void advance(long seconds) {
      now.updateAndGet(t -> t.plusSeconds(seconds));
    }

    @Override
    public ZoneId getZone() {
      return ZoneOffset.UTC;
    }

    @Override
    public Clock withZone(ZoneId zone) {
      return this;
    }

    @Override
    public Instant instant() {
      return now.get();
    }
  }
}
