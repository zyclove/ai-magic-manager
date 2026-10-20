package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.idempotency.IdempotencyResultLifecycle;
import com.aimanager.idempotency.IdempotencyRetentionSettings;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.SecretMaterial;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;

class ErasureIdempotencyProcessorTest {
  private static final String STEP = "IDEMPOTENCY_RESPONSES";
  private static final String ZERO_HASH = "0".repeat(64);
  ErasureObservationProcessorTest fixture;
  JdbcTemplate db;
  ErasureIdempotencyProcessor processor;
  String tenant, subject, peer;

  record Cache(String scope, String actor, String operation, String key) {}

  @BeforeEach
  void setup() {
    fixture = new ErasureObservationProcessorTest();
    fixture.setup();
    db = fixture.db;
    // RecoveryJobsTest.source validates explicitly isolated MySQL fixture schemas before setup.
    // Global classification checks require each method to start with its own response fixtures.
    db.update("DELETE FROM idempotency_subject_owners");
    db.update("DELETE FROM idempotency_requests");
    tenant = fixture.tenant;
    subject = fixture.subject;
    peer = fixture.peer;
    processor = new ErasureIdempotencyProcessor(fixture.data.jobs, db, fixture.catalog);
  }

  String id() {
    return fixture.id();
  }

  Cache cache(String scope, String state, String body, String... subjects) {
    String operation = "subjects.create";
    var cache =
        new Cache(scope, ActorKeys.key("private-actor"), SecretMaterial.hash(operation),
            SecretMaterial.hash(id()));
    Long committedAt = body == null ? null : 1L;
    db.update(
        "INSERT INTO idempotency_requests(id,scope_id,actor_id,actor_key,operation,operation_key,"
            + "key_hash,request_hash,response_body,expires_at,response_state,"
            + "result_committed_at,result_expires_at,result_policy_revision,result_last_observed_at)"
            + " VALUES(?,?,'private-actor',?,?,?,?,?,?,1,?,?,?,?,?)",
        id(),
        cache.scope(),
        cache.actor(),
        operation,
        cache.operation(),
        cache.key(),
        SecretMaterial.hash("private-request"),
        body,
        state,
        committedAt,
        committedAt == null ? null : IdempotencyResultLifecycle.expirationAt(committedAt),
        committedAt == null ? null : IdempotencyRetentionSettings.DEFAULT_POLICY_VERSION,
        committedAt);
    for (String person : subjects) owner(cache, scope, person);
    return cache;
  }

  void owner(Cache cache, String ownerTenant, String ownerSubject) {
    db.update(
        "INSERT INTO idempotency_subject_owners(id,scope_id,actor_key,operation_key,key_hash,"
            + "tenant_id,subject_key) VALUES(?,?,?,?,?,?,?)",
        id(), cache.scope(), cache.actor(), cache.operation(), cache.key(), ownerTenant,
        ResponseOwnership.subjectKey(ownerTenant, ownerSubject));
  }

  Object[] key(Cache cache) {
    return new Object[] {cache.scope(), cache.actor(), cache.operation(), cache.key()};
  }

  Map<String, Object> row(Cache cache) {
    return db.queryForMap(
        "SELECT * FROM idempotency_requests WHERE scope_id=? AND actor_key=?"
            + " AND operation_key=? AND key_hash=?", key(cache));
  }

  void erased(Cache cache) {
    var row = row(cache);
    assertEquals("ERASED", row.get("response_state"));
    assertNull(row.get("response_body"));
    assertEquals("", row.get("actor_id"));
    assertEquals("", row.get("operation"));
    assertEquals(ZERO_HASH, row.get("request_hash"));
    assertEquals(cache.actor(), row.get("actor_key"));
    assertEquals(cache.operation(), row.get("operation_key"));
    assertEquals(cache.key(), row.get("key_hash"));
  }

  ErasureIdempotencyProcessor.Result finish(ErasureRecoveryJobs.Claim claim, int limit) {
    for (int n = 0; n < 100; n++) {
      var result = processor.process(claim, limit);
      if (result.complete()) return result;
      assertFalse(result.classificationBlocked(), "Unexpected unclassified response");
    }
    fail("Bounded response processor did not finish");
    return null;
  }

  long steps() {
    return db.queryForObject(
        "SELECT COUNT(*) FROM erasure_recovery_steps WHERE step_code=?", Long.class, STEP);
  }

  long totalRows() {
    return db.queryForObject(
        "SELECT rows_processed FROM erasure_recovery_steps WHERE step_code=?", Long.class, STEP);
  }

  @Test
  void redactsTargetAndSharedResponseWhileKeepingOtherSubjectSourcesAndOpaqueTombstones() {
    var own = cache(tenant, "SCOPED", "private child response", subject);
    var shared = cache(tenant, "SCOPED", "private shared response", subject, peer);
    var retained = cache(tenant, "SCOPED", "private peer response", peer);
    var claim = fixture.accept();
    var result = finish(claim, 1);
    assertEquals(2, result.totalRows());
    erased(own);
    erased(shared);
    assertEquals("private peer response", row(retained).get("response_body"));
    assertEquals(3L, db.queryForObject("SELECT COUNT(*) FROM idempotency_requests", Long.class));
    assertEquals(4L,
        db.queryForObject("SELECT COUNT(*) FROM idempotency_subject_owners", Long.class));
    assertEquals(2L, fixture.count("subjects"));
    assertEquals("CLAIMED", fixture.data.jobs.find(claim.job().entry().request().requestId()).state());
    var replay = finish(claim, 1);
    assertTrue(replay.complete());
    assertEquals(0, replay.redactedRows());
    assertEquals(result.totalRows(), replay.totalRows());
    assertTrue(replay.batches() >= result.batches());
  }

  @Test
  void ignoresResponseTextAndRetainsOtherTenantWithSameRawSubjectId() {
    var misleading = cache(tenant, "SCOPED", subject + " private target name", peer);
    String otherTenant = id();
    var other = cache(otherTenant, "SCOPED", "other tenant private response", subject);
    var result = finish(fixture.accept(), 25);
    assertEquals(0, result.totalRows());
    assertEquals(subject + " private target name", row(misleading).get("response_body"));
    assertEquals("other tenant private response", row(other).get("response_body"));
  }

  @Test
  void explicitlyClassifiedNonSubjectResponseDoesNotBlockOrGetRedacted() {
    var nonSubject = cache("global-bootstrap", "NON_SUBJECT", "non subject response " + subject);
    var result = finish(fixture.accept(), 25);
    assertEquals(0, result.totalRows());
    assertEquals("NON_SUBJECT", row(nonSubject).get("response_state"));
    assertEquals("non subject response " + subject, row(nonSubject).get("response_body"));
  }

  @Test
  void boundedBatchAndReconstructedProcessorContinuePersistedProgress() {
    var rows = new ArrayList<Cache>();
    for (int n = 0; n < 3; n++) rows.add(cache(tenant, "SCOPED", "private response " + n, subject));
    var claim = fixture.accept();
    var first = processor.process(claim, 1);
    assertEquals(1, first.redactedRows());
    assertEquals(1, first.totalRows());
    assertFalse(first.complete());
    assertEquals(1, totalRows());
    processor = new ErasureIdempotencyProcessor(fixture.data.jobs, db, fixture.catalog);
    var last = finish(claim, 1);
    assertEquals(3, last.totalRows());
    for (var row : rows) erased(row);
  }

  @Test
  void globalVerificationIsBoundedAndLateUnknownBeforeRecoveredCursorStillBlocksCompletion() {
    for (int n = 0; n < 40; n++)
      cache("global-bootstrap", "NON_SUBJECT", "non subject response " + n);
    var claim = fixture.accept();
    var data = processor.process(claim, 25);
    assertEquals("VERIFY", data.phase());
    assertFalse(data.complete());
    var firstPage = processor.process(claim, 25);
    assertFalse(firstPage.complete(), "Forty response rows must require more than one verification page");
    String cursor = db.queryForObject(
        "SELECT cursor_id FROM erasure_recovery_steps WHERE step_code=?", String.class, STEP);
    assertNotNull(cursor);
    assertDoesNotThrow(() -> UUID.fromString(cursor));
    var unknown = cache("global-bootstrap", "UNCLASSIFIED", "late unclassified response");
    db.update("UPDATE idempotency_requests SET id='00000000-0000-0000-0000-000000000001'"
        + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?", key(unknown));
    processor = new ErasureIdempotencyProcessor(fixture.data.jobs, db, fixture.catalog);
    var recovered = processor.process(claim, 25);
    assertFalse(recovered.complete());
    assertTrue(recovered.classificationBlocked());
    assertEquals("VERIFY", recovered.phase());
    assertEquals(0, recovered.totalRows());
    db.update("UPDATE idempotency_requests SET response_state='NON_SUBJECT'"
        + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?", key(unknown));
    assertTrue(finish(claim, 25).complete());
  }

  @Test
  void restoredOrphanOwnerBlocksCompletedAndFreshJobsInsteadOfDisappearingFromParentScan() {
    var completed = fixture.accept();
    finish(completed, 25);
    var orphan = cache(tenant, "SCOPED", "private peer response", peer);
    db.execute((ConnectionCallback<Void>) connection -> {
      String product = connection.getMetaData().getDatabaseProductName();
      String disable;
      String enable;
      if (product.equals("MySQL")) {
        disable = "SET FOREIGN_KEY_CHECKS=0";
        enable = "SET FOREIGN_KEY_CHECKS=1";
      } else if (product.equals("H2")) {
        disable = "SET REFERENTIAL_INTEGRITY FALSE";
        enable = "SET REFERENTIAL_INTEGRITY TRUE";
      } else throw new IllegalStateException("Unsupported isolated fixture database");
      try (var statement = connection.createStatement()) {
        statement.execute(disable);
        try (var delete = connection.prepareStatement(
            "DELETE FROM idempotency_requests WHERE scope_id=? AND actor_key=?"
                + " AND operation_key=? AND key_hash=?")) {
          var arguments = key(orphan);
          for (int n = 0; n < arguments.length; n++) delete.setObject(n + 1, arguments[n]);
          assertEquals(1, delete.executeUpdate());
        } finally {
          statement.execute(enable);
        }
      }
      return null;
    });
    try {
      assertEquals(1L, db.queryForObject("SELECT COUNT(*) FROM idempotency_subject_owners"
          + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?",
          Long.class, key(orphan)));
      fixture.data.failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT",
          () -> finish(completed, 25));
      fixture.data.jobs.retry(completed,
          ErasureRecoveryJobs.RetryReason.HANDLER_UNAVAILABLE, 86400);
      var fresh = fixture.accept();
      fixture.data.failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT", () -> finish(fresh, 25));
    } finally {
      db.update("DELETE FROM idempotency_subject_owners WHERE scope_id=? AND actor_key=?"
          + " AND operation_key=? AND key_hash=?", key(orphan));
    }
  }

  @Test
  void ownerIntegrityVerificationIsBoundedAndResumesItsIndependentUuidCursor() {
    var ownerSubjects = new ArrayList<String>();
    ownerSubjects.add(peer);
    for (int n = 1; n < 40; n++) ownerSubjects.add(id());
    var retained = cache(tenant, "SCOPED", "private peer response",
        ownerSubjects.toArray(String[]::new));
    var claim = fixture.accept();
    assertEquals("VERIFY", processor.process(claim, 25).phase());
    var parentPage = processor.process(claim, 25);
    assertFalse(parentPage.complete());
    assertEquals("RECHECK", parentPage.phase());
    var firstOwnerPage = processor.process(claim, 25);
    assertFalse(firstOwnerPage.complete(), "Forty owners require multiple bounded owner pages");
    assertEquals("RECHECK", firstOwnerPage.phase());
    String cursor = db.queryForObject(
        "SELECT cursor_id FROM erasure_recovery_steps WHERE step_code=?", String.class, STEP);
    assertNotNull(cursor);
    assertDoesNotThrow(() -> UUID.fromString(cursor));
    processor = new ErasureIdempotencyProcessor(fixture.data.jobs, db, fixture.catalog);
    var result = finish(claim, 25);
    assertTrue(result.complete());
    assertEquals(0, result.totalRows());
    assertEquals("private peer response", row(retained).get("response_body"));
    assertEquals(40L, db.queryForObject("SELECT COUNT(*) FROM idempotency_subject_owners"
        + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?",
        Long.class, key(retained)));
  }

  @Test
  void unclassifiedGlobalResponseBlocksVerificationAfterCommittedTargetRedaction() {
    var target = cache(tenant, "SCOPED", "private child response", subject);
    var unknown = cache("global-bootstrap", "UNCLASSIFIED", "private unclassified response");
    var claim = fixture.accept();
    var first = processor.process(claim, 25);
    assertEquals(1, first.redactedRows());
    assertFalse(first.complete());
    assertEquals("VERIFY", first.phase());
    erased(target);
    var verification = processor.process(claim, 25);
    assertEquals("VERIFY", verification.phase());
    assertTrue(verification.classificationBlocked());
    assertFalse(verification.complete());
    assertEquals(1, verification.totalRows());
    assertEquals("private unclassified response", row(unknown).get("response_body"));
    assertEquals(1, totalRows());
  }

  @Test
  void unknownAfterDoneCannotBeHiddenByCompletedCheckpoint() {
    var claim = fixture.accept();
    finish(claim, 25);
    cache("global-bootstrap", "UNCLASSIFIED", "unclassified response");
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
  }

  @Test
  void newAttributedResponseAfterDoneRequiresRecheckAndPreservesNewSource() {
    var claim = fixture.accept();
    finish(claim, 25);
    var reappeared = cache(tenant, "SCOPED", "new child response", subject);
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    assertEquals("new child response", row(reappeared).get("response_body"));
    assertEquals(0, totalRows());
  }

  @Test
  void erasedLabelCannotConcealReappearingPayloadOrPersonalMetadata() {
    var target = cache(tenant, "SCOPED", "private child response", subject);
    var claim = fixture.accept();
    finish(claim, 25);
    for (String column : List.of("response_body", "actor_id", "operation", "request_hash")) {
      db.update(
          "UPDATE idempotency_requests SET " + column + "=? WHERE scope_id=? AND actor_key=?"
              + " AND operation_key=? AND key_hash=?",
          column.equals("request_hash") ? "b".repeat(64) : "private-restored-value",
          target.scope(), target.actor(), target.operation(), target.key());
      fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
      db.update(
          "UPDATE idempotency_requests SET response_body=NULL,actor_id='',operation='',"
              + "request_hash=? WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?",
          ZERO_HASH, target.scope(), target.actor(), target.operation(), target.key());
    }
  }

  @Test
  void scopedCacheWithoutOwnerIsCorruptInsteadOfSilentlyCompleted() {
    cache(tenant, "SCOPED", "unattributed private response");
    var claim = fixture.accept();
    processor.process(claim, 25);
    fixture.data.failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT", () -> processor.process(claim, 25));
  }

  @Test
  void committedScopedResponseCannotBeMissingItsBody() {
    var target = cache(tenant, "SCOPED", null, subject);
    var claim = fixture.accept();
    fixture.data.failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals("SCOPED", row(target).get("response_state"));
    assertEquals(0, steps());
  }

  @Test
  void foreignTenantOwnerCannotAuthorizeRedactingThisScope() {
    var corrupt = cache(tenant, "SCOPED", "private response");
    owner(corrupt, id(), subject);
    var claim = fixture.accept();
    processor.process(claim, 25);
    fixture.data.failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals("private response", row(corrupt).get("response_body"));
  }

  @Test
  void scopedGlobalRecordIsNotAValidSubjectAttribution() {
    var corrupt = cache("global-bootstrap", "SCOPED", "private response");
    // The public ownership helper rejects invalid tenants. Model a damaged stored row directly,
    // using a valid digest rather than weakening that helper to construct the fixture.
    db.update("INSERT INTO idempotency_subject_owners(id,scope_id,actor_key,operation_key,key_hash,"
        + "tenant_id,subject_key) VALUES(?,?,?,?,?,?,?)",
        id(), corrupt.scope(), corrupt.actor(), corrupt.operation(), corrupt.key(),
        "global-bootstrap", ResponseOwnership.subjectKey(tenant, subject));
    var claim = fixture.accept();
    processor.process(claim, 25);
    fixture.data.failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals("private response", row(corrupt).get("response_body"));
  }

  @Test
  void malformedSubjectDigestCannotHideAttributedPrivateCopy() {
    var corrupt = cache(tenant, "SCOPED", "private response", peer);
    db.update(
        "UPDATE idempotency_subject_owners SET subject_key='not-a-sha256'"
            + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?", key(corrupt));
    var claim = fixture.accept();
    processor.process(claim, 25);
    fixture.data.failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals("private response", row(corrupt).get("response_body"));
  }

  @Test
  void originalActorAndOperationMustMatchTheirOpaqueDigestsBeforeRedaction() {
    for (String column : List.of("actor_id", "operation")) {
      var corrupt = cache(tenant, "SCOPED", "private response", subject);
      db.update(
          "UPDATE idempotency_requests SET " + column + "='tampered'"
              + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?", key(corrupt));
      var claim = fixture.accept();
      fixture.data.failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT", () -> processor.process(claim, 25));
      assertEquals("private response", row(corrupt).get("response_body"));
      db.update("DELETE FROM idempotency_subject_owners WHERE scope_id=? AND actor_key=?"
          + " AND operation_key=? AND key_hash=?", key(corrupt));
      db.update("DELETE FROM idempotency_requests WHERE scope_id=? AND actor_key=?"
          + " AND operation_key=? AND key_hash=?", key(corrupt));
      fixture.data.jobs.retry(claim, ErasureRecoveryJobs.RetryReason.HANDLER_UNAVAILABLE, 86400);
    }
  }

  @Test
  void realRedactionThenStorageFailureRollsBackPayloadAndNewCheckpoint() {
    var target = cache(tenant, "SCOPED", "private child response", subject);
    var claim = fixture.accept();
    var faulty = new JdbcTemplate(fixture.data.business) {
      @Override
      public int update(String sql, Object... arguments) {
        int written = super.update(sql, arguments);
        if (sql.startsWith("UPDATE idempotency_requests SET"))
          throw new IllegalStateException("Injected after actual response redaction");
        return written;
      }
    };
    var failing = new ErasureIdempotencyProcessor(fixture.data.jobs, faulty, fixture.catalog);
    assertThrows(IllegalStateException.class, () -> failing.process(claim, 25));
    assertEquals("private child response", row(target).get("response_body"));
    assertEquals("SCOPED", row(target).get("response_state"));
    assertEquals(0, steps());
    assertEquals(1, finish(claim, 25).totalRows());
  }

  @Test
  void leaseLossAfterRedactionRollsBackPayloadAndPersistedCheckpoint() {
    var first = cache(tenant, "SCOPED", "private response one", subject);
    var second = cache(tenant, "SCOPED", "private response two", subject);
    var claim = fixture.accept();
    assertEquals(1, processor.process(claim, 1).totalRows());
    var expiring = new JdbcTemplate(fixture.data.business) {
      @Override
      public int update(String sql, Object... arguments) {
        int written = super.update(sql, arguments);
        if (sql.startsWith("UPDATE idempotency_requests SET"))
          super.update("UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
              claim.job().entry().request().requestId());
        return written;
      }
    };
    var failing = new ErasureIdempotencyProcessor(fixture.data.jobs, expiring, fixture.catalog);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> failing.process(claim, 25));
    assertEquals(1, totalRows());
    assertEquals(1L, db.queryForObject("SELECT COUNT(*) FROM idempotency_requests"
        + " WHERE response_state='SCOPED'", Long.class));
    assertEquals(2, finish(claim, 25).totalRows());
    erased(first);
    erased(second);
  }

  @Test
  void lostFenceCannotRedactOrCreateCheckpoint() {
    var target = cache(tenant, "SCOPED", "private response", subject);
    var old = fixture.accept();
    db.update("UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
        old.job().entry().request().requestId());
    var replacement = fixture.data.jobs.claim(id(), 300);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> processor.process(old, 25));
    assertEquals("private response", row(target).get("response_body"));
    assertEquals(0, steps());
    assertEquals(1, finish(replacement, 25).totalRows());
  }

  @Test
  void checkpointWriteFailureAfterActualRedactionRollsBackAllChanges() {
    var target = cache(tenant, "SCOPED", "private response", subject);
    var claim = fixture.accept();
    var faulty = new JdbcTemplate(fixture.data.business) {
      @Override
      public int update(String sql, Object... arguments) {
        int written = super.update(sql, arguments);
        if (sql.startsWith("UPDATE erasure_recovery_steps SET"))
          throw new IllegalStateException("Injected after checkpoint update");
        return written;
      }
    };
    var failing = new ErasureIdempotencyProcessor(fixture.data.jobs, faulty, fixture.catalog);
    assertThrows(IllegalStateException.class, () -> failing.process(claim, 25));
    assertEquals("private response", row(target).get("response_body"));
    assertEquals("SCOPED", row(target).get("response_state"));
    assertEquals(0, steps());
  }

  @Test
  void concurrentCallsUsingSameClaimNeverCountOneResponseTwice() throws Exception {
    for (int n = 0; n < 3; n++) cache(tenant, "SCOPED", "private response " + n, subject);
    var claim = fixture.accept();
    var pool = Executors.newFixedThreadPool(2);
    try {
      var one = pool.submit(() -> processor.process(claim, 1));
      var two = pool.submit(() -> processor.process(claim, 1));
      assertEquals(2, one.get(20, TimeUnit.SECONDS).redactedRows()
          + two.get(20, TimeUnit.SECONDS).redactedRows());
    } finally {
      pool.shutdownNow();
      assertTrue(pool.awaitTermination(20, TimeUnit.SECONDS));
    }
    assertEquals(3, finish(claim, 1).totalRows());
  }

  @Test
  void unsupportedOrInvalidCheckpointCannotSkipPrivateResponses() {
    var target = cache(tenant, "SCOPED", "private response", subject);
    var claim = fixture.accept();
    db.update("INSERT INTO erasure_recovery_steps(request_id,step_code,handler_version,phase,"
        + "rows_processed,batches_processed,updated_at) VALUES(?,?,2,'DATA',0,0,0)",
        claim.job().entry().request().requestId(), STEP);
    fixture.data.failure("ERASURE_STEP_VERSION_UNSUPPORTED", () -> processor.process(claim, 25));
    db.update("UPDATE erasure_recovery_steps SET handler_version=1,phase='REPORTS'");
    fixture.data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    assertEquals("private response", row(target).get("response_body"));
    assertEquals(0, totalRows());
  }

  @Test
  void invalidBatchSizesNeverCreateCheckpoint() {
    var claim = fixture.accept();
    for (int limit : new int[] {-1, 0, 26, Integer.MAX_VALUE})
      assertThrows(IllegalArgumentException.class, () -> processor.process(claim, limit));
    assertEquals(0, steps());
  }
}
