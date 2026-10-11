package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.time.Clock;
import java.util.*;
import java.util.concurrent.*;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

class ErasureRecoveryJobsTest {
  DataSource business, journal;
  JdbcTemplate db, ledgerDb;
  String id;
  JdbcErasureLedger ledger;
  ErasureRecoveryJobs jobs;

  DataSource source(String prefix) {
    var env = System.getenv();
    String url =
        env.getOrDefault(
            prefix + "_URL",
            "jdbc:h2:mem:"
                + UUID.randomUUID()
                + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE");
    if (env.containsKey(prefix + "_URL")
        && !url.matches("jdbc:mysql://127\\.0\\.0\\.1:3308/notification_it_[a-f0-9]{32}\\?.*"))
      throw new IllegalArgumentException("Recovery tests require isolated schemas");
    return new DriverManagerDataSource(
        url,
        env.getOrDefault(prefix + "_USERNAME", "sa"),
        env.getOrDefault(prefix + "_PASSWORD", ""));
  }

  @BeforeEach
  void setup() {
    business = source("LEDGER_BUSINESS_TEST");
    journal = source("LEDGER_STORE_TEST");
    db = new JdbcTemplate(business);
    ledgerDb = new JdbcTemplate(journal);
    String vendor = System.getenv("LEDGER_BUSINESS_TEST_URL") == null ? "h2" : "mysql";
    Flyway.configure()
        .dataSource(business)
        .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
        .load()
        .migrate();
    // Only explicitly isolated fixture schemas can reach this setup.
    if (hasTable("erasure_recovery_steps")) db.update("DELETE FROM erasure_recovery_steps");
    if (hasTable("erasure_recovery_jobs")) db.update("DELETE FROM erasure_recovery_jobs");
    if (hasTable("erasure_recovery_state")) db.update("DELETE FROM erasure_recovery_state");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_work_admissions");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_admission_pause");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_ledger_entries");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_ledger_head");
    id = UUID.randomUUID().toString();
    ErasureLedgerBootstrap.initialize(journal, id);
    ledger = new JdbcErasureLedger(business, journal, id, Clock.systemUTC());
    jobs = new ErasureRecoveryJobs(db, new DataSourceTransactionManager(business), ledger);
  }

  boolean hasTable(String name) {
    return db.queryForObject(
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE LOWER(TABLE_NAME)=?",
            Integer.class,
            name)
        > 0;
  }

  ErasureLedger.Request request() {
    String hash = "a".repeat(64);
    return new ErasureLedger.Request(
        UUID.randomUUID().toString(),
        UUID.randomUUID().toString(),
        UUID.randomUUID().toString(),
        hash,
        hash,
        hash,
        List.of(
            new ErasureLedger.Registration(
                UUID.randomUUID().toString(), UUID.randomUUID().toString())));
  }

  void failure(String code, org.junit.jupiter.api.function.Executable action) {
    assertEquals(code, assertThrows(ErasureLedger.Failure.class, action).code());
  }

  @Test
  void importsBoundedPagesWithoutPretendingErasureIsComplete() {
    var entries =
        List.of(ledger.append(request()), ledger.append(request()), ledger.append(request()));
    var first = jobs.reconcile(2);
    assertNotNull(first);
    assertEquals(2, first.imported());
    assertEquals(2, first.read().sequence());
    assertFalse(first.endOfSnapshot());
    var second = jobs.reconcile(2);
    assertEquals(1, second.imported());
    assertTrue(second.endOfSnapshot());
    assertEquals(0, jobs.reconcile(2).imported());
    for (var entry : entries) {
      var job = jobs.find(entry.request().requestId());
      assertNotNull(job);
      assertEquals(entry, job.entry());
      assertEquals("ACCEPTED", job.state());
      assertEquals(0, job.fence());
    }
    assertEquals(3, db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_jobs", Integer.class));
  }

  @Test
  void ledgerAcceptanceSurvivesBusinessRollbackAndRebuildsLostBusinessProjection() {
    var entry = ledger.append(request());
    var tx = new TransactionTemplate(new DataSourceTransactionManager(business));
    tx.executeWithoutResult(
        status -> {
          jobs.reconcile(10);
          status.setRollbackOnly();
        });
    assertEquals(entry, jobs.find(entry.request().requestId()).entry());
    db.update("DELETE FROM erasure_recovery_jobs");
    db.update("DELETE FROM erasure_recovery_state");
    assertEquals(1, jobs.reconcile(10).imported());
    assertEquals(entry, jobs.find(entry.request().requestId()).entry());
  }

  @Test
  void partialPageFailureRollsBackJobsAndCursor() {
    var a = ledger.append(request());
    var b = ledger.append(request());
    jobs.reconcile(2);
    db.update("DELETE FROM erasure_recovery_jobs WHERE request_id=?", a.request().requestId());
    db.update(
        "UPDATE erasure_recovery_state SET read_sequence=0,read_hash=?",
        LedgerIntegrity.genesis(id));
    db.update(
        "UPDATE erasure_recovery_jobs SET request_hash=? WHERE request_id=?",
        "b".repeat(64),
        b.request().requestId());
    failure("ERASURE_RECOVERY_CORRUPT", () -> jobs.reconcile(100));
    assertNull(jobs.find(a.request().requestId()));
    assertEquals(
        0L, db.queryForObject("SELECT read_sequence FROM erasure_recovery_state", Long.class));
  }

  @Test
  void startupPersistsRecoveryButNeverMistakesReadTailForCompletedErasure() {
    var entry = ledger.append(request());
    var guard = new ErasureStartupGuard(jobs, true, "");
    failure("ERASURE_LEDGER_RECONCILIATION_REQUIRED", guard::afterSingletonsInstantiated);
    assertEquals(entry, jobs.find(entry.request().requestId()).entry());
    assertEquals("ACCEPTED", jobs.find(entry.request().requestId()).state());
    assertEquals(
        1L, db.queryForObject("SELECT read_sequence FROM erasure_recovery_state", Long.class));
    failure("ERASURE_LEDGER_RECONCILIATION_REQUIRED", guard::afterSingletonsInstantiated);
    assertEquals(1, db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_jobs", Integer.class));
  }

  @Test
  void concurrentImportAndClaimsDoNotDuplicateOrShareLeases() throws Exception {
    for (int i = 0; i < 4; i++) ledger.append(request());
    var pool = Executors.newFixedThreadPool(4);
    try {
      var imports = new ArrayList<Future<?>>();
      for (int i = 0; i < 4; i++) imports.add(pool.submit(() -> jobs.reconcile(2)));
      for (var future : imports) future.get(15, TimeUnit.SECONDS);
      assertEquals(
          4, db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_jobs", Integer.class));
      var claims = new ArrayList<Future<ErasureRecoveryJobs.Claim>>();
      for (int i = 0; i < 4; i++)
        claims.add(pool.submit(() -> jobs.claim(UUID.randomUUID().toString(), 30)));
      var ids = new HashSet<String>();
      for (var future : claims) {
        var claim = future.get(15, TimeUnit.SECONDS);
        assertNotNull(claim);
        assertTrue(ids.add(claim.job().entry().request().requestId()));
      }
      assertNull(jobs.claim(UUID.randomUUID().toString(), 30));
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void expiredLeaseGetsHigherFenceAndOldWorkerCannotMutateIt() {
    var entry = ledger.append(request());
    jobs.reconcile(10);
    var old = jobs.claim(UUID.randomUUID().toString(), 30);
    assertNotNull(old);
    db.update(
        "UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
        entry.request().requestId());
    var current = jobs.claim(UUID.randomUUID().toString(), 30);
    assertEquals(old.fence() + 1, current.fence());
    failure("ERASURE_RECOVERY_LEASE_LOST", () -> jobs.renew(old, 30));
    failure(
        "ERASURE_RECOVERY_LEASE_LOST",
        () -> jobs.retry(old, ErasureRecoveryJobs.RetryReason.HANDLER_UNAVAILABLE, 1));
    assertTrue(jobs.renew(current, 60).until() >= current.until());
    jobs.retry(current, ErasureRecoveryJobs.RetryReason.HANDLER_UNAVAILABLE, 60);
    assertEquals("RETRY_REQUIRED", jobs.find(entry.request().requestId()).state());
    assertNull(jobs.claim(UUID.randomUUID().toString(), 30));
    db.update(
        "UPDATE erasure_recovery_jobs SET next_attempt_at=0 WHERE request_id=?",
        entry.request().requestId());
    assertEquals(current.fence() + 1, jobs.claim(UUID.randomUUID().toString(), 30).fence());
  }

  @Test
  void anExpiredOwnerCannotRenewEvenBeforeReplacement() {
    ledger.append(request());
    jobs.reconcile(10);
    var claim = jobs.claim(UUID.randomUUID().toString(), 30);
    db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
    failure("ERASURE_RECOVERY_LEASE_LOST", () -> jobs.renew(claim, 30));
    failure(
        "ERASURE_RECOVERY_LEASE_LOST",
        () -> jobs.retry(claim, ErasureRecoveryJobs.RetryReason.EXTERNAL_PENDING, 0));
  }

  @Test
  void claimVerifiesImmutableProjectionAgainstTheIndependentJournal() {
    var first = ledger.append(request());
    jobs.reconcile(10);
    db.update("UPDATE erasure_recovery_jobs SET tenant_id=?", UUID.randomUUID().toString());
    failure("ERASURE_RECOVERY_CORRUPT", () -> jobs.claim(UUID.randomUUID().toString(), 30));
    db.update("UPDATE erasure_recovery_jobs SET tenant_id=?", first.request().tenantId());
    ledgerDb.update("UPDATE erasure_ledger_entries SET entry_hash=?", "b".repeat(64));
    assertThrows(ErasureLedger.Failure.class, () -> jobs.claim(UUID.randomUUID().toString(), 30));
    assertEquals("ACCEPTED", jobs.find(first.request().requestId()).state());
  }

  @Test
  void invalidBoundsDoNotPersistAnyRecoveryState() {
    assertThrows(IllegalArgumentException.class, () -> jobs.reconcile(0));
    assertThrows(IllegalArgumentException.class, () -> jobs.reconcile(101));
    assertThrows(IllegalArgumentException.class, () -> jobs.claim("worker-name", 30));
    assertThrows(IllegalArgumentException.class, () -> jobs.claim(UUID.randomUUID().toString(), 0));
    assertThrows(
        IllegalArgumentException.class, () -> jobs.claim(UUID.randomUUID().toString(), 301));
    assertEquals(
        0, db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_state", Integer.class));
  }

  @Test
  void changedLedgerIdentityAndMissingAnchorFailClosed() {
    var entry = ledger.append(request());
    jobs.reconcile(10);
    db.update("UPDATE erasure_recovery_state SET ledger_id=?", UUID.randomUUID().toString());
    failure("ERASURE_RECOVERY_IDENTITY_MISMATCH", () -> jobs.reconcile(10));
    db.update("UPDATE erasure_recovery_state SET ledger_id=?", id);
    db.update("DELETE FROM erasure_recovery_jobs WHERE request_id=?", entry.request().requestId());
    failure("ERASURE_RECOVERY_CORRUPT", () -> jobs.reconcile(10));
  }

  @Test
  void missingEarlierJobCannotBeSkippedByAnIntactTail() {
    var first = ledger.append(request());
    ledger.append(request());
    ledger.append(request());
    jobs.reconcile(10);
    db.update("DELETE FROM erasure_recovery_jobs WHERE request_id=?", first.request().requestId());
    failure("ERASURE_RECOVERY_CORRUPT", () -> jobs.reconcile(10));
    assertEquals(
        3L, db.queryForObject("SELECT read_sequence FROM erasure_recovery_state", Long.class));
  }

  @Test
  void transactionStartupFailureUsesStableCodeWithoutConnectionDetails() {
    var manager =
        org.mockito.Mockito.mock(org.springframework.transaction.PlatformTransactionManager.class);
    org.mockito.Mockito.when(manager.getTransaction(org.mockito.ArgumentMatchers.any()))
        .thenThrow(
            new org.springframework.transaction.CannotCreateTransactionException(
                "private-connection-detail"));
    var unavailable = new ErasureRecoveryJobs(db, manager, ledger);
    failure("ERASURE_RECOVERY_UNAVAILABLE", () -> unavailable.find(UUID.randomUUID().toString()));
  }

  @Test
  void malformedOrOversizedScopeAndExhaustedFenceFailClosed() {
    var entry = ledger.append(request());
    jobs.reconcile(10);
    String payload =
        db.queryForObject("SELECT request_json FROM erasure_recovery_jobs", String.class);
    db.update("UPDATE erasure_recovery_jobs SET request_json=?", payload + " {}");
    failure("ERASURE_RECOVERY_CORRUPT", () -> jobs.claim(UUID.randomUUID().toString(), 30));
    db.update("UPDATE erasure_recovery_jobs SET request_json=?", " ".repeat(262145));
    failure("ERASURE_RECOVERY_CORRUPT", () -> jobs.find(entry.request().requestId()));
    db.update("UPDATE erasure_recovery_jobs SET request_json=?,fence=?", payload, Long.MAX_VALUE);
    failure("ERASURE_RECOVERY_FENCE_EXHAUSTED", () -> jobs.claim(UUID.randomUUID().toString(), 30));
    assertEquals("ACCEPTED", jobs.find(entry.request().requestId()).state());
  }

  @Test
  void selfConsistentForgedScopeCannotAcquireALease() throws Exception {
    var entry = ledger.append(request());
    jobs.reconcile(10);
    var original = entry.request();
    var forged =
        new ErasureLedger.Request(
            original.requestId(),
            UUID.randomUUID().toString(),
            original.subjectId(),
            original.actorHash(),
            original.policyHash(),
            original.scopeHash(),
            original.registrations());
    String hash = LedgerIntegrity.requestHash(forged);
    db.update(
        "UPDATE erasure_recovery_jobs SET tenant_id=?,request_json=?,request_hash=?,entry_hash=?",
        forged.tenantId(),
        new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(forged),
        hash,
        LedgerIntegrity.entryHash(
            id, entry.sequence(), entry.acceptedAt(), entry.previousHash(), hash));
    failure("ERASURE_RECOVERY_CORRUPT", () -> jobs.claim(UUID.randomUUID().toString(), 30));
    assertEquals("ACCEPTED", jobs.find(original.requestId()).state());
  }

  @Test
  void startupRejectsLedgerRestoredToAnOlderEmptySnapshot() {
    ledger.append(request());
    jobs.reconcile(10);
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_work_admissions");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_admission_pause");
    ledgerDb.execute("DROP TABLE erasure_ledger_entries");
    ledgerDb.execute("DROP TABLE erasure_ledger_head");
    ErasureLedgerBootstrap.initialize(journal, id);
    assertEquals(0, ledger.head().sequence());
    var guard = new ErasureStartupGuard(jobs, true, "");
    failure("ERASURE_LEDGER_BEHIND_BUSINESS", guard::afterSingletonsInstantiated);
    assertEquals(
        1L, db.queryForObject("SELECT read_sequence FROM erasure_recovery_state", Long.class));
  }

  @Test
  void startupRejectsSwitchToADifferentValidEmptyLedger() {
    ledger.append(request());
    jobs.reconcile(10);
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_work_admissions");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_admission_pause");
    ledgerDb.execute("DROP TABLE erasure_ledger_entries");
    ledgerDb.execute("DROP TABLE erasure_ledger_head");
    String replacementId = UUID.randomUUID().toString();
    ErasureLedgerBootstrap.initialize(journal, replacementId);
    var replacement = new JdbcErasureLedger(business, journal, replacementId, Clock.systemUTC());
    var recovery =
        new ErasureRecoveryJobs(db, new DataSourceTransactionManager(business), replacement);
    assertEquals(0, replacement.head().sequence());
    var guard = new ErasureStartupGuard(recovery, true, "");
    failure("ERASURE_RECOVERY_IDENTITY_MISMATCH", guard::afterSingletonsInstantiated);
  }

  @Test
  void startupAcceptsAGenuinelyNewEmptyBusinessAndJournalPair() {
    var guard = new ErasureStartupGuard(jobs, true, "");
    assertDoesNotThrow(guard::afterSingletonsInstantiated);
    assertEquals(
        id, db.queryForObject("SELECT ledger_id FROM erasure_recovery_state", String.class));
    assertEquals(
        0L, db.queryForObject("SELECT read_sequence FROM erasure_recovery_state", Long.class));
    assertDoesNotThrow(guard::afterSingletonsInstantiated);
  }
}
