package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.audit.AuditSelection;
import com.aimanager.audit.AuditService;
import com.aimanager.reporting.ExportMaintenance;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.JWEAlgorithm;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.KeyUse;
import com.nimbusds.jose.jwk.gen.OctetSequenceKeyGenerator;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.*;
import org.springframework.context.annotation.*;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Isolated real HTTP/SQL contract; MFA claims are fixtures, never production OTP evidence. */
@SpringBootTest(
    properties = {
      "spring.datasource.url=${AUDIT_EXPORT_TEST_DATABASE_URL:jdbc:h2:mem:audit-export;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${AUDIT_EXPORT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${AUDIT_EXPORT_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false",
      "manager.exports.max-rows=3",
      "manager.exports.max-bytes=2048",
      "manager.notifications.retention-job.enabled=false"
    })
@AutoConfigureMockMvc
@Import(AuditExportJourneyTest.TimeConfiguration.class)
class AuditExportJourneyTest {
  @MockitoSpyBean AuditService audit;

  @Test
  void twoWorkersPublishOnce() throws Exception {
    String id = create();
    var executor = Executors.newFixedThreadPool(2);
    try {
      var one = executor.submit(() -> maintenance.runBatch(25));
      var two = executor.submit(() -> maintenance.runBatch(25));
      one.get(15, TimeUnit.SECONDS);
      two.get(15, TimeUnit.SECONDS);
      assertThat(job(id).path("state").asText()).isEqualTo("READY");
      assertThat(job(id).path("attempts").asInt()).isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND resource_id=? AND"
                      + " action='AUDIT_EXPORT_GENERATED'",
                  Integer.class,
                  tenant,
                  id))
          .isEqualTo(1);
    } finally {
      executor.shutdownNow();
    }
  }

  @Test
  void transientGenerationFailureRetriesOnlyAfterBackoff() throws Exception {
    String id = create();
    doThrow(new IllegalStateException("isolated fault"))
        .when(audit)
        .exportEvents(eq(tenant), any(AuditSelection.class), anyInt());
    work();
    assertThat(job(id).path("state").asText()).isEqualTo("QUEUED");
    assertThat(job(id).path("attempts").asInt()).isEqualTo(1);
    doCallRealMethod().when(audit).exportEvents(eq(tenant), any(AuditSelection.class), anyInt());
    clock.value.addAndGet(29999);
    work();
    assertThat(job(id).path("attempts").asInt()).isEqualTo(1);
    clock.value.incrementAndGet();
    work();
    assertThat(job(id).path("state").asText()).isEqualTo("READY");
  }

  @Test
  void leaseLostDuringGenerationDoesNotPublishAnArtifact() throws Exception {
    String id = create();
    doAnswer(
            invocation -> {
              Object rows = invocation.callRealMethod();
              clock.value.addAndGet(60001);
              return rows;
            })
        .when(audit)
        .exportEvents(eq(tenant), any(AuditSelection.class), anyInt());
    work();
    assertThat(job(id).path("state").asText()).isEqualTo("QUEUED");
    assertThat(
            db.queryForObject(
                "SELECT artifact FROM audit_exports WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                id))
        .isNull();
    doCallRealMethod().when(audit).exportEvents(eq(tenant), any(AuditSelection.class), anyInt());
    clock.value.addAndGet(30000);
    work();
    assertThat(job(id).path("state").asText()).isEqualTo("READY");
  }

  @Test
  void revokedCreatorNeverStartsGeneratingAndOldMetadataIsPurged() throws Exception {
    String id = create();
    db.update(
        "UPDATE tenant_members SET revoked_at=?,version=version+1 WHERE tenant_id=?",
        new java.sql.Timestamp(NOW),
        tenant);
    work();
    assertThat(
            db.queryForObject(
                "SELECT state FROM audit_exports WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                id))
        .isEqualTo("REVOKED");
    assertThat(
            db.queryForObject(
                "SELECT attempts FROM audit_exports WHERE tenant_id=? AND id=?",
                Integer.class,
                tenant,
                id))
        .isZero();
    clock.value.addAndGet(31L * 86400000);
    maintenance.purge(100);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_exports WHERE tenant_id=? AND id=?",
                Integer.class,
                tenant,
                id))
        .isZero();
  }

  @Autowired(required = false)
  ExportMaintenance maintenance;

  void work() {
    assertThat(maintenance).as("durable export worker").isNotNull();
    maintenance.runBatch(10);
  }

  JsonNode job(String id) throws Exception {
    return body(mvc.perform(get(root + "/" + id).with(actor(owner))).andExpect(status().isOk()));
  }

  @Test
  void generationStoresOnlyAuthenticatedCiphertextAndDownloadsTheSelectedEvents() throws Exception {
    String id = create();
    work();
    assertThat(job(id).path("state").asText()).isEqualTo("READY");
    String artifact =
        db.queryForObject(
            "SELECT artifact FROM audit_exports WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            id);
    assertThat(artifact).doesNotContain(owner).doesNotContain("SUBJECT_CREATED");
    assertThat(
            com.nimbusds.jose.JWEObject.parse(artifact).getHeader().getEncryptionMethod().getName())
        .isEqualTo("A256GCM");
    var downloaded =
        body(
            mvc.perform(get(root + "/" + id + "/content").with(actor(owner)))
                .andExpect(status().isOk())
                .andExpect(header().string("Cache-Control", "no-store")));
    assertThat(downloaded.path("schemaVersion").asInt()).isEqualTo(1);
    assertThat(downloaded.path("events").size()).isEqualTo(2);
    assertThat(downloaded.path("recordCount").asInt()).isEqualTo(2);
    mvc.perform(
            get(root + "/" + id + "/content")
                .with(jwt().jwt(j -> j.subject(owner).claim("amr", List.of("pwd")))))
        .andExpect(status().isUnauthorized());
  }

  @Test
  void membershipEpochChangeRevokesArtifactsEvenWhenRoleRemainsAllowed() throws Exception {
    String id = create();
    work();
    db.update("UPDATE tenant_members SET version=version+1 WHERE tenant_id=?", tenant);
    assertThat(job(id).path("state").asText()).isEqualTo("REVOKED");
    mvc.perform(get(root + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isForbidden());
    maintenance.purge(20);
    assertThat(
            db.queryForObject(
                "SELECT artifact FROM audit_exports WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                id))
        .isNull();
  }

  @Test
  void expiredAndCancelledJobsDoNotKeepArtifacts() throws Exception {
    String id = create();
    work();
    clock.value.addAndGet(86400001);
    maintenance.purge(20);
    assertThat(job(id).path("state").asText()).isEqualTo("EXPIRED");
    assertThat(
            db.queryForObject(
                "SELECT artifact FROM audit_exports WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                id))
        .isNull();
    clock.value.set(NOW + 60001);
    String other = create();
    mvc.perform(post(root + "/" + other + "/cancel").with(actor(owner))).andExpect(status().isOk());
    work();
    assertThat(job(other).path("state").asText()).isEqualTo("CANCELLED");
    assertThat(job(other).path("attempts").asInt()).isZero();
  }

  @Test
  void abandonedLeaseCanRecoverAndAttemptBudgetIsBounded() throws Exception {
    String id = create();
    db.update(
        "UPDATE audit_exports SET state='RUNNING',claim_token=?,lease_until=?,attempts=1 WHERE"
            + " tenant_id=? AND id=?",
        UUID.randomUUID().toString(),
        NOW - 1,
        tenant,
        id);
    work();
    assertThat(job(id).path("state").asText()).isEqualTo("READY");
    assertThat(job(id).path("attempts").asInt()).isEqualTo(2);
    clock.value.addAndGet(60001);
    String failed = create();
    db.update(
        "UPDATE audit_exports SET state='RUNNING',claim_token=?,lease_until=?,attempts=3 WHERE"
            + " tenant_id=? AND id=?",
        UUID.randomUUID().toString(),
        NOW - 1,
        tenant,
        failed);
    work();
    assertThat(job(failed).path("state").asText()).isEqualTo("FAILED");
    assertThat(job(failed).path("failureCode").asText()).isEqualTo("EXPORT_ATTEMPTS_EXHAUSTED");
  }

  @Test
  void oversizedResultsFailWithoutPublishingPartialData() throws Exception {
    for (int n = 0; n < 2; n++)
      db.update(
          "INSERT INTO"
              + " audit_events(tenant_id,id,actor_id,action,resource_id,correlation_id,occurred_at)"
              + " VALUES(?,?,?,?,?,?,?)",
          tenant,
          UUID.randomUUID().toString(),
          owner,
          "SUBJECT_CREATED",
          RESOURCE,
          UUID.randomUUID().toString(),
          NOW - 2000 - n);
    String id = create();
    work();
    assertThat(job(id).path("state").asText()).isEqualTo("FAILED");
    assertThat(job(id).path("failureCode").asText()).isEqualTo("EXPORT_ROW_LIMIT_EXCEEDED");
    assertThat(
            db.queryForObject(
                "SELECT artifact FROM audit_exports WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                id))
        .isNull();
  }

  @Test
  void byteBudgetAndCrossJobCiphertextBindingAreEnforced() throws Exception {
    String id = create();
    work();
    clock.value.addAndGet(60001);
    String second = create();
    work();
    String firstArtifact =
        db.queryForObject(
            "SELECT artifact FROM audit_exports WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            id);
    db.update(
        "UPDATE audit_exports SET artifact=? WHERE tenant_id=? AND id=?",
        firstArtifact,
        tenant,
        second);
    mvc.perform(get(root + "/" + second + "/content").with(actor(owner)))
        .andExpect(status().isServiceUnavailable());
    clock.value.addAndGet(60001);
    db.update(
        "INSERT INTO"
            + " audit_events(tenant_id,id,actor_id,action,resource_id,correlation_id,occurred_at)"
            + " VALUES(?,?,?,?,?,?,?)",
        tenant,
        UUID.randomUUID().toString(),
        "测".repeat(255),
        "SUBJECT_CREATED",
        RESOURCE,
        UUID.randomUUID().toString(),
        NOW - 2000);
    db.update(
        "UPDATE audit_events SET actor_id=? WHERE tenant_id=? AND resource_id=?",
        "测".repeat(255),
        tenant,
        RESOURCE);
    String tooLarge = create();
    work();
    assertThat(job(tooLarge).path("failureCode").asText()).isEqualTo("EXPORT_BYTE_LIMIT_EXCEEDED");
  }

  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @Autowired TestClock clock;
  @MockitoBean JwtDecoder decoder;
  static Path keyFile;
  String tenant, owner, root;
  static final long NOW = Instant.parse("2026-10-10T03:00:00Z").toEpochMilli();
  static final String RESOURCE = "11111111-1111-1111-1111-111111111111";

  @DynamicPropertySource
  static void keys(DynamicPropertyRegistry registry) throws Exception {
    keyFile = Files.createTempFile("audit-export-test-", ".jwk");
    var key =
        new OctetSequenceKeyGenerator(256)
            .keyID("test-export")
            .keyUse(KeyUse.ENCRYPTION)
            .algorithm(JWEAlgorithm.DIR)
            .generate();
    Files.writeString(keyFile, new JWKSet(key).toString(false));
    registry.add("manager.exports.key-file", () -> keyFile.toString());
  }

  @AfterAll
  static void removeKey() throws Exception {
    if (keyFile != null) Files.deleteIfExists(keyFile);
  }

  RequestPostProcessor actor(String who) {
    return jwt()
        .jwt(
            j ->
                j.subject(who)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  JsonNode body(ResultActions result) throws Exception {
    return json.readTree(result.andReturn().getResponse().getContentAsString());
  }

  @BeforeEach
  void setup() throws Exception {
    clock.value.set(NOW);
    owner = "export-owner-" + UUID.randomUUID();
    tenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .header("Idempotency-Key", UUID.randomUUID())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"Export\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated()))
            .path("id")
            .asText();
    root = "/api/v1/tenants/" + tenant + "/audit-exports";
    for (int n = 0; n < 2; n++)
      db.update(
          "INSERT INTO"
              + " audit_events(tenant_id,id,actor_id,action,resource_id,correlation_id,occurred_at)"
              + " VALUES(?,?,?,?,?,?,?)",
          tenant,
          UUID.randomUUID().toString(),
          owner,
          "SUBJECT_CREATED",
          RESOURCE,
          UUID.randomUUID().toString(),
          NOW - 1000 - n);
  }

  Map<String, Object> input() {
    return Map.of("from", NOW - 60000, "to", NOW, "resourceId", RESOURCE);
  }

  ResultActions create(String key, Map<String, Object> input) throws Exception {
    var request =
        post(root)
            .with(actor(owner))
            .contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsBytes(input));
    if (key != null) request.header("Idempotency-Key", key);
    return mvc.perform(request);
  }

  String create() throws Exception {
    return body(create(UUID.randomUUID().toString(), input()).andExpect(status().isAccepted()))
        .path("id")
        .asText();
  }

  @Test
  void creationIsQueuedAndListsOnlyOwnJobs() throws Exception {
    String id = create();
    var result =
        body(mvc.perform(get(root + "/" + id).with(actor(owner))).andExpect(status().isOk()));
    assertThat(result.path("state").asText()).isEqualTo("QUEUED");
    assertThat(result.path("expiresAt").asLong()).isEqualTo(NOW + 86400000);
    assertThat(
            body(mvc.perform(get(root).with(actor(owner))).andExpect(status().isOk()))
                .path("items")
                .size())
        .isEqualTo(1);
    mvc.perform(get(root + "/" + id).with(actor("outsider"))).andExpect(status().isForbidden());
  }

  @Test
  void idempotencyReturnsCurrentCancelledStateAndRejectsChangedBody() throws Exception {
    String key = UUID.randomUUID().toString();
    String id = body(create(key, input()).andExpect(status().isAccepted())).path("id").asText();
    mvc.perform(post(root + "/" + id + "/cancel").with(actor(owner))).andExpect(status().isOk());
    assertThat(body(create(key, input()).andExpect(status().isAccepted())).path("state").asText())
        .isEqualTo("CANCELLED");
    create(key, Map.of("from", NOW - 50000, "to", NOW)).andExpect(status().isConflict());
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_exports WHERE tenant_id=?", Integer.class, tenant))
        .isEqualTo(1);
  }

  @Test
  void recentMfaRequiredAndReadRolesDoNotGrantOtherCreatorsAccess() throws Exception {
    mvc.perform(
            post(root)
                .with(
                    jwt()
                        .jwt(
                            j ->
                                j.subject(owner)
                                    .claim("auth_time", clock.instant().getEpochSecond())
                                    .claim("amr", List.of("pwd"))))
                .header("Idempotency-Key", UUID.randomUUID())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(input())))
        .andExpect(status().isUnauthorized());
    for (String role : List.of("TEACHER", "CHILD")) {
      db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, tenant);
      create(UUID.randomUUID().toString(), input()).andExpect(status().isForbidden());
    }
  }

  @Test
  void requiredKeyAndInvalidRangesFailWithoutCreatingJobs() throws Exception {
    create(null, input()).andExpect(status().isBadRequest());
    create(UUID.randomUUID().toString(), Map.of("from", NOW, "to", NOW))
        .andExpect(status().isBadRequest());
    create(UUID.randomUUID().toString(), Map.of("from", 0, "to", NOW))
        .andExpect(status().isBadRequest());
    create(
            UUID.randomUUID().toString(),
            Map.of("from", NOW - 60000, "to", NOW, "action", "x' OR 1=1"))
        .andExpect(status().isBadRequest());
  }

  @Test
  void queuedOrCancelledJobsCannotBeDownloaded() throws Exception {
    String id = create();
    mvc.perform(get(root + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isConflict());
    mvc.perform(post(root + "/" + id + "/cancel").with(actor(owner))).andExpect(status().isOk());
    mvc.perform(get(root + "/" + id + "/content").with(actor(owner)))
        .andExpect(status().isConflict());
  }

  @Test
  void repeatedRequestsDoNotConsumeCreateRateBudget() throws Exception {
    String key = UUID.randomUUID().toString(),
        id = body(create(key, input()).andExpect(status().isAccepted())).path("id").asText();
    for (int n = 0; n < 4; n++)
      assertThat(body(create(key, input()).andExpect(status().isAccepted())).path("id").asText())
          .isEqualTo(id);
    create(UUID.randomUUID().toString(), input()).andExpect(status().isTooManyRequests());
  }

  @TestConfiguration
  static class TimeConfiguration {
    @Bean
    @Primary
    TestClock testClock() {
      return new TestClock();
    }
  }

  static class TestClock extends Clock {
    final AtomicLong value = new AtomicLong(NOW);

    public ZoneId getZone() {
      return ZoneOffset.UTC;
    }

    public Clock withZone(ZoneId zone) {
      return this;
    }

    public Instant instant() {
      return Instant.ofEpochMilli(value.get());
    }
  }
}
