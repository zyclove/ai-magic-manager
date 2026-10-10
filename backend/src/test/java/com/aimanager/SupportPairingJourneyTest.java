package com.aimanager;

import static org.assertj.core.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    properties = {
      "spring.datasource.url=${SUPPORT_TEST_DATABASE_URL:jdbc:h2:mem:support-pairing;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${SUPPORT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${SUPPORT_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false",
      "manager.report-jobs.worker.enabled=false"
    })
@AutoConfigureMockMvc(
    print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
class SupportPairingJourneyTest {
  @RepeatedTest(5)
  void concurrentCreatesRespectCapacityAndDuplicateKeysReturnOneCode() throws Exception {
    var workers = java.util.concurrent.Executors.newFixedThreadPool(3);
    try {
      var start = new java.util.concurrent.CountDownLatch(1);
      var a =
          workers.submit(
              () -> {
                start.await();
                return body(create("same-key").andExpect(status().isCreated()));
              });
      var b =
          workers.submit(
              () -> {
                start.await();
                return body(create("same-key").andExpect(status().isCreated()));
              });
      var thirdAttempt =
          workers.submit(
              () -> {
                start.await();
                return body(create("same-key").andExpect(status().isCreated()));
              });
      start.countDown();
      var first = a.get(10, java.util.concurrent.TimeUnit.SECONDS);
      var second = b.get(10, java.util.concurrent.TimeUnit.SECONDS);
      var third = thirdAttempt.get(10, java.util.concurrent.TimeUnit.SECONDS);
      assertThat(first.path("request").path("id")).isEqualTo(second.path("request").path("id"));
      assertThat(third.path("request").path("id")).isEqualTo(first.path("request").path("id"));
      assertThat(
              java.util.stream.Stream.of(first, second, third)
                  .filter(item -> !item.path("code").isNull())
                  .count())
          .isEqualTo(1);
      create("second-request").andExpect(status().isCreated());
      var race = new java.util.concurrent.CountDownLatch(1);
      var c =
          workers.submit(
              () -> {
                race.await();
                return statusOf(create("capacity-race-1"));
              });
      var d =
          workers.submit(
              () -> {
                race.await();
                return statusOf(create("capacity-race-2"));
              });
      race.countDown();
      assertThat(
              List.of(
                  c.get(10, java.util.concurrent.TimeUnit.SECONDS),
                  d.get(10, java.util.concurrent.TimeUnit.SECONDS)))
          .containsExactlyInAnyOrder(201, 409);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM support_pairing_requests WHERE recipient_actor_id=?",
                  Integer.class,
                  recipient))
          .isEqualTo(3);
    } finally {
      workers.shutdownNow();
      workers.awaitTermination(5, java.util.concurrent.TimeUnit.SECONDS);
    }
  }

  private int statusOf(ResultActions action) throws Exception {
    var response = action.andReturn();
    if (response.getResponse().getStatus() == 500)
      throw new AssertionError(
          "Unexpected internal pairing error", response.getResolvedException());
    return response.getResponse().getStatus();
  }

  @Test
  void parallelFailedResolutionsKeepExactIndependentRateAccounting() throws Exception {
    var workers = java.util.concurrent.Executors.newFixedThreadPool(4);
    try {
      var start = new java.util.concurrent.CountDownLatch(1);
      var results = new java.util.ArrayList<java.util.concurrent.Future<Integer>>();
      for (int i = 0; i < 12; i++)
        results.add(
            workers.submit(
                () -> {
                  start.await();
                  return statusOf(resolve("a".repeat(43)));
                }));
      start.countDown();
      for (var result : results)
        assertThat(result.get(10, java.util.concurrent.TimeUnit.SECONDS)).isEqualTo(404);
      assertThat(
              db.queryForObject(
                  "SELECT resolve_count FROM support_pairing_heads WHERE actor_key=?",
                  Integer.class,
                  com.aimanager.identity.ActorKeys.key(owner)))
          .isEqualTo(12);
    } finally {
      workers.shutdownNow();
      workers.awaitTermination(5, java.util.concurrent.TimeUnit.SECONDS);
    }
  }

  @Test
  void cancellingRequestsCannotBypassCreationRateLimit() throws Exception {
    for (int i = 0; i < 5; i++) {
      var created = body(create("rate-" + i).andExpect(status().isCreated()));
      String id = created.path("request").path("id").asText();
      mvc.perform(
              post(ROOT + "/" + id + "/cancel")
                  .with(actor(recipient))
                  .header("If-Match", "\"0\"")
                  .header("Idempotency-Key", "cancel-rate-" + i))
          .andExpect(status().isOk());
    }
    create("rate-sixth").andExpect(status().isTooManyRequests());
    create("rate-0").andExpect(status().isCreated()).andExpect(jsonPath("$.code").isEmpty());
    assertThat(
            db.queryForObject(
                "SELECT create_count FROM support_pairing_heads WHERE actor_key=?",
                Integer.class,
                com.aimanager.identity.ActorKeys.key(recipient)))
        .isEqualTo(5);
  }

  @Test
  void consumedPairingCannotBeCancelledAsIfItRevokedAnExistingGrant() throws Exception {
    var created = body(create("consume").andExpect(status().isCreated()));
    String id = created.path("request").path("id").asText();
    db.update("UPDATE support_pairing_requests SET state='CONSUMED',version=1 WHERE id=?", id);
    resolve(created.path("code").asText()).andExpect(status().isNotFound());
    mvc.perform(
            post(ROOT + "/" + id + "/cancel")
                .with(actor(recipient))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", "consumed-cancel"))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("SUPPORT_PAIRING_ALREADY_USED"));
    create("consume")
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.request.state").value("CONSUMED"));
  }

  @Test
  void issuerSubjectCaseIsNotCollapsedByDatabaseCollation() throws Exception {
    recipient = "Case-sensitive-" + UUID.randomUUID();
    String original = recipient;
    var first = body(create("case-key").andExpect(status().isCreated()));
    recipient = recipient.toLowerCase(java.util.Locale.ROOT);
    mvc.perform(get(ROOT + "/" + first.path("request").path("id").asText()).with(actor(recipient)))
        .andExpect(status().isForbidden());
    var second = body(create("case-key").andExpect(status().isCreated()));
    assertThat(second.path("request").path("id")).isNotEqualTo(first.path("request").path("id"));
    assertThat(first.path("request").path("recipientActorId").asText()).isEqualTo(original);
  }

  @Test
  void unverifiedEmailIsNotShownAndListingStaysBounded() throws Exception {
    var unverified =
        jwt()
            .jwt(
                j ->
                    j.subject(recipient)
                        .issuedAt(Instant.now())
                        .claim("auth_time", Instant.now().getEpochSecond())
                        .claim("amr", List.of("pwd", "otp"))
                        .claim("email", "unverified@example.test")
                        .claim("email_verified", false))
            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
    var created =
        body(
            mvc.perform(post(ROOT).with(unverified).header("Idempotency-Key", "unverified"))
                .andExpect(status().isCreated()));
    assertThat(created.path("request").path("verifiedEmail").isNull()).isTrue();
    create("page-two").andExpect(status().isCreated());
    var page =
        body(
            mvc.perform(get(ROOT).param("limit", "1").with(actor(recipient)))
                .andExpect(status().isOk()));
    assertThat(page.path("items").size()).isEqualTo(1);
    var next =
        body(
            mvc.perform(
                    get(ROOT)
                        .param("limit", "1")
                        .param("cursor", page.path("nextCursor").asText())
                        .with(actor(recipient)))
                .andExpect(status().isOk()));
    assertThat(next.path("items").size()).isEqualTo(1);
    assertThat(next.path("items").get(0).path("id"))
        .isNotEqualTo(page.path("items").get(0).path("id"));
    mvc.perform(get(ROOT).param("limit", "101").with(actor(recipient)))
        .andExpect(status().isBadRequest());
  }

  static final String ROOT = "/api/v1/support/pairing-requests";
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper json;
  String recipient, owner, tenant;

  RequestPostProcessor identity(String id, boolean adult, boolean strong) {
    return jwt()
        .jwt(
            j ->
                j.subject(id)
                    .issuedAt(Instant.now())
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", strong ? List.of("pwd", "otp") : List.of("pwd"))
                    .claim("name", "Support recipient")
                    .claim("email", "recipient@example.test")
                    .claim("email_verified", true))
        .authorities(new SimpleGrantedAuthority(adult ? "SCOPE_tenant:create" : "SCOPE_openid"));
  }

  RequestPostProcessor actor(String id) {
    return identity(id, true, true);
  }

  JsonNode body(ResultActions response) throws Exception {
    return json.readTree(response.andReturn().getResponse().getContentAsByteArray());
  }

  ResultActions create(String key) throws Exception {
    return mvc.perform(post(ROOT).with(actor(recipient)).header("Idempotency-Key", key));
  }

  ResultActions resolve(String code) throws Exception {
    return mvc.perform(
        post("/api/v1/tenants/" + tenant + "/support-pairing/resolve")
            .with(actor(owner))
            .contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsBytes(java.util.Map.of("code", code))));
  }

  @BeforeEach
  void setup() throws Exception {
    recipient = "support-recipient-" + UUID.randomUUID();
    owner = "support-owner-" + UUID.randomUUID();
    tenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            "{\"name\":\"Support"
                                + " fixture\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated()))
            .path("id")
            .asText();
  }

  @Test
  void oneTimeCodeResolvesOnlyIdentityAndIsNeverJournaled() throws Exception {
    var created =
        body(
            create("create-1")
                .andExpect(status().isCreated())
                .andExpect(header().string("Cache-Control", "no-store")));
    String id = created.path("request").path("id").asText(), code = created.path("code").asText();
    assertThat(code).matches("[A-Za-z0-9_-]{43}");
    var resolved = body(resolve(code).andExpect(status().isOk()));
    assertThat(resolved.path("id").asText()).isEqualTo(id);
    assertThat(resolved.path("recipientActorId").asText()).isEqualTo(recipient);
    assertThat(resolved.path("verifiedEmail").asText()).isEqualTo("recipient@example.test");
    assertThat(resolved.toString()).doesNotContain("deviceId", "tenantId", code);
    assertThat(db.queryForList("SELECT * FROM support_pairing_requests WHERE id=?", id).toString())
        .doesNotContain(code);
    assertThat(
            db.queryForList(
                    "SELECT response_body FROM idempotency_requests WHERE actor_id=?", recipient)
                .toString())
        .doesNotContain(code);
    var retry = body(create("create-1").andExpect(status().isCreated()));
    assertThat(retry.path("code").isNull()).isTrue();
    assertThat(retry.path("request").path("id").asText()).isEqualTo(id);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM support_pairing_events WHERE request_id=? AND"
                    + " action='CREATED'",
                Integer.class,
                id))
        .isEqualTo(1);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='SUPPORT_PAIRING_RESOLVED'",
                Integer.class,
                tenant))
        .isEqualTo(1);
  }

  @Test
  void adultEligibilityAndRecentMfaAreRequiredEvenOnReplay() throws Exception {
    create("mfa-key").andExpect(status().isCreated());
    for (String method : List.of("create", "list")) {
      var request =
          method.equals("create") ? post(ROOT).header("Idempotency-Key", "mfa-key") : get(ROOT);
      mvc.perform(request.with(identity(recipient, false, true))).andExpect(status().isForbidden());
      mvc.perform(request.with(identity(recipient, true, false)))
          .andExpect(status().isUnauthorized())
          .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    }
  }

  @Test
  void requiresIdempotencyAndNeverGivesAnotherActorAccessToRequest() throws Exception {
    mvc.perform(post(ROOT).with(actor(recipient))).andExpect(status().isBadRequest());
    String id =
        body(create("owner-key").andExpect(status().isCreated()))
            .path("request")
            .path("id")
            .asText();
    mvc.perform(get(ROOT + "/" + id).with(actor(owner))).andExpect(status().isForbidden());
    mvc.perform(
            post(ROOT + "/" + id + "/cancel")
                .with(actor(owner))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "other-cancel"))
        .andExpect(status().isForbidden());
    mvc.perform(get(ROOT).with(actor(owner)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items").isEmpty());
    mvc.perform(get(ROOT).with(actor(recipient)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1));
  }

  @Test
  void cancellationUsesVersionsAndReplayReturnsCurrentState() throws Exception {
    var created = body(create("cancel-create").andExpect(status().isCreated()));
    String id = created.path("request").path("id").asText(), code = created.path("code").asText();
    mvc.perform(
            post(ROOT + "/" + id + "/cancel")
                .with(actor(recipient))
                .header("Idempotency-Key", "cancel"))
        .andExpect(status().isPreconditionRequired());
    mvc.perform(
            post(ROOT + "/" + id + "/cancel")
                .with(actor(recipient))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", "wrong-version"))
        .andExpect(status().isPreconditionFailed());
    for (int i = 0; i < 2; i++)
      mvc.perform(
              post(ROOT + "/" + id + "/cancel")
                  .with(actor(recipient))
                  .header("If-Match", "\"0\"")
                  .header("Idempotency-Key", "cancel"))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.state").value("CANCELLED"))
          .andExpect(header().string("ETag", "\"1\""));
    resolve(code)
        .andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("SUPPORT_PAIRING_UNAVAILABLE"));
    var retried = body(create("cancel-create").andExpect(status().isCreated()));
    assertThat(retried.path("request").path("state").asText()).isEqualTo("CANCELLED");
    assertThat(retried.path("code").isNull()).isTrue();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM support_pairing_events WHERE request_id=? AND"
                    + " action='CANCELLED'",
                Integer.class,
                id))
        .isEqualTo(1);
  }

  @Test
  void expiredCodesAndUnknownCodesShareTheSameUnavailableError() throws Exception {
    var created = body(create("expired").andExpect(status().isCreated()));
    String id = created.path("request").path("id").asText();
    db.update(
        "UPDATE support_pairing_requests SET expires_at=? WHERE id=?",
        System.currentTimeMillis() - 1,
        id);
    resolve(created.path("code").asText())
        .andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("SUPPORT_PAIRING_UNAVAILABLE"));
    resolve("a".repeat(43))
        .andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("SUPPORT_PAIRING_UNAVAILABLE"));
    mvc.perform(get(ROOT + "/" + id).with(actor(recipient)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("EXPIRED"));
  }

  @Test
  void customerNeedsCurrentAdminMembershipAndRecentMfa() throws Exception {
    String code = body(create("resolve").andExpect(status().isCreated())).path("code").asText();
    for (String role : List.of("CHILD", "TEACHER", "AUDITOR")) {
      db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, tenant);
      resolve(code).andExpect(status().isForbidden());
    }
    db.update("UPDATE tenant_members SET role='OWNER' WHERE tenant_id=?", tenant);
    mvc.perform(
            post("/api/v1/tenants/" + tenant + "/support-pairing/resolve")
                .with(identity(owner, true, false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(java.util.Map.of("code", code))))
        .andExpect(status().isUnauthorized());
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", tenant);
    resolve(code).andExpect(status().isForbidden());
  }

  @Test
  void activeRequestCapacityIsBounded() throws Exception {
    for (int i = 0; i < 3; i++) create("capacity-" + i).andExpect(status().isCreated());
    create("capacity-4")
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("SUPPORT_PAIRING_CAPACITY_REACHED"));
    create("capacity-0").andExpect(status().isCreated()).andExpect(jsonPath("$.code").isEmpty());
  }

  @Test
  void failedResolutionsConsumeRateBudgetDespiteBusinessRollback() throws Exception {
    for (int i = 0; i < 60; i++) resolve("a".repeat(43)).andExpect(status().isNotFound());
    resolve("a".repeat(43))
        .andExpect(status().isTooManyRequests())
        .andExpect(jsonPath("$.errorCode").value("SUPPORT_PAIRING_RATE_LIMITED"));
  }
}
