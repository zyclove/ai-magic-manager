package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.*;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.ECDSAVerifier;
import com.nimbusds.jose.jwk.*;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.*;
import org.springframework.context.annotation.*;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    properties = {
      "spring.datasource.url=${ACCESS_DELIVERY_TEST_DATABASE_URL:jdbc:h2:mem:access-delivery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${ACCESS_DELIVERY_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${ACCESS_DELIVERY_TEST_DATABASE_PASSWORD:}",
      "manager.approval.expiry-job.enabled=false",
      "manager.quota.materialization-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false"
    })
@AutoConfigureMockMvc
@Import(AccessDeliveryJourneyTest.TimeConfiguration.class)
class AccessDeliveryJourneyTest {
  @Test
  void aRetryCannotOutliveTheRemainingApprovedWindow() throws Exception {
    var s = scope();
    var token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    String id = json(document(token, r).andExpect(status().isOk())).get("documentId").asText();
    clock.set(clock.instant().plusSeconds(271));
    receipt(token, r, Map.of("documentId", id, "phase", "REJECTED", "reasonCode", "STORAGE_FAILED"))
        .andExpect(status().isOk());
    delivery(s, r).andExpect(jsonPath("$.retryStatus").value("WINDOW_ENDING"));
    retry(token, r, id, 1)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("ACCESS_RETRY_NOT_ALLOWED"));
    mvc.perform(
            post(devicePath(r) + "/delivery-retries")
                .with(actor(s.owner()))
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(Map.of("documentId", id, "failedAttempt", 1))))
        .andExpect(status().isForbidden());
  }

  @Test
  void transientRejectionRetriesWithoutChangingTheSignedGrant() throws Exception {
    var s = scope();
    var token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    var d = json(document(token, r).andExpect(status().isOk()));
    String id = d.get("documentId").asText();
    receipt(token, r, Map.of("documentId", id, "phase", "RECEIVED")).andExpect(status().isOk());
    receipt(token, r, Map.of("documentId", id, "phase", "REJECTED", "reasonCode", "STORAGE_FAILED"))
        .andExpect(status().isOk());
    retry(token, r, id, 1)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("ACCESS_RETRY_TOO_EARLY"));
    delivery(s, r)
        .andExpect(jsonPath("$.retryStatus").value("WAITING"))
        .andExpect(jsonPath("$.reasonCode").value("STORAGE_FAILED"));
    clock.set(clock.instant().plusSeconds(30));
    var retry = json(retry(token, r, id, 1).andExpect(status().isOk()));
    assertThat(retry.get("deliveryAttempt").asInt()).isEqualTo(2);
    assertThat(json(retry(token, r, id, 1).andExpect(status().isOk()))).isEqualTo(retry);
    var current = json(document(token, r).andExpect(status().isOk()));
    assertThat(current.get("signedDocument")).isEqualTo(d.get("signedDocument"));
    assertThat(current.get("documentIssuedAt")).isEqualTo(d.get("documentIssuedAt"));
    assertThat(current.get("approvalVersion")).isEqualTo(d.get("approvalVersion"));
    receipt(token, r, Map.of("documentId", id, "phase", "RECEIVED"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.current").value(false));
    receipt(token, r, Map.of("documentId", id, "phase", "STORED")).andExpect(status().isConflict());
    receipt(token, r, Map.of("documentId", id, "phase", "STORED", "deliveryAttempt", 2))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.current").value(true));
    delivery(s, r)
        .andExpect(jsonPath("$.deliveryState").value("STORED"))
        .andExpect(jsonPath("$.deliveryAttempt").value(2))
        .andExpect(jsonPath("$.executionState").value("NOT_ENFORCED"));
    mvc.perform(
            get(path(s) + "/" + r.get("id").asText() + "/documents/" + id + "/attempts")
                .with(actor(s.child())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(2))
        .andExpect(jsonPath("$.items[0].deliveryAttempt").value(2))
        .andExpect(jsonPath("$.items[1].reasonCode").value("STORAGE_FAILED"));
  }

  @Test
  void parallelRetryRequestsCreateOnlyOneSuccessor() throws Exception {
    var s = scope();
    var token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    String id = json(document(token, r).andExpect(status().isOk())).get("documentId").asText();
    receipt(
            token,
            r,
            Map.of("documentId", id, "phase", "REJECTED", "reasonCode", "BASELINE_MISSING"))
        .andExpect(status().isOk());
    clock.set(clock.instant().plusSeconds(30));
    var pool = java.util.concurrent.Executors.newFixedThreadPool(6);
    try {
      var tasks = new ArrayList<java.util.concurrent.Callable<JsonNode>>();
      for (int i = 0; i < 6; i++)
        tasks.add(() -> json(retry(token, r, id, 1).andExpect(status().isOk())));
      var results = new HashSet<JsonNode>();
      for (var future : pool.invokeAll(tasks))
        results.add(future.get(15, java.util.concurrent.TimeUnit.SECONDS));
      assertThat(results).hasSize(1);
      tasks.clear();
      for (int i = 0; i < 6; i++)
        tasks.add(
            () ->
                json(
                    receipt(
                            token,
                            r,
                            Map.of("documentId", id, "deliveryAttempt", 2, "phase", "STORED"))
                        .andExpect(status().isOk())));
      results.clear();
      for (var future : pool.invokeAll(tasks))
        results.add(future.get(15, java.util.concurrent.TimeUnit.SECONDS));
      assertThat(results).hasSize(1);
      assertThat(
              database.queryForObject(
                  "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                      + " action='ACCESS_DOCUMENT_STORED'",
                  Integer.class,
                  s.tenant()))
          .isEqualTo(1);
      assertThat(
              database.queryForObject(
                  "SELECT COUNT(*) FROM access_window_attempts WHERE tenant_id=?",
                  Integer.class,
                  s.tenant()))
          .isEqualTo(2);
      assertThat(
              database.queryForObject(
                  "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                      + " action='ACCESS_DOCUMENT_RETRIED'",
                  Integer.class,
                  s.tenant()))
          .isEqualTo(1);
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void retryDoesNotReviveExpiredOrRevokedWindowsAndPermanentErrorsNeedDiagnosis() throws Exception {
    for (String reason :
        List.of("SIGNATURE_INVALID", "EXPIRED", "UNSUPPORTED_SCHEMA", "WRONG_DEVICE", "OTHER")) {
      var s = scope();
      var token = token(s);
      var r = request(s, "create");
      approve(s, r, "approve");
      String id = json(document(token, r).andExpect(status().isOk())).get("documentId").asText();
      receipt(token, r, Map.of("documentId", id, "phase", "REJECTED", "reasonCode", reason))
          .andExpect(status().isOk());
      clock.set(clock.instant().plusSeconds(30));
      retry(token, r, id, 1)
          .andExpect(status().isConflict())
          .andExpect(jsonPath("$.errorCode").value("ACCESS_RETRY_NOT_ALLOWED"));
    }
    for (boolean revoke : List.of(false, true)) {
      var s = scope();
      var token = token(s);
      var r = request(s, "create");
      approve(s, r, "approve");
      String id = json(document(token, r).andExpect(status().isOk())).get("documentId").asText();
      receipt(
              token,
              r,
              Map.of("documentId", id, "phase", "REJECTED", "reasonCode", "STORAGE_FAILED"))
          .andExpect(status().isOk());
      if (revoke)
        mvc.perform(
                post(path(s) + "/" + r.get("id").asText() + "/revoke")
                    .with(actor(s.owner()))
                    .header("If-Match", "\"1\"")
                    .header("Idempotency-Key", "revoke"))
            .andExpect(status().isOk());
      else clock.set(clock.instant().plusSeconds(300));
      retry(token, r, id, 1)
          .andExpect(status().isConflict())
          .andExpect(jsonPath("$.errorCode").value("ACCESS_DOCUMENT_SUPERSEDED"));
      assertThat(
              envelope(json(document(token, r).andExpect(status().isOk()))).get("action").asText())
          .isEqualTo("REMOVE_ACCESS_WINDOW");
    }
  }

  @Test
  void removalRetriesHaveBackoffAndABoundedHistory() throws Exception {
    var s = scope();
    var token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    clock.set(clock.instant().plusSeconds(300));
    String id = json(document(token, r).andExpect(status().isOk())).get("documentId").asText();
    for (int attempt = 1; attempt <= 10; attempt++) {
      receipt(
              token,
              r,
              Map.of(
                  "documentId",
                  id,
                  "deliveryAttempt",
                  attempt,
                  "phase",
                  "REJECTED",
                  "reasonCode",
                  "STORAGE_FAILED"))
          .andExpect(status().isOk());
      long delay = Math.min(300, 30L << (attempt - 1));
      if (attempt == 10) {
        retry(token, r, id, attempt)
            .andExpect(status().isConflict())
            .andExpect(jsonPath("$.errorCode").value("ACCESS_RETRY_LIMIT"));
        break;
      }
      clock.set(clock.instant().plusSeconds(delay - 1));
      retry(token, r, id, attempt).andExpect(status().isConflict());
      clock.set(clock.instant().plusSeconds(1));
      retry(token, r, id, attempt)
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.deliveryAttempt").value(attempt + 1));
    }
    delivery(s, r).andExpect(jsonPath("$.retryStatus").value("EXHAUSTED"));
    mvc.perform(
            get(path(s) + "/" + r.get("id").asText() + "/documents/" + id + "/attempts")
                .with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(10));
    retry(token, r, id, 1)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.deliveryAttempt").value(2))
        .andExpect(jsonPath("$.current").value(false));
  }

  @Test
  void retryAndAttemptReadsRetainScopeAndAuditAtomicity() throws Exception {
    var s = scope();
    var token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    String id = json(document(token, r).andExpect(status().isOk())).get("documentId").asText();
    var other = scope();
    retry(token(other), r, id, 1).andExpect(status().isForbidden());
    retry(token, r, id, 0).andExpect(status().isBadRequest());
    retry(token, r, id, 1).andExpect(status().isConflict());
    receipt(token, r, Map.of("documentId", id, "phase", "STORED", "deliveryAttempt", 2))
        .andExpect(status().isForbidden());
    mvc.perform(
            get(path(s) + "/" + r.get("id").asText() + "/documents/" + id + "/attempts")
                .with(actor(other.owner())))
        .andExpect(status().isForbidden());
    receipt(token, r, Map.of("documentId", id, "phase", "REJECTED", "reasonCode", "STORAGE_FAILED"))
        .andExpect(status().isOk());
    clock.set(clock.instant().plusSeconds(30));
    String constraint = "ck_retry_" + UUID.randomUUID().toString().replace("-", "");
    database.execute(
        "ALTER TABLE audit_events ADD CONSTRAINT "
            + constraint
            + " CHECK(tenant_id<>'"
            + s.tenant()
            + "' OR action<>'ACCESS_DOCUMENT_RETRIED')");
    try {
      retry(token, r, id, 1).andExpect(status().isInternalServerError());
    } finally {
      database.execute("ALTER TABLE audit_events DROP CONSTRAINT " + constraint);
    }
    delivery(s, r)
        .andExpect(jsonPath("$.deliveryAttempt").value(1))
        .andExpect(jsonPath("$.deliveryState").value("REJECTED"));
    assertThat(
            database.queryForObject(
                "SELECT COUNT(*) FROM access_window_attempts WHERE tenant_id=?",
                Integer.class,
                s.tenant()))
        .isEqualTo(1);
    retry(token, r, id, 1).andExpect(status().isOk());
    database.update(
        "UPDATE device_credentials SET revoked_at=? WHERE tenant_id=?", clock.millis(), s.tenant());
    retry(token, r, id, 1).andExpect(status().isUnauthorized());
  }

  private ResultActions retry(String token, JsonNode r, String id, int failedAttempt)
      throws Exception {
    return mvc.perform(
        post(devicePath(r) + "/delivery-retries")
            .header("Authorization", "Bearer " + token)
            .contentType(MediaType.APPLICATION_JSON)
            .content(
                mapper.writeValueAsString(
                    Map.of("documentId", id, "failedAttempt", failedAttempt))));
  }

  private ResultActions delivery(Scope s, JsonNode r) throws Exception {
    return mvc.perform(
            get(path(s) + "/" + r.get("id").asText() + "/delivery").with(actor(s.owner())))
        .andExpect(status().isOk());
  }

  @Test
  void anOldReceiptCannotConfirmTheCurrentRemoval() throws Exception {
    var s = scope();
    String token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    var old = json(document(token, r).andExpect(status().isOk()));
    mvc.perform(
            post(path(s) + "/" + r.get("id").asText() + "/revoke")
                .with(actor(s.owner()))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", "revoke"))
        .andExpect(status().isOk());
    receipt(token, r, Map.of("documentId", old.get("documentId").asText(), "phase", "STORED"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.current").value(false));
    mvc.perform(get(path(s) + "/" + r.get("id").asText() + "/delivery").with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.deliveryState").value("NOT_FETCHED"))
        .andExpect(jsonPath("$.action").value("REMOVE_ACCESS_WINDOW"));
    document(token, r).andExpect(status().isOk());
    mvc.perform(get(path(s) + "/" + r.get("id").asText() + "/documents").with(actor(s.child())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(2))
        .andExpect(
            jsonPath("$.items[?(@.current == true)].action")
                .value(org.hamcrest.Matchers.contains("REMOVE_ACCESS_WINDOW")));
  }

  @Test
  void lifecycleAndBaselineChangesDeliverRemovalToTheSameRegistration() throws Exception {
    for (String change : List.of("policy", "member", "subject")) {
      var s = scope();
      String token = token(s);
      var r = request(s, "create");
      approve(s, r, "approve");
      document(token, r).andExpect(status().isOk());
      if (change.equals("policy")) publish(s);
      else if (change.equals("member"))
        mvc.perform(
                delete("/api/v1/tenants/" + s.tenant() + "/members/" + s.child())
                    .with(actor(s.owner())))
            .andExpect(status().isNoContent());
      else
        mvc.perform(
                post("/api/v1/tenants/" + s.tenant() + "/subjects/" + s.subject() + "/archive")
                    .with(actor(s.owner()))
                    .header("If-Match", "\"0\""))
            .andExpect(status().isNoContent());
      var e = envelope(json(document(token, r).andExpect(status().isOk())));
      assertThat(e.get("action").asText()).isEqualTo("REMOVE_ACCESS_WINDOW");
      assertThat(e.get("approvalState").asText()).isEqualTo("REVOKED");
    }
  }

  @Test
  void parallelDownloadsCreateOneImmutableDocument() throws Exception {
    var s = scope();
    String token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    var pool = java.util.concurrent.Executors.newFixedThreadPool(6);
    try {
      var tasks = new ArrayList<java.util.concurrent.Callable<String>>();
      for (int i = 0; i < 6; i++)
        tasks.add(
            () ->
                json(document(token, r).andExpect(status().isOk())).get("signedDocument").asText());
      var values = new HashSet<String>();
      for (var result : pool.invokeAll(tasks))
        values.add(result.get(15, java.util.concurrent.TimeUnit.SECONDS));
      assertThat(values).hasSize(1);
      assertThat(
              database.queryForObject(
                  "SELECT COUNT(*) FROM access_window_documents WHERE tenant_id=?",
                  Integer.class,
                  s.tenant()))
          .isEqualTo(1);
      assertThat(
              database.queryForObject(
                  "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                      + " action='ACCESS_DOCUMENT_SIGNED'",
                  Integer.class,
                  s.tenant()))
          .isEqualTo(1);
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void receiptValidationAndRejectionReplayKeepTheirOriginalMeaning() throws Exception {
    var s = scope();
    String token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    var d = json(document(token, r).andExpect(status().isOk()));
    String id = d.get("documentId").asText();
    receipt(token, r, Map.of("documentId", id, "phase", "REJECTED"))
        .andExpect(status().isBadRequest());
    receipt(token, r, Map.of("documentId", id, "phase", "STORED", "reasonCode", "OTHER"))
        .andExpect(status().isBadRequest());
    var in =
        Map.<String, Object>of(
            "documentId", id, "phase", "REJECTED", "reasonCode", "BASELINE_MISSING");
    var first = json(receipt(token, r, in).andExpect(status().isOk()));
    clock.set(clock.instant().plusSeconds(1));
    assertThat(json(receipt(token, r, in).andExpect(status().isOk()))).isEqualTo(first);
    receipt(token, r, Map.of("documentId", id, "phase", "REJECTED", "reasonCode", "OTHER"))
        .andExpect(status().isConflict());
    receipt(token, r, Map.of("documentId", id, "phase", "STORED")).andExpect(status().isConflict());
    mvc.perform(
            get(path(s) + "/" + r.get("id").asText() + "/delivery").with(actor(scope().owner())))
        .andExpect(status().isForbidden());
  }

  @Test
  void signingPersistenceAndAuditFailAtomically() throws Exception {
    var s = scope();
    String token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    String name = "ck_access_audit_" + UUID.randomUUID().toString().replace("-", "");
    database.execute(
        "ALTER TABLE audit_events ADD CONSTRAINT "
            + name
            + " CHECK(tenant_id<>'"
            + s.tenant()
            + "' OR action<>'ACCESS_DOCUMENT_SIGNED')");
    try {
      document(token, r).andExpect(status().isInternalServerError());
    } finally {
      database.execute("ALTER TABLE audit_events DROP CONSTRAINT " + name);
    }
    assertThat(
            database.queryForObject(
                "SELECT COUNT(*) FROM access_window_documents WHERE tenant_id=?",
                Integer.class,
                s.tenant()))
        .isZero();
    document(token, r).andExpect(status().isOk());
  }

  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate database;
  @Autowired TestClock clock;
  @MockitoBean JwtDecoder decoder;
  static final ECKey KEY;
  static final Path KEY_FILE;

  static {
    try {
      KEY = new ECKeyGenerator(Curve.P_256).keyID("access-test").generate();
      Path dir = Path.of(".local").toAbsolutePath();
      Files.createDirectories(dir);
      KEY_FILE = Files.createTempFile(dir, "access-test-", ".jwk");
      Files.writeString(KEY_FILE, KEY.toJSONString());
    } catch (Exception e) {
      throw new IllegalStateException(e);
    }
  }

  @DynamicPropertySource
  static void properties(DynamicPropertyRegistry r) {
    r.add("manager.delivery.signing-key-file", () -> KEY_FILE.toString());
  }

  @AfterAll
  static void cleanup() throws Exception {
    Files.deleteIfExists(KEY_FILE);
  }

  @BeforeEach
  void reset() {
    clock.set(Instant.parse("2026-10-09T02:00:00Z"));
    doThrow(new BadJwtException("Not a user token")).when(decoder).decode(anyString());
  }

  private RequestPostProcessor actor(String name) {
    return jwt()
        .jwt(
            t ->
                t.subject(name)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private JsonNode body(String text) throws Exception {
    return mapper.readTree(text);
  }

  private String path(Scope s) {
    return "/api/v1/tenants/" + s.tenant() + "/access-requests";
  }

  private Scope scope() throws Exception {
    String owner = "approval-owner-" + UUID.randomUUID(),
        child = "approval-child-" + UUID.randomUUID();
    String tenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"家\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
            .get("id")
            .asText();
    String subject =
        body(mvc.perform(
                    post("/api/v1/tenants/" + tenant + "/subjects")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
            .get("id")
            .asText();
    database.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
    database.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,
        device,
        subject,
        registration,
        "设备",
        clock.millis());
    String application =
        body(mvc.perform(
                    post("/api/v1/tenants/" + tenant + "/applications")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            mapper.writeValueAsString(
                                Map.of(
                                    "displayName",
                                    "游戏",
                                    "platform",
                                    "ANDROID",
                                    "packageName",
                                    "org.example.game",
                                    "profile",
                                    "PRIMARY",
                                    "signingDigests",
                                    List.of("a".repeat(64))))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
            .get("id")
            .asText();
    String policy =
        body(mvc.perform(
                    post("/api/v1/tenants/" + tenant + "/policies")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            mapper.writeValueAsString(
                                Map.of(
                                    "name",
                                    "游戏规则",
                                    "kind",
                                    "POLICY",
                                    "rules",
                                    List.of(
                                        Map.of(
                                            "id",
                                            "game",
                                            "kind",
                                            "APP_LAUNCH",
                                            "effect",
                                            "DENY",
                                            "applicationId",
                                            application,
                                            "required",
                                            true))))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
            .get("id")
            .asText();
    var s =
        new Scope(owner, child, tenant, subject, device, registration, application, policy, null);
    String version = publish(s).get("versionId").asText();
    return new Scope(
        owner, child, tenant, subject, device, registration, application, policy, version);
  }

  private JsonNode publish(Scope s) throws Exception {
    String policyPath = "/api/v1/tenants/" + s.tenant() + "/policies/" + s.policy();
    var preview =
        body(
            mvc.perform(
                    post(policyPath + "/previews")
                        .with(actor(s.owner()))
                        .header("If-Match", "\"0\"")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            mapper.writeValueAsString(Map.of("deviceIds", List.of(s.device())))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    return body(
        mvc.perform(
                post(policyPath + "/publications")
                    .with(actor(s.owner()))
                    .header("If-Match", "\"0\"")
                    .header("Idempotency-Key", UUID.randomUUID())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(
                        mapper.writeValueAsString(
                            Map.of(
                                "previewId",
                                preview.get("id").asText(),
                                "previewHash",
                                preview.get("hash").asText(),
                                "mode",
                                "CONFIGURE_ONLY"))))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  private Map<String, Object> input(Scope s) {
    return Map.of(
        "deviceId",
        s.device(),
        "policyId",
        s.policy(),
        "baseVersionId",
        s.version(),
        "applicationId",
        s.application(),
        "ruleIds",
        List.of("game"),
        "requestedWindowSeconds",
        600,
        "reason",
        "想和同学一起玩一会");
  }

  private JsonNode request(Scope s, String key) throws Exception {
    return body(
        mvc.perform(
                post(path(s))
                    .with(actor(s.child()))
                    .header("Idempotency-Key", key)
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(mapper.writeValueAsString(input(s))))
            .andExpect(status().isCreated())
            .andExpect(header().string("ETag", "\"0\""))
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  private JsonNode approve(Scope s, JsonNode request, String key) throws Exception {
    return body(
        mvc.perform(
                post(path(s) + "/" + request.get("id").asText() + "/decisions")
                    .with(actor(s.owner()))
                    .header("If-Match", "\"0\"")
                    .header("Idempotency-Key", key)
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":300}"))
            .andExpect(status().isOk())
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  private String token(Scope s) {
    String value = SecretMaterial.token();
    database.update(
        "INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active)"
            + " VALUES(?,?,?,TRUE)",
        s.tenant(),
        s.registration(),
        s.device());
    database.update(
        "INSERT INTO"
            + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
            + " VALUES(?,?,?,?,?,TRUE,?,?)",
        UUID.randomUUID().toString(),
        s.tenant(),
        s.device(),
        s.registration(),
        SecretMaterial.hash(value),
        clock.millis(),
        clock.millis() + 86400000);
    return value;
  }

  private String devicePath(JsonNode request) {
    return "/api/v1/device-api/access-requests/" + request.get("id").asText();
  }

  private ResultActions document(String token, JsonNode request) throws Exception {
    return mvc.perform(
        get(devicePath(request) + "/document").header("Authorization", "Bearer " + token));
  }

  private JsonNode json(ResultActions result) throws Exception {
    return body(result.andReturn().getResponse().getContentAsString());
  }

  private JsonNode envelope(JsonNode doc) throws Exception {
    var jws = JWSObject.parse(doc.get("signedDocument").asText());
    assertThat(jws.getHeader().getType().toString()).isEqualTo("aimanager-access-window+jws");
    assertThat(jws.verify(new ECDSAVerifier(KEY.toPublicJWK()))).isTrue();
    return mapper.readTree(jws.getPayload().toString());
  }

  @Test
  void signedWindowBindsScopeAndReplaysTheOriginalDeadline() throws Exception {
    var s = scope();
    String token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    var d = json(document(token, r).andExpect(status().isOk()));
    var e = envelope(d);
    assertThat(e.get("tenantId").asText()).isEqualTo(s.tenant());
    assertThat(e.get("subjectId").asText()).isEqualTo(s.subject());
    assertThat(e.get("deviceId").asText()).isEqualTo(s.device());
    assertThat(e.get("registrationId").asText()).isEqualTo(s.registration());
    assertThat(e.get("baseVersionId").asText()).isEqualTo(s.version());
    assertThat(e.get("ruleIds").get(0).asText()).isEqualTo("game");
    assertThat(e.get("quotaEffect").asText()).isEqualTo("UNCHANGED");
    assertThat(e.get("mode").asText()).isEqualTo("CONFIGURE_ONLY");
    assertThat(e.get("action").asText()).isEqualTo("UPSERT_ACCESS_WINDOW");
    assertThat(e.get("absoluteNotAfter").asLong()).isEqualTo(clock.millis() + 300000);
    assertThat(e.toString()).doesNotContain(s.owner(), s.child(), "想和同学");
    clock.set(clock.instant().plusSeconds(10));
    assertThat(json(document(token, r).andExpect(status().isOk()))).isEqualTo(d);
    mvc.perform(
            get("/api/v1/device-api/access-requests").header("Authorization", "Bearer " + token))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].requestId").value(r.get("id").asText()));
  }

  @Test
  void revokedAndExpiredWindowsDeliverRemovalWithoutReissuingGrant() throws Exception {
    var s = scope();
    String token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    var first = json(document(token, r).andExpect(status().isOk()));
    mvc.perform(
            post(path(s) + "/" + r.get("id").asText() + "/revoke")
                .with(actor(s.owner()))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", "revoke"))
        .andExpect(status().isOk());
    var removed = json(document(token, r).andExpect(status().isOk()));
    assertThat(envelope(removed).get("action").asText()).isEqualTo("REMOVE_ACCESS_WINDOW");
    assertThat(removed.get("approvalVersion").asLong()).isEqualTo(2);
    assertThat(removed.get("documentId")).isNotEqualTo(first.get("documentId"));
    var b = scope();
    String other = token(b);
    var r2 = request(b, "create");
    approve(b, r2, "approve");
    clock.set(clock.instant().plusSeconds(300));
    assertThat(
            envelope(json(document(other, r2).andExpect(status().isOk())))
                .get("approvalState")
                .asText())
        .isEqualTo("EXPIRED");
  }

  @Test
  void deviceCannotReadOtherScopeOrUnapprovedDocument() throws Exception {
    var s = scope();
    String token = token(s);
    var r = request(s, "create");
    document(token, r).andExpect(status().isConflict());
    approve(s, r, "approve");
    var other = scope();
    document(token(other), r).andExpect(status().isForbidden());
    mvc.perform(get(devicePath(r) + "/document").with(actor(s.owner())))
        .andExpect(status().isForbidden());
    mvc.perform(get(devicePath(r) + "/document")).andExpect(status().isUnauthorized());
    database.update(
        "UPDATE device_credentials SET revoked_at=? WHERE tenant_id=?", clock.millis(), s.tenant());
    document(token, r).andExpect(status().isUnauthorized());
  }

  @Test
  void receiptStagesAreIdempotentAndNeverClaimEnforcement() throws Exception {
    var s = scope();
    String token = token(s);
    var r = request(s, "create");
    approve(s, r, "approve");
    var d = json(document(token, r).andExpect(status().isOk()));
    var in = new HashMap<String, Object>();
    in.put("documentId", d.get("documentId").asText());
    in.put("phase", "RECEIVED");
    var first = json(receipt(token, r, in).andExpect(status().isOk()));
    assertThat(json(receipt(token, r, in).andExpect(status().isOk()))).isEqualTo(first);
    in.put("phase", "STORED");
    receipt(token, r, in)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.executionState").value("NOT_ENFORCED"));
    in.put("phase", "RECEIVED");
    receipt(token, r, in).andExpect(status().isOk());
    in.put("phase", "REJECTED");
    in.put("reasonCode", "STORAGE_FAILED");
    receipt(token, r, in).andExpect(status().isConflict());
    mvc.perform(get(path(s) + "/" + r.get("id").asText() + "/delivery").with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.deliveryState").value("STORED"));
  }

  private ResultActions receipt(String token, JsonNode r, Map<String, Object> in) throws Exception {
    return mvc.perform(
        post(devicePath(r) + "/receipts")
            .header("Authorization", "Bearer " + token)
            .contentType(MediaType.APPLICATION_JSON)
            .content(mapper.writeValueAsString(in)));
  }

  private record Scope(
      String owner,
      String child,
      String tenant,
      String subject,
      String device,
      String registration,
      String application,
      String policy,
      String version) {}

  @TestConfiguration
  static class TimeConfiguration {
    @Bean
    @Primary
    TestClock accessDeliveryClock() {
      return new TestClock();
    }
  }

  static class TestClock extends Clock {
    private final AtomicReference<Instant> now =
        new AtomicReference<>(Instant.parse("2026-10-09T02:00:00Z"));

    void set(Instant time) {
      now.set(time);
    }

    @Override
    public ZoneId getZone() {
      return ZoneOffset.UTC;
    }

    @Override
    public Clock withZone(ZoneId z) {
      return Clock.fixed(instant(), z);
    }

    @Override
    public Instant instant() {
      return now.get();
    }
  }
}
