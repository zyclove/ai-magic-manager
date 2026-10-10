package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    properties = {
      "spring.datasource.url=${ERASURE_TEST_DATABASE_URL:jdbc:h2:mem:erasure_preview;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${ERASURE_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${ERASURE_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false",
      "manager.report-jobs.worker.enabled=false",
      "manager.diagnostic-packages.worker.enabled=false",
      "manager.erasure-previews.cleanup.enabled=false"
    })
@AutoConfigureMockMvc
class ErasurePreviewJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper json;
  @Autowired PreviewClock clock;
  @Autowired ErasurePreviewService previews;
  String tenant, subject, owner, path;

  @TestConfiguration
  static class Configuration {
    @Bean
    @Primary
    PreviewClock previewClock() {
      return new PreviewClock();
    }
  }

  static class PreviewClock extends Clock {
    volatile Instant now = Instant.now();

    public ZoneId getZone() {
      return ZoneOffset.UTC;
    }

    public Clock withZone(ZoneId zone) {
      return this;
    }

    public Instant instant() {
      return now;
    }
  }

  RequestPostProcessor actor(String id, boolean mfa) {
    return jwt()
        .jwt(
            j ->
                j.subject(id)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", mfa ? List.of("pwd", "otp") : List.of("pwd")));
  }

  @BeforeEach
  void fixture() {
    clock.now = Instant.now();
    tenant = UUID.randomUUID().toString();
    subject = UUID.randomUUID().toString();
    owner = "preview-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at,version) VALUES(?,'private"
            + " tenant','FAMILY','UTC',?,0)",
        tenant,
        clock.millis());
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,version)"
            + " VALUES(?,?,?,'OWNER',0)",
        tenant,
        owner,
        ActorKeys.key(owner));
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at,version)"
            + " VALUES(?,?,'private child','AGE_7_12',?,0)",
        tenant,
        subject,
        clock.millis());
    path = "/api/v1/tenants/" + tenant + "/subjects/" + subject + "/erasure-previews";
  }

  JsonNode create(String key) throws Exception {
    var body =
        mvc.perform(
                post(path)
                    .with(actor(owner, true))
                    .header("If-Match", "\"0\"")
                    .header("Idempotency-Key", key))
            .andExpect(status().isCreated())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(header().string("ETag", "\"0\""))
            .andReturn()
            .getResponse()
            .getContentAsString();
    return json.readTree(body);
  }

  @Test
  void preparationIsDurableNonExecutableAndRetryReturnsSameCurrentResource() throws Exception {
    String key = UUID.randomUUID().toString();
    var created = create(key);
    assertEquals("PREPARED", created.path("state").asText());
    assertFalse(created.path("executionAvailable").asBoolean(true));
    assertEquals(subject, created.path("subjectId").asText());
    assertEquals(clock.millis() + 300_000, created.path("expiresAt").asLong());
    assertEquals(created, create(key));
    String id = created.path("id").asText();
    mvc.perform(get(path + "/" + id).with(actor(owner, true)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("snapshot.readyToErase").value(false));
    assertEquals(
        1,
        db.queryForObject(
            "SELECT COUNT(*) FROM subject_erasure_previews WHERE tenant_id=?",
            Integer.class,
            tenant));
    String stored =
        db.queryForObject(
            "SELECT snapshot_json FROM subject_erasure_previews WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            id);
    assertFalse(stored.contains("private child"));
    assertFalse(stored.contains(owner));
    assertEquals(
        1,
        db.queryForObject(
            "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                + " action='SUBJECT_ERASURE_PREVIEW_CREATED'",
            Integer.class,
            tenant));
  }

  @Test
  void cancellationIsConditionalAndRetriesDoNotResurrectSnapshot() throws Exception {
    String key = UUID.randomUUID().toString();
    String id = create(key).path("id").asText();
    for (int n = 0; n < 2; n++) {
      mvc.perform(
              post(path + "/" + id + "/cancel")
                  .with(actor(owner, true))
                  .header("If-Match", "\"0\""))
          .andExpect(status().isOk())
          .andExpect(header().string("ETag", "\"1\""))
          .andExpect(jsonPath("state").value("CANCELLED"))
          .andExpect(jsonPath("snapshot").doesNotExist());
    }
    mvc.perform(
            post(path)
                .with(actor(owner, true))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", key))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("id").value(id))
        .andExpect(jsonPath("state").value("CANCELLED"))
        .andExpect(jsonPath("snapshot").doesNotExist());
    assertNull(
        db.queryForObject(
            "SELECT snapshot_json FROM subject_erasure_previews WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            id));
    assertEquals(
        "private child",
        db.queryForObject(
            "SELECT nickname FROM subjects WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            subject));
  }

  @Test
  void expiredAndSupersededPreviewsCannotExposeTheirOldSnapshots() throws Exception {
    String first = create(UUID.randomUUID().toString()).path("id").asText();
    String second = create(UUID.randomUUID().toString()).path("id").asText();
    mvc.perform(get(path + "/" + first).with(actor(owner, true)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("state").value("SUPERSEDED"))
        .andExpect(jsonPath("snapshot").doesNotExist());
    clock.now = clock.now.plusSeconds(300);
    mvc.perform(get(path + "/" + second).with(actor(owner, true)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("state").value("EXPIRED"))
        .andExpect(jsonPath("snapshot").doesNotExist());
    assertEquals(
        0,
        db.queryForObject(
            "SELECT COUNT(*) FROM subject_erasure_previews WHERE tenant_id=? AND snapshot_json IS"
                + " NOT NULL",
            Integer.class,
            tenant));
  }

  @Test
  void scopeMfaAndCurrentAuthorityAreCheckedBeforeAnyStoredResponse() throws Exception {
    String key = UUID.randomUUID().toString(), id = create(key).path("id").asText();
    mvc.perform(get(path + "/" + id).with(actor("outsider", true)))
        .andExpect(status().isForbidden());
    mvc.perform(get(path + "/" + id).with(actor(owner, false)))
        .andExpect(status().isUnauthorized());
    db.update("UPDATE tenant_members SET version=version+1 WHERE tenant_id=?", tenant);
    mvc.perform(get(path + "/" + id).with(actor(owner, true))).andExpect(status().isForbidden());
    mvc.perform(
            post(path)
                .with(actor(owner, true))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", key))
        .andExpect(status().isForbidden());
  }

  @Test
  void strongSubjectVersionAndRequestKeyAreRequiredBeforeCreatingAnything() throws Exception {
    mvc.perform(post(path).with(actor(owner, true)).header("Idempotency-Key", "request"))
        .andExpect(status().isPreconditionRequired());
    mvc.perform(post(path).with(actor(owner, true)).header("If-Match", "\"0\""))
        .andExpect(status().isBadRequest());
    for (String value : List.of("*", "W/\"0\"", "\"0\",\"1\""))
      mvc.perform(
              post(path)
                  .with(actor(owner, true))
                  .header("If-Match", value)
                  .header("Idempotency-Key", "request"))
          .andExpect(status().isBadRequest());
    mvc.perform(
            post(path)
                .with(actor(owner, true))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", "request"))
        .andExpect(status().isPreconditionFailed());
    assertEquals(
        0,
        db.queryForObject(
            "SELECT COUNT(*) FROM subject_erasure_previews WHERE tenant_id=?",
            Integer.class,
            tenant));
  }

  @Test
  void subjectChangesInvalidateSnapshotAndKeyCannotBeReboundToNewVersion() throws Exception {
    String key = UUID.randomUUID().toString(), id = create(key).path("id").asText();
    db.update("UPDATE subjects SET version=version+1 WHERE tenant_id=? AND id=?", tenant, subject);
    mvc.perform(get(path + "/" + id).with(actor(owner, true)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("state").value("STALE"))
        .andExpect(jsonPath("snapshot").doesNotExist());
    mvc.perform(
            post(path)
                .with(actor(owner, true))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", key))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
    mvc.perform(
            post(path)
                .with(actor(owner, true))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", UUID.randomUUID().toString()))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("subjectVersion").value(1));
  }

  @Test
  void anotherAdministratorCannotReadOrCancelSomeoneElsesPreparation() throws Exception {
    String id = create(UUID.randomUUID().toString()).path("id").asText();
    String other = "other-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,version)"
            + " VALUES(?,?,?,'OWNER',0)",
        tenant,
        other,
        ActorKeys.key(other));
    mvc.perform(get(path + "/" + id).with(actor(other, true))).andExpect(status().isForbidden());
    mvc.perform(
            post(path + "/" + id + "/cancel").with(actor(other, true)).header("If-Match", "\"0\""))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(path)
                .with(actor(other, true))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "request"))
        .andExpect(status().isCreated());
    assertEquals(
        2,
        db.queryForObject(
            "SELECT COUNT(*) FROM subject_erasure_previews WHERE tenant_id=? AND state='PREPARED'",
            Integer.class,
            tenant));
    mvc.perform(
            get(path.replace(subject, UUID.randomUUID().toString()) + "/" + id)
                .with(actor(owner, true)))
        .andExpect(status().isForbidden());
  }

  @Test
  void unreviewedSchemaClosesSnapshotAccessButDoesNotPreventCancellation() throws Exception {
    String id = create(UUID.randomUUID().toString()).path("id").asText();
    db.execute("CREATE TABLE erasure_preview_unreviewed(id VARCHAR(36))");
    try {
      mvc.perform(get(path + "/" + id).with(actor(owner, true)))
          .andExpect(status().isServiceUnavailable())
          .andExpect(jsonPath("errorCode").value("ERASURE_SCHEMA_REVIEW_REQUIRED"));
      mvc.perform(
              post(path + "/" + id + "/cancel")
                  .with(actor(owner, true))
                  .header("If-Match", "\"0\""))
          .andExpect(status().isOk())
          .andExpect(jsonPath("state").value("CANCELLED"));
    } finally {
      db.execute("DROP TABLE erasure_preview_unreviewed");
    }
  }

  @Test
  void corruptStoredSnapshotIsNotReturnedAsUsablePreparation() throws Exception {
    String id = create(UUID.randomUUID().toString()).path("id").asText();
    db.update(
        "UPDATE subject_erasure_previews SET snapshot_json='{}' WHERE tenant_id=? AND id=?",
        tenant,
        id);
    mvc.perform(get(path + "/" + id).with(actor(owner, true)))
        .andExpect(status().isServiceUnavailable())
        .andExpect(jsonPath("errorCode").value("ERASURE_PREVIEW_UNAVAILABLE"));
    mvc.perform(
            post(path + "/" + id + "/cancel").with(actor(owner, true)).header("If-Match", "\"99\""))
        .andExpect(status().isPreconditionFailed());
    mvc.perform(
            post(path + "/" + id + "/cancel").with(actor(owner, true)).header("If-Match", "\"0\""))
        .andExpect(status().isOk());
  }

  @Test
  void repeatedPreparationsAreBoundedAndRejectionKeepsExistingIntent() throws Exception {
    String id = null;
    for (int i = 0; i < 20; i++) id = create(UUID.randomUUID().toString()).path("id").asText();
    mvc.perform(
            post(path)
                .with(actor(owner, true))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", UUID.randomUUID().toString()))
        .andExpect(status().isTooManyRequests())
        .andExpect(jsonPath("errorCode").value("ERASURE_PREVIEW_RATE_LIMITED"));
    mvc.perform(get(path + "/" + id).with(actor(owner, true)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("state").value("PREPARED"));
    assertEquals(
        20,
        db.queryForObject(
            "SELECT COUNT(*) FROM subject_erasure_previews WHERE tenant_id=?",
            Integer.class,
            tenant));
  }

  @Test
  void simultaneousRetriesProduceOnePersistentPreviewAndOneCreationAudit() throws Exception {
    String key = UUID.randomUUID().toString();
    var pool = java.util.concurrent.Executors.newFixedThreadPool(4);
    var gate = new java.util.concurrent.CountDownLatch(1);
    try {
      var futures = new ArrayList<java.util.concurrent.Future<String>>();
      for (int i = 0; i < 4; i++)
        futures.add(
            pool.submit(
                () -> {
                  gate.await();
                  return create(key).path("id").asText();
                }));
      gate.countDown();
      var ids = new HashSet<String>();
      for (var future : futures) ids.add(future.get(30, java.util.concurrent.TimeUnit.SECONDS));
      assertEquals(1, ids.size());
      assertEquals(
          1,
          db.queryForObject(
              "SELECT COUNT(*) FROM subject_erasure_previews WHERE tenant_id=?",
              Integer.class,
              tenant));
      assertEquals(
          1,
          db.queryForObject(
              "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                  + " action='SUBJECT_ERASURE_PREVIEW_CREATED'",
              Integer.class,
              tenant));
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void housekeepingExpiresSnapshotsAndPrunesOldTombstonesInBoundedBatches() throws Exception {
    for (int i = 0; i < 3; i++) create(UUID.randomUUID().toString());
    db.update(
        "UPDATE subject_erasure_previews SET created_at=?,expires_at=? WHERE tenant_id=?",
        clock.millis() - 86_400_001,
        clock.millis() - 1,
        tenant);
    assertEquals(2, previews.purge(1));
    assertEquals(
        2,
        db.queryForObject(
            "SELECT COUNT(*) FROM subject_erasure_previews WHERE tenant_id=?",
            Integer.class,
            tenant));
    assertEquals(
        0,
        db.queryForObject(
            "SELECT COUNT(*) FROM subject_erasure_previews WHERE tenant_id=? AND snapshot_json IS"
                + " NOT NULL",
            Integer.class,
            tenant));
    assertEquals(2, previews.purge(100));
    assertEquals(0, previews.purge(100));
    assertThrows(IllegalArgumentException.class, () -> previews.purge(101));
    assertEquals(
        1,
        db.queryForObject(
            "SELECT COUNT(*) FROM subjects WHERE tenant_id=? AND id=?",
            Integer.class,
            tenant,
            subject));
  }
}
