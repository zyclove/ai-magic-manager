package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.idempotency.IdempotencyResultTime;
import com.aimanager.idempotency.IdempotencyRetentionSettings;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.retention.ErasureLedger;
import com.aimanager.shared.DomainException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/** 真实事务和独立删除账本的边界验收；不表示普通 HTTP 在恢复暂停期间返回 410。 */
class ErasureIdempotencyCardinalityTest {
  private static final String ACTOR = "cardinality-fixture-actor";
  private static final String OPERATION = "reports.cardinality-fixture";
  private static final String SHARED_KEY = "shared-two-hundred-subjects";
  private static final String RETAINED_KEY = "retained-two-hundred-subjects";
  private static final String STEP = "IDEMPOTENCY_RESPONSES";
  private static final Map<String, ?> ATTRIBUTES = Map.of("selection", "frozen-subject-selection");
  private static final Clock CLOCK =
      Clock.fixed(Instant.parse("2026-10-15T00:00:00Z"), ZoneOffset.UTC);

  private ErasureObservationProcessorTest fixture;
  private JdbcTemplate db;
  private TransactionTemplate tx;
  private IdempotencyService journal;
  private ErasureIdempotencyProcessor processor;
  private String tenant;

  record SharedResponse(List<String> subjectIds, String description) {}

  @BeforeEach
  void setup() {
    // 原夹具验证 MySQL 专属测试 schema；默认业务库和账本是两个独立 H2 实例。
    fixture = new ErasureObservationProcessorTest();
    fixture.setup();
    db = fixture.db;
    db.update("DELETE FROM idempotency_subject_owners");
    db.update("DELETE FROM idempotency_requests");
    tenant = fixture.tenant;
    tx = new TransactionTemplate(new DataSourceTransactionManager(fixture.data.business));
    tx.setTimeout(10);
    var retention = IdempotencyRetentionSettings.defaults();
    var trustedTime = new IdempotencyResultTime(db, CLOCK, retention) {
      @Override
      public long now() {
        if (!TransactionSynchronizationManager.isActualTransactionActive()) {
          throw new IllegalStateException("Fixture result time requires an active transaction");
        }
        return CLOCK.millis();
      }
      // Inherit now(lifecycle): awaiting and durable last-observation checks remain real.
    };
    journal = new IdempotencyService(db, fixture.json, CLOCK, retention, trustedTime);
    processor = new ErasureIdempotencyProcessor(fixture.data.jobs, db, fixture.catalog);
  }

  @Test
  void twoHundredDistinctOwnersCommitAndRemainReadableThroughBothJournalMethods() {
    var owners = twoHundredSubjects();
    var original = create(SHARED_KEY, owners);

    assertEquals(200, original.subjectIds().size());
    assertEquals(owners, original.subjectIds());
    assertOwners(SHARED_KEY, owners);
    assertEquals("SCOPED", row(SHARED_KEY).get("response_state"));
    assertEquals(digest("{\"selection\":\"frozen-subject-selection\"}"),
        row(SHARED_KEY).get("request_hash"));
    assertEquals(digest(ACTOR), row(SHARED_KEY).get("actor_key"));
    assertEquals(digest(OPERATION), row(SHARED_KEY).get("operation_key"));

    var replay = tx.execute(status -> journal.execute(
        tenant, ACTOR, OPERATION, SHARED_KEY, ATTRIBUTES, SharedResponse.class,
        () -> { throw new AssertionError("Committed mutation must not repeat"); },
        response -> { throw new AssertionError("Committed owners must not be recomputed"); }));
    assertEquals(original, replay);
    var found = tx.execute(status -> journal.findCommitted(
        tenant, ACTOR, OPERATION, SHARED_KEY, ATTRIBUTES, SharedResponse.class));
    assertNotNull(found);
    assertEquals(original, found.toHttpResult());
    assertOwners(SHARED_KEY, owners);
    assertEquals(1L, count("idempotency_requests"));
  }

  @Test
  void twoSubjectJobsInterleaveAndRedactTheSharedResponseOnceWithoutLosingOtherOwners() {
    var sharedOwners = twoHundredSubjects();
    var retainedOwners = otherTwoHundredSubjects(sharedOwners);
    create(SHARED_KEY, sharedOwners);
    var retainedResponse = create(RETAINED_KEY, retainedOwners);
    var retainedBefore = row(RETAINED_KEY);
    var claims = acceptTwoSubjects(sharedOwners.get(0), sharedOwners.get(1));

    var first = processor.process(claims.get(0), 25);
    var second = processor.process(claims.get(1), 25);
    assertEquals(1, first.redactedRows());
    assertEquals(0, second.redactedRows());
    assertEquals(1, first.totalRows() + second.totalRows());
    assertEquals(1, finish(processor, claims.get(0)).totalRows());
    assertEquals(0, finish(processor, claims.get(1)).totalRows());
    assertEquals(0, processor.process(claims.get(0), 25).redactedRows());
    assertEquals(0, processor.process(claims.get(1), 25).redactedRows());

    assertErased(SHARED_KEY);
    assertOwners(SHARED_KEY, sharedOwners);
    assertOwners(RETAINED_KEY, retainedOwners);
    assertEquals(retainedBefore, row(RETAINED_KEY));
    assertEquals(400L, count("idempotency_subject_owners"));
    assertEquals(202L, fixture.count("subjects"));
    assertEquals(1L, processedRows());
    assertEquals(retainedResponse, tx.execute(status -> journal.findCommitted(
        tenant, ACTOR, OPERATION, RETAINED_KEY, ATTRIBUTES, SharedResponse.class)).toHttpResult());
    assertPermanentGone(SHARED_KEY);
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, fixture.data.ledger.workState());
  }

  @Test
  void concurrentSubjectJobsAndReclaimedLeasesNeverDoubleCountTheSharedResponse() throws Exception {
    var sharedOwners = twoHundredSubjects();
    var retainedOwners = otherTwoHundredSubjects(sharedOwners);
    create(SHARED_KEY, sharedOwners);
    create(RETAINED_KEY, retainedOwners);
    var retainedBefore = row(RETAINED_KEY);
    var claims = acceptTwoSubjects(sharedOwners.get(0), sharedOwners.get(1));
    String sharedResponseId = (String) row(SHARED_KEY).get("id");
    assertEquals("SCOPED", row(SHARED_KEY).get("response_state"));
    var bothDiscovered = new CountDownLatch(2);
    var continueToParentLock = new CountDownLatch(1);
    var discoveredIds = new ConcurrentLinkedQueue<String>();
    var observingDb = new JdbcTemplate(fixture.data.business) {
      @Override
      public <T> List<T> query(String sql, RowMapper<T> mapper, Object... arguments) {
        if (!sql.startsWith("SELECT r.id,r.scope_id,r.actor_key,r.operation_key,r.key_hash"
            + " FROM idempotency_requests r JOIN idempotency_subject_owners o ON ")) {
          return super.query(sql, mapper, arguments);
        }
        var actualIds = new ArrayList<String>();
        List<T> selected = super.query(sql, (result, number) -> {
          actualIds.add(result.getString(1));
          return mapper.mapRow(result, number);
        }, arguments);
        // 原查询与 RowMapper 真实执行后停在 parent lock 之前；不伪造候选或数据库异常。
        assertEquals(List.of(sharedResponseId), actualIds);
        assertEquals(1, selected.size());
        assertEquals("SCOPED", db.queryForObject(
            "SELECT response_state FROM idempotency_requests WHERE id=?", String.class,
            sharedResponseId));
        discoveredIds.addAll(actualIds);
        bothDiscovered.countDown();
        try {
          assertTrue(continueToParentLock.await(10, TimeUnit.SECONDS),
              "Both real discoveries must finish before either parent lock proceeds");
        } catch (InterruptedException interrupted) {
          Thread.currentThread().interrupt();
          throw new AssertionError("Interrupted before the shared parent-lock race", interrupted);
        }
        return selected;
      }
    };
    var racing = new ErasureIdempotencyProcessor(fixture.data.jobs, observingDb, fixture.catalog);
    var pool = Executors.newFixedThreadPool(2);
    try {
      var first = pool.submit(() -> racing.process(claims.get(0), 25));
      var second = pool.submit(() -> racing.process(claims.get(1), 25));
      assertTrue(bothDiscovered.await(10, TimeUnit.SECONDS),
          "Both subject jobs must read the same still-SCOPED response before either locks it");
      assertEquals(List.of(sharedResponseId, sharedResponseId), List.copyOf(discoveredIds));
      assertEquals("SCOPED", row(SHARED_KEY).get("response_state"));
      continueToParentLock.countDown();
      var firstResult = first.get(20, TimeUnit.SECONDS);
      var secondResult = second.get(20, TimeUnit.SECONDS);
      assertEquals(1, firstResult.redactedRows() + secondResult.redactedRows());
      assertEquals(1, firstResult.totalRows() + secondResult.totalRows());
    } finally {
      continueToParentLock.countDown();
      pool.shutdownNow();
      assertTrue(pool.awaitTermination(20, TimeUnit.SECONDS));
    }

    var expired = claims.get(0);
    String requestId = expired.job().entry().request().requestId();
    assertEquals(1, db.update("UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
        requestId));
    var replacement = fixture.data.jobs.claim(id(), 300);
    assertNotNull(replacement);
    assertEquals(requestId, replacement.job().entry().request().requestId());
    assertEquals(expired.fence() + 1, replacement.fence());
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> processor.process(expired, 25));

    var reconstructed = new ErasureIdempotencyProcessor(
        fixture.data.jobs, new JdbcTemplate(fixture.data.business), fixture.catalog);
    var firstDone = finish(reconstructed, replacement);
    var secondDone = finish(reconstructed, claims.get(1));
    assertEquals(1, firstDone.totalRows() + secondDone.totalRows());
    fixture.data.jobs.retry(replacement, ErasureRecoveryJobs.RetryReason.HANDLER_UNAVAILABLE, 0);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST",
        () -> reconstructed.process(replacement, 25));
    var retried = fixture.data.jobs.claim(id(), 300);
    assertNotNull(retried);
    assertEquals(requestId, retried.job().entry().request().requestId());
    assertEquals(replacement.fence() + 1, retried.fence());
    var repeated = finish(reconstructed, retried);
    assertEquals(firstDone.totalRows(), repeated.totalRows());
    assertEquals(0, repeated.redactedRows());

    assertEquals(1L, processedRows());
    assertErased(SHARED_KEY);
    assertOwners(SHARED_KEY, sharedOwners);
    assertOwners(RETAINED_KEY, retainedOwners);
    assertEquals(retainedBefore, row(RETAINED_KEY));
    assertEquals(400L, count("idempotency_subject_owners"));
    assertEquals(202L, fixture.count("subjects"));
    assertPermanentGone(SHARED_KEY);
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, fixture.data.ledger.workState());
  }

  @Test
  void twoHundredAndOneStoredOwnersRollBackEarlierActualRedactionAndTheCheckpoint() {
    String validKey = "valid-before-corrupt";
    String corruptKey = "corrupt-later-response";
    assertTrue(digest(validKey).compareTo(digest(corruptKey)) < 0,
        "The valid response must be processed before the damaged response");
    create(validKey, List.of(fixture.subject));
    create(corruptKey, List.of(fixture.subject));
    var damagedOwners = new ArrayList<String>();
    damagedOwners.add(fixture.subject);
    for (int index = 0; index < 200; index++) {
      String person = insertSubject();
      damagedOwners.add(person);
      // 模拟存储损坏；合法 response 必须先由真实 execute 提交，不能预置 ERASED。
      db.update("INSERT INTO idempotency_subject_owners(id,scope_id,actor_key,operation_key,"
              + "key_hash,tenant_id,subject_key) VALUES(?,?,?,?,?,?,?)",
          id(), tenant, digest(ACTOR), digest(OPERATION), digest(corruptKey), tenant,
          ownerDigest(person));
    }
    assertEquals(201, damagedOwners.size());
    assertOwners(corruptKey, damagedOwners);
    var validBefore = row(validKey);
    var corruptBefore = row(corruptKey);
    var actualRedactions = new AtomicInteger();
    var observingDb = new JdbcTemplate(fixture.data.business) {
      @Override
      public int update(String sql, Object... arguments) {
        int changed = super.update(sql, arguments);
        if (sql.startsWith("UPDATE idempotency_requests SET response_body=NULL")) {
          assertEquals(digest(validKey), arguments[4]);
          actualRedactions.addAndGet(changed);
        }
        return changed;
      }
    };
    var observing = new ErasureIdempotencyProcessor(
        fixture.data.jobs, observingDb, fixture.catalog);
    var claim = accept(fixture.subject);
    fixture.data.failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT", () -> observing.process(claim, 25));

    assertEquals(1, actualRedactions.get(), "The failure must follow an actual earlier write");
    assertEquals(validBefore, row(validKey));
    assertEquals(corruptBefore, row(corruptKey));
    assertOwners(validKey, List.of(fixture.subject));
    assertOwners(corruptKey, damagedOwners);
    assertEquals(0L, db.queryForObject(
        "SELECT COUNT(*) FROM erasure_recovery_steps WHERE request_id=?", Long.class,
        claim.job().entry().request().requestId()));
  }

  @Test
  void twoHundredAndOneRequestedOwnersRollBackBusinessMutationAndJournalTogether() {
    var tooMany = new ArrayList<>(twoHundredSubjects());
    tooMany.add(insertSubject());
    assertEquals(201, tooMany.size());
    var mutations = new AtomicInteger();
    String previousName = db.queryForObject(
        "SELECT nickname FROM subjects WHERE tenant_id=? AND id=?", String.class,
        tenant, fixture.subject);
    assertThrows(IllegalArgumentException.class, () -> tx.execute(status -> journal.execute(
        tenant, ACTOR, OPERATION, "too-many-owners", ATTRIBUTES, SharedResponse.class,
        () -> {
          mutations.incrementAndGet();
          assertEquals(1, db.update("UPDATE subjects SET nickname='uncommitted replacement'"
                  + " WHERE tenant_id=? AND id=?", tenant, fixture.subject));
          return new SharedResponse(List.copyOf(tooMany), "private oversized response");
        }, response -> ResponseOwnership.subjects(tenant, response.subjectIds()))));
    assertEquals(1, mutations.get());
    assertEquals(previousName, db.queryForObject(
        "SELECT nickname FROM subjects WHERE tenant_id=? AND id=?", String.class,
        tenant, fixture.subject));
    assertEquals(0L, count("idempotency_requests"));
    assertEquals(0L, count("idempotency_subject_owners"));
  }

  private SharedResponse create(String key, List<String> owners) {
    return assertDoesNotThrow(() -> tx.execute(status -> journal.execute(
        tenant, ACTOR, OPERATION, key, ATTRIBUTES, SharedResponse.class,
        () -> new SharedResponse(List.copyOf(owners), "private shared response"),
        response -> ResponseOwnership.subjects(tenant, response.subjectIds()))),
        "A valid response with at most 200 distinct subjects must commit atomically");
  }

  private List<String> twoHundredSubjects() {
    var result = new ArrayList<>(List.of(fixture.subject, fixture.peer));
    while (result.size() < 200) result.add(insertSubject());
    assertEquals(200, result.stream().distinct().count());
    return List.copyOf(result);
  }

  private List<String> otherTwoHundredSubjects(List<String> shared) {
    var result = new ArrayList<>(shared.subList(2, 200));
    result.add(insertSubject());
    result.add(insertSubject());
    assertEquals(200, result.stream().distinct().count());
    assertFalse(result.contains(shared.get(0)));
    assertFalse(result.contains(shared.get(1)));
    return List.copyOf(result);
  }

  private String insertSubject() {
    String person = id();
    assertEquals(1, db.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
        + " VALUES(?,?,'private fixture source','AGE_7_12',1)", tenant, person));
    return person;
  }

  private ErasureRecoveryJobs.Claim accept(String person) {
    var entry = fixture.data.ledger.append(new ErasureLedger.Request(
        id(), tenant, person, "a".repeat(64), "b".repeat(64), "c".repeat(64), List.of()));
    assertEquals(1, fixture.data.jobs.reconcile(10).imported());
    var claim = fixture.data.jobs.claim(id(), 300);
    assertNotNull(claim);
    assertEquals(entry, claim.job().entry());
    return claim;
  }

  private List<ErasureRecoveryJobs.Claim> acceptTwoSubjects(String first, String second) {
    var firstClaim = accept(first);
    var secondClaim = accept(second);
    assertNotEquals(firstClaim.job().entry().request().requestId(),
        secondClaim.job().entry().request().requestId());
    assertNotEquals(firstClaim.job().entry().request().subjectId(),
        secondClaim.job().entry().request().subjectId());
    assertEquals(2, fixture.data.ledger.head().sequence());
    return List.of(firstClaim, secondClaim);
  }

  private ErasureIdempotencyProcessor.Result finish(
      ErasureIdempotencyProcessor worker, ErasureRecoveryJobs.Claim claim) {
    for (int batch = 0; batch < 100; batch++) {
      var result = worker.process(claim, 25);
      assertFalse(result.classificationBlocked());
      if (result.complete()) return result;
    }
    fail("Bounded journal response work did not finish");
    return null;
  }

  private Object[] key(String value) {
    return new Object[] {tenant, digest(ACTOR), digest(OPERATION), digest(value)};
  }

  private Map<String, Object> row(String value) {
    return db.queryForMap("SELECT * FROM idempotency_requests WHERE scope_id=? AND actor_key=?"
        + " AND operation_key=? AND key_hash=?", key(value));
  }

  private void assertOwners(String value, List<String> subjects) {
    var actual = db.queryForList(
        "SELECT subject_key FROM idempotency_subject_owners WHERE scope_id=? AND actor_key=?"
            + " AND operation_key=? AND key_hash=? ORDER BY subject_key", String.class, key(value));
    var expected = subjects.stream().map(this::ownerDigest).sorted().toList();
    assertEquals(expected, actual);
    assertEquals(subjects.size(), actual.size());
    assertEquals(subjects.size(), actual.stream().distinct().count());
    assertEquals(subjects.size(), db.queryForObject(
        "SELECT COUNT(*) FROM idempotency_subject_owners WHERE scope_id=? AND actor_key=?"
            + " AND operation_key=? AND key_hash=? AND tenant_id=?", Integer.class,
        tenant, digest(ACTOR), digest(OPERATION), digest(value), tenant));
  }

  private void assertErased(String value) {
    var stored = row(value);
    assertEquals("ERASED", stored.get("response_state"));
    assertNull(stored.get("response_body"));
    assertEquals("", stored.get("actor_id"));
    assertEquals("", stored.get("operation"));
    assertEquals("0".repeat(64), stored.get("request_hash"));
    assertEquals(digest(ACTOR), stored.get("actor_key"));
    assertEquals(digest(OPERATION), stored.get("operation_key"));
    assertEquals(digest(value), stored.get("key_hash"));
  }

  private void assertPermanentGone(String value) {
    // 此处调用服务方法；恢复暂停仍生效，不能据此宣称普通 HTTP 绕过暂停过滤器。
    var originalOwners = db.queryForList(
        "SELECT id,tenant_id,subject_key FROM idempotency_subject_owners WHERE scope_id=?"
            + " AND actor_key=? AND operation_key=? AND key_hash=? ORDER BY id", key(value));
    long originalResponses = count("idempotency_requests");
    for (long expiry : new long[] {CLOCK.millis() + 60000, 0}) {
      assertEquals(1, db.update("UPDATE idempotency_requests SET expires_at=? WHERE scope_id=?"
              + " AND actor_key=? AND operation_key=? AND key_hash=?",
          expiry, tenant, digest(ACTOR), digest(OPERATION), digest(value)));
      for (var attributes : List.of(ATTRIBUTES, Map.of("selection", "changed-after-erasure"))) {
        assertGone(() -> tx.execute(status -> journal.execute(
            tenant, ACTOR, OPERATION, value, attributes, SharedResponse.class,
            () -> { throw new AssertionError("An erased key must never repeat its mutation"); },
            response -> { throw new AssertionError("An erased key must never replace owners"); })));
        assertGone(() -> tx.execute(status -> journal.findCommitted(
            tenant, ACTOR, OPERATION, value, attributes, SharedResponse.class)));
      }
      assertErased(value);
    }
    assertEquals(originalOwners, db.queryForList(
        "SELECT id,tenant_id,subject_key FROM idempotency_subject_owners WHERE scope_id=?"
            + " AND actor_key=? AND operation_key=? AND key_hash=? ORDER BY id", key(value)));
    assertEquals(originalResponses, count("idempotency_requests"));
  }

  private void assertGone(Executable action) {
    var failure = assertThrows(DomainException.class, action);
    assertEquals(HttpStatus.GONE, failure.status());
    assertEquals("IDEMPOTENCY_RESPONSE_ERASED", failure.errorCode());
    assertFalse(failure.getMessage().contains("private shared response"));
    assertFalse(failure.getMessage().contains(fixture.subject));
  }

  private long count(String table) {
    return db.queryForObject("SELECT COUNT(*) FROM " + table, Long.class);
  }

  private long processedRows() {
    return db.queryForObject("SELECT COALESCE(SUM(rows_processed),0) FROM erasure_recovery_steps"
        + " WHERE step_code=?", Long.class, STEP);
  }

  private String ownerDigest(String subject) {
    // 独立摘要 oracle；不调用生产 ownership helper，也不引用待实现的上限常量。
    return digest("idempotency-subject-v1\n" + tenant + "\n" + subject);
  }

  private static String digest(String value) {
    try {
      return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
          .digest(value.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException failure) {
      throw new AssertionError("Required test digest is unavailable", failure);
    }
  }

  private static String id() {
    return UUID.randomUUID().toString();
  }
}
