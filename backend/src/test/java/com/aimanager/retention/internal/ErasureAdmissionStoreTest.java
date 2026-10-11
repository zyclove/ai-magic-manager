package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.time.Clock;
import java.util.*;
import java.util.concurrent.*;
import javax.sql.DataSource;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.support.TransactionTemplate;

class ErasureAdmissionStoreTest {
  DataSource business, journal;
  JdbcTemplate db;
  JdbcErasureLedger first, second;
  String id;

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
      throw new IllegalArgumentException("Admission tests require isolated schemas");
    return new DriverManagerDataSource(
        url,
        env.getOrDefault(prefix + "_USERNAME", "sa"),
        env.getOrDefault(prefix + "_PASSWORD", ""));
  }

  @BeforeEach
  void setup() {
    business = source("LEDGER_BUSINESS_TEST");
    journal = source("LEDGER_STORE_TEST");
    db = new JdbcTemplate(journal);
    for (String table :
        List.of(
            "erasure_work_admissions",
            "erasure_admission_pause",
            "erasure_ledger_entries",
            "erasure_ledger_head")) db.execute("DROP TABLE IF EXISTS " + table);
    id = UUID.randomUUID().toString();
    ErasureLedgerBootstrap.initialize(journal, id);
    first = new JdbcErasureLedger(business, journal, id, Clock.systemUTC());
    second = new JdbcErasureLedger(business, journal, id, Clock.systemUTC());
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
        List.of());
  }

  ErasureLedger.WorkPermit begin(JdbcErasureLedger store) {
    return store.beginWork(UUID.randomUUID().toString());
  }

  void failure(String code, org.junit.jupiter.api.function.Executable action) {
    assertEquals(code, assertThrows(ErasureLedger.Failure.class, action).code());
  }

  long active() {
    return db.queryForObject("SELECT COUNT(*) FROM erasure_work_admissions", Long.class);
  }

  @Test
  void independentWorkersRegisterDurablyAndReleaseIdempotently() {
    var a = begin(first);
    var b = begin(second);
    assertEquals(2, active());
    assertEquals(ErasureLedger.WorkState.READY, first.workState());
    a.close();
    a.close();
    assertEquals(1, active());
    b.close();
    assertEquals(0, active());
  }

  @Test
  void pendingAppendClosesAdmissionAndWaitsForEveryExistingWorker() {
    var request = request();
    var a = begin(first);
    var b = begin(second);
    failure("ERASURE_LEDGER_WORK_ACTIVE", () -> first.append(request));
    assertEquals(0, second.head().sequence());
    assertEquals(ErasureLedger.WorkState.PAUSING, second.workState());
    failure("ERASURE_LEDGER_WORK_PAUSED", () -> begin(second));
    failure("ERASURE_LEDGER_REQUEST_CONFLICT", () -> second.append(request()));
    a.close();
    failure("ERASURE_LEDGER_WORK_ACTIVE", () -> second.append(request));
    b.close();
    var entry = second.append(request);
    assertEquals(1, entry.sequence());
    assertEquals(entry, first.append(request));
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, first.workState());
    failure("ERASURE_LEDGER_RECONCILIATION_REQUIRED", () -> begin(first));
    assertEquals(0L, db.queryForObject("SELECT COUNT(*) FROM erasure_admission_pause", Long.class));
  }

  @Test
  void acceptedRecordRejectsWorkEvenWithoutPriorPause() {
    first.append(request());
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, second.workState());
    failure("ERASURE_LEDGER_RECONCILIATION_REQUIRED", () -> begin(second));
  }

  @Test
  void abandonedOldPermitIsNeverAutomaticallyExpiredOrForgottenByNewInstance() {
    var permit = begin(first);
    db.update("UPDATE erasure_work_admissions SET started_at=1");
    var restarted = new JdbcErasureLedger(business, journal, id, Clock.systemUTC());
    var request = request();
    failure("ERASURE_LEDGER_WORK_ACTIVE", () -> restarted.append(request));
    assertEquals(1, active());
    assertEquals(0, restarted.head().sequence());
    permit.close();
    assertEquals(1, restarted.append(request).sequence());
  }

  @Test
  void pauseSurvivesRollbackOfCallerBusinessTransaction() {
    var permit = begin(first);
    var request = request();
    new TransactionTemplate(new DataSourceTransactionManager(business))
        .executeWithoutResult(
            status -> {
              failure("ERASURE_LEDGER_WORK_ACTIVE", () -> first.append(request));
              status.setRollbackOnly();
            });
    assertEquals(ErasureLedger.WorkState.PAUSING, second.workState());
    assertEquals(0, second.head().sequence());
    permit.close();
    second.append(request);
  }

  @Test
  void releaseFailsClosedOnIdentityChangeAndCanRetryAfterRepair() {
    var permit = begin(first);
    db.update("UPDATE erasure_ledger_head SET ledger_id=?", UUID.randomUUID().toString());
    failure("ERASURE_LEDGER_IDENTITY_MISMATCH", permit::close);
    assertEquals(1, active());
    db.update("UPDATE erasure_ledger_head SET ledger_id=?", id);
    permit.close();
    assertEquals(0, active());
  }

  @Test
  void concurrentAdmissionAndAcceptanceCannotBothSucceed() throws Exception {
    var start = new CountDownLatch(1);
    var pool = Executors.newFixedThreadPool(2);
    try {
      Future<ErasureLedger.WorkPermit> admission =
          pool.submit(
              () -> {
                start.await();
                try {
                  return begin(first);
                } catch (ErasureLedger.Failure denied) {
                  assertEquals("ERASURE_LEDGER_RECONCILIATION_REQUIRED", denied.code());
                  return null;
                }
              });
      Future<ErasureLedger.Entry> append =
          pool.submit(
              () -> {
                start.await();
                try {
                  return second.append(request());
                } catch (ErasureLedger.Failure pending) {
                  assertEquals("ERASURE_LEDGER_WORK_ACTIVE", pending.code());
                  return null;
                }
              });
      start.countDown();
      var permit = admission.get(15, TimeUnit.SECONDS);
      var entry = append.get(15, TimeUnit.SECONDS);
      assertNotEquals(permit == null, entry == null);
      if (permit != null) permit.close();
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void corruptedPauseCannotAdmitOrAcceptDifferentScope() {
    var permit = begin(first);
    var request = request();
    failure("ERASURE_LEDGER_WORK_ACTIVE", () -> first.append(request));
    db.update("UPDATE erasure_admission_pause SET request_hash=?", "b".repeat(64));
    failure("ERASURE_LEDGER_CORRUPT", () -> begin(second));
    failure("ERASURE_LEDGER_CORRUPT", () -> second.append(request));
    permit.close();
    assertEquals(0, first.head().sequence());
  }

  @Test
  void invalidWorkerIdentifierDoesNotCreateARecord() {
    assertThrows(IllegalArgumentException.class, () -> first.beginWork("a worker name"));
    assertEquals(0, active());
  }

  @Test
  @org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable(
      named = "NOTICE_IT_ROOT_PASSWORD",
      matches = ".+")
  void leastPrivilegeRuntimeCanDrainWorkButCannotRewriteAcceptedRecords() throws Exception {
    String url = System.getenv("LEDGER_STORE_TEST_URL");
    assertNotNull(url);
    assertTrue(url.matches("jdbc:mysql://127\\.0\\.0\\.1:3308/notification_it_[a-f0-9]{32}\\?.*"));
    String schema =
        db.execute(
            (org.springframework.jdbc.core.ConnectionCallback<String>)
                java.sql.Connection::getCatalog);
    assertNotNull(schema);
    assertTrue(schema.matches("notification_it_[a-f0-9]{32}"));
    String user = "admit_rt_" + UUID.randomUUID().toString().replace("-", "").substring(0, 12);
    String password = UUID.randomUUID().toString();
    try (var root =
            java.sql.DriverManager.getConnection(
                url, "root", System.getenv("NOTICE_IT_ROOT_PASSWORD"));
        var sql = root.createStatement()) {
      boolean created = false;
      try {
        sql.execute("CREATE USER '" + user + "'@'%' IDENTIFIED BY '" + password + "'");
        created = true;
        for (var grant :
            Map.of(
                    "erasure_ledger_head",
                    "SELECT,UPDATE",
                    "erasure_ledger_entries",
                    "SELECT,INSERT",
                    "erasure_work_admissions",
                    "SELECT,INSERT,DELETE",
                    "erasure_admission_pause",
                    "SELECT,INSERT,DELETE")
                .entrySet())
          sql.execute(
              "GRANT "
                  + grant.getValue()
                  + " ON "
                  + schema
                  + "."
                  + grant.getKey()
                  + " TO '"
                  + user
                  + "'@'%'");
        var runtimeSource = new DriverManagerDataSource(url, user, password);
        var runtime = new JdbcErasureLedger(business, runtimeSource, id, Clock.systemUTC());
        var permit = begin(runtime);
        var request = request();
        failure("ERASURE_LEDGER_WORK_ACTIVE", () -> runtime.append(request));
        permit.close();
        assertEquals(1, runtime.append(request).sequence());
        var restricted = new JdbcTemplate(runtimeSource);
        for (String denied :
            List.of(
                "DELETE FROM erasure_ledger_entries",
                "UPDATE erasure_ledger_entries SET accepted_at=1",
                "DROP TABLE erasure_work_admissions",
                "UPDATE erasure_work_admissions SET started_at=1"))
          assertThrows(
              org.springframework.dao.DataAccessException.class, () -> restricted.execute(denied));
      } catch (java.sql.SQLException unavailable) {
        fail("Isolated runtime permission setup failed");
      } finally {
        try {
          if (created) sql.execute("DROP USER IF EXISTS '" + user + "'@'%'");
        } catch (java.sql.SQLException unavailable) {
          fail("Isolated runtime account cleanup failed");
        }
      }
    }
  }
}
