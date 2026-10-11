package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.time.Clock;
import java.util.*;
import java.util.concurrent.*;
import javax.sql.DataSource;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

class ErasureLedgerStoreTest {
  DataSource business, ledger;
  JdbcTemplate businessDb, ledgerDb;
  String id;
  JdbcErasureLedger store;
  final String digest = "a".repeat(64);

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
      throw new IllegalArgumentException("Ledger tests require an isolated test schema");
    return new DriverManagerDataSource(
        url,
        env.getOrDefault(prefix + "_USERNAME", "sa"),
        env.getOrDefault(prefix + "_PASSWORD", ""));
  }

  @BeforeEach
  void setUp() {
    business = source("LEDGER_BUSINESS_TEST");
    ledger = source("LEDGER_STORE_TEST");
    businessDb = new JdbcTemplate(business);
    ledgerDb = new JdbcTemplate(ledger);
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_work_admissions");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_admission_pause");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_ledger_entries");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_ledger_head");
    businessDb.execute(
        "CREATE TABLE IF NOT EXISTS ledger_test_business_marker(id VARCHAR(36) PRIMARY KEY)");
    id = UUID.randomUUID().toString();
    ErasureLedgerBootstrap.initialize(ledger, id);
    store = new JdbcErasureLedger(business, ledger, id, Clock.systemUTC());
  }

  ErasureLedger.Request request() {
    return new ErasureLedger.Request(
        UUID.randomUUID().toString(),
        UUID.randomUUID().toString(),
        UUID.randomUUID().toString(),
        digest,
        digest,
        digest,
        List.of(
            new ErasureLedger.Registration(
                UUID.randomUUID().toString(), UUID.randomUUID().toString())));
  }

  ErasureLedger.Checkpoint genesis() {
    return new ErasureLedger.Checkpoint(id, 0, LedgerIntegrity.genesis(id));
  }

  void failure(String code, org.junit.jupiter.api.function.Executable operation) {
    assertEquals(code, assertThrows(ErasureLedger.Failure.class, operation).code());
  }

  @Test
  void initializationIsExplicitAndNeverOverwritesExistingLedger() {
    assertEquals(genesis(), store.head());
    failure("ERASURE_LEDGER_NOT_EMPTY", () -> ErasureLedgerBootstrap.initialize(ledger, id));
    assertEquals(genesis(), store.head());
  }

  @Test
  void sameDatabaseWrongIdentityUnknownTableAndMissingLedgerFailClosed() {
    failure(
        "ERASURE_LEDGER_NOT_INDEPENDENT",
        () -> new JdbcErasureLedger(ledger, ledger, id, Clock.systemUTC()).head());
    failure(
        "ERASURE_LEDGER_IDENTITY_MISMATCH",
        () ->
            new JdbcErasureLedger(business, ledger, UUID.randomUUID().toString(), Clock.systemUTC())
                .head());
    ledgerDb.execute("CREATE TABLE unrelated_store(id INTEGER)");
    try {
      failure("ERASURE_LEDGER_SCHEMA_INVALID", store::head);
    } finally {
      ledgerDb.execute("DROP TABLE unrelated_store");
    }
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_work_admissions");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_admission_pause");
    ledgerDb.execute("DROP TABLE erasure_ledger_entries");
    failure("ERASURE_LEDGER_SCHEMA_INVALID", store::head);
  }

  @Test
  void acceptsExactlyOnceAndCanonicalizesRegistrationOrder() {
    var seed = request();
    var extra =
        new ErasureLedger.Registration(UUID.randomUUID().toString(), UUID.randomUUID().toString());
    var first =
        new ErasureLedger.Request(
            seed.requestId(),
            seed.tenantId(),
            seed.subjectId(),
            digest,
            digest,
            digest,
            List.of(seed.registrations().get(0), extra));
    var reversed =
        new ErasureLedger.Request(
            seed.requestId(),
            seed.tenantId(),
            seed.subjectId(),
            digest,
            digest,
            digest,
            List.of(extra, seed.registrations().get(0)));
    var accepted = store.append(first);
    assertEquals(1, accepted.sequence());
    assertEquals(accepted, store.append(reversed));
    var conflict =
        new ErasureLedger.Request(
            seed.requestId(),
            seed.tenantId(),
            seed.subjectId(),
            digest,
            digest,
            "b".repeat(64),
            first.registrations());
    failure("ERASURE_LEDGER_REQUEST_CONFLICT", () -> store.append(conflict));
    assertEquals(1, store.head().sequence());
  }

  @Test
  void ledgerCommitSurvivesBusinessRollbackAndRestoredOldBusinessWatermark() {
    var accepted = new ArrayList<ErasureLedger.Entry>();
    var tx = new TransactionTemplate(new DataSourceTransactionManager(business));
    tx.executeWithoutResult(
        status -> {
          businessDb.update(
              "INSERT INTO ledger_test_business_marker(id) VALUES(?)",
              UUID.randomUUID().toString());
          accepted.add(store.append(request()));
          status.setRollbackOnly();
        });
    assertEquals(
        0,
        businessDb.queryForObject(
            "SELECT COUNT(*) FROM ledger_test_business_marker", Integer.class));
    assertEquals(accepted.get(0).hash(), store.head().hash());
    var restored = store.readAfter(genesis(), 10);
    assertEquals(accepted, restored.entries());
    assertTrue(restored.endOfSnapshot());
    assertEquals(store.head(), restored.nextRead());
    assertTrue(store.readAfter(restored.nextRead(), 10).entries().isEmpty());
  }

  @Test
  void replayIsBoundedContiguousAndAnchoredToTheSameLedger() {
    for (int n = 0; n < 5; n++) store.append(request());
    var first = store.readAfter(genesis(), 2);
    assertEquals(
        List.of(1L, 2L), first.entries().stream().map(ErasureLedger.Entry::sequence).toList());
    assertFalse(first.endOfSnapshot());
    var second = store.readAfter(first.nextRead(), 2);
    assertEquals(4, second.nextRead().sequence());
    var third = store.readAfter(second.nextRead(), 2);
    assertTrue(third.endOfSnapshot());
    failure(
        "ERASURE_LEDGER_CHECKPOINT_INVALID",
        () ->
            store.readAfter(
                new ErasureLedger.Checkpoint(UUID.randomUUID().toString(), 0, digest), 2));
    failure(
        "ERASURE_LEDGER_CHECKPOINT_INVALID",
        () -> store.readAfter(new ErasureLedger.Checkpoint(id, 2, digest), 2));
    failure(
        "ERASURE_LEDGER_BEHIND_BUSINESS",
        () -> store.readAfter(new ErasureLedger.Checkpoint(id, 10, digest), 2));
    assertThrows(IllegalArgumentException.class, () -> store.readAfter(genesis(), 101));
  }

  @Test
  void corruptedPayloadAndMissingMiddleEntryCannotBeSkippedOnRecovery() {
    store.append(request());
    store.append(request());
    store.append(request());
    String original =
        ledgerDb.queryForObject(
            "SELECT request_json FROM erasure_ledger_entries WHERE sequence_number=2",
            String.class);
    ledgerDb.update("UPDATE erasure_ledger_entries SET request_json='{}' WHERE sequence_number=2");
    failure("ERASURE_LEDGER_CORRUPT", () -> store.readAfter(genesis(), 10));
    ledgerDb.update(
        "UPDATE erasure_ledger_entries SET request_json=? WHERE sequence_number=2", original);
    ledgerDb.update("DELETE FROM erasure_ledger_entries WHERE sequence_number=2");
    failure("ERASURE_LEDGER_CORRUPT", () -> store.readAfter(genesis(), 10));
  }

  @Test
  void concurrentRetriesAndDistinctRequestsAllocateGaplessSequences() throws Exception {
    var same = request();
    var gate = new CountDownLatch(1);
    var pool = Executors.newFixedThreadPool(4);
    try {
      var futures = new ArrayList<Future<ErasureLedger.Entry>>();
      for (int i = 0; i < 4; i++)
        futures.add(
            pool.submit(
                () -> {
                  gate.await();
                  return store.append(same);
                }));
      gate.countDown();
      var ids = new HashSet<Long>();
      for (var f : futures) ids.add(f.get(30, TimeUnit.SECONDS).sequence());
      assertEquals(Set.of(1L), ids);
      futures.clear();
      for (int i = 0; i < 4; i++) futures.add(pool.submit(() -> store.append(request())));
      for (var f : futures) f.get(30, TimeUnit.SECONDS);
      assertEquals(
          List.of(1L, 2L, 3L, 4L, 5L),
          store.readAfter(genesis(), 100).entries().stream()
              .map(ErasureLedger.Entry::sequence)
              .toList());
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void lostCommitAcknowledgementCanBeRetriedWithoutDuplicateAcceptance() {
    var loseAcknowledgement = new java.util.concurrent.atomic.AtomicBoolean(true);
    var faulty =
        new org.springframework.jdbc.datasource.AbstractDataSource() {
          @Override
          public java.sql.Connection getConnection() throws java.sql.SQLException {
            var delegate = ledger.getConnection();
            return (java.sql.Connection)
                java.lang.reflect.Proxy.newProxyInstance(
                    getClass().getClassLoader(),
                    new Class<?>[] {java.sql.Connection.class},
                    (proxy, method, args) -> {
                      final Object value;
                      try {
                        value = method.invoke(delegate, args);
                      } catch (java.lang.reflect.InvocationTargetException failure) {
                        throw failure.getCause();
                      }
                      if (method.getName().equals("commit") && loseAcknowledgement.getAndSet(false))
                        throw new java.sql.SQLException("Synthetic lost commit acknowledgement");
                      return value;
                    });
          }

          @Override
          public java.sql.Connection getConnection(String username, String password)
              throws java.sql.SQLException {
            return getConnection();
          }
        };
    var unreliable = new JdbcErasureLedger(business, faulty, id, Clock.systemUTC());
    var request = request();
    failure("ERASURE_LEDGER_UNAVAILABLE", () -> unreliable.append(request));
    var recovered = unreliable.append(request);
    assertEquals(1, recovered.sequence());
    assertEquals(
        1, ledgerDb.queryForObject("SELECT COUNT(*) FROM erasure_ledger_entries", Integer.class));
    assertEquals(recovered.hash(), store.head().hash());
  }

  @Test
  void unknownColumnsFormatsAndTamperedHeadFailClosed() {
    ledgerDb.execute("ALTER TABLE erasure_ledger_entries ADD COLUMN unrelated_note TEXT");
    try {
      failure("ERASURE_LEDGER_SCHEMA_INVALID", store::head);
    } finally {
      ledgerDb.execute("ALTER TABLE erasure_ledger_entries DROP COLUMN unrelated_note");
    }
    ledgerDb.update("UPDATE erasure_ledger_head SET format_version=2");
    failure("ERASURE_LEDGER_FORMAT_UNSUPPORTED", store::head);
    ledgerDb.update("UPDATE erasure_ledger_head SET format_version=1,last_hash=?", digest);
    failure("ERASURE_LEDGER_CORRUPT", store::head);
  }

  @Test
  void invalidRequestsAndDuplicateRegistrationsAreRejected() {
    var r = request();
    assertThrows(
        IllegalArgumentException.class,
        () ->
            new ErasureLedger.Request(
                r.requestId(),
                r.tenantId(),
                r.subjectId(),
                digest,
                digest,
                digest,
                List.of(r.registrations().get(0), r.registrations().get(0))));
    assertThrows(
        IllegalArgumentException.class,
        () ->
            new ErasureLedger.Request(
                r.requestId(),
                r.tenantId(),
                r.subjectId(),
                "actor name",
                digest,
                digest,
                List.of()));
  }

  @Test
  void hiddenLedgerTablesCannotMakeTheSameCatalogIndependent() {
    var restricted =
        new org.springframework.jdbc.datasource.AbstractDataSource() {
          @Override
          public java.sql.Connection getConnection() throws java.sql.SQLException {
            var connection = ledger.getConnection();
            var metadata =
                org.mockito.Mockito.mock(
                    java.sql.DatabaseMetaData.class,
                    org.mockito.AdditionalAnswers.delegatesTo(connection.getMetaData()));
            org.mockito.Mockito.doReturn(org.mockito.Mockito.mock(java.sql.ResultSet.class))
                .when(metadata)
                .getTables(
                    org.mockito.ArgumentMatchers.any(),
                    org.mockito.ArgumentMatchers.any(),
                    org.mockito.ArgumentMatchers.any(),
                    org.mockito.ArgumentMatchers.any());
            return (java.sql.Connection)
                java.lang.reflect.Proxy.newProxyInstance(
                    getClass().getClassLoader(),
                    new Class<?>[] {java.sql.Connection.class},
                    (proxy, method, args) -> {
                      if (method.getName().equals("getMetaData")) return metadata;
                      try {
                        return method.invoke(connection, args);
                      } catch (java.lang.reflect.InvocationTargetException error) {
                        throw error.getCause();
                      }
                    });
          }

          @Override
          public java.sql.Connection getConnection(String user, String password)
              throws java.sql.SQLException {
            return getConnection();
          }
        };
    var sameCatalog = new JdbcErasureLedger(restricted, ledger, id, Clock.systemUTC());
    failure("ERASURE_LEDGER_NOT_INDEPENDENT", sameCatalog::head);
  }

  @Test
  void trailingJsonContentIsCorruption() {
    store.append(request());
    ledgerDb.update("UPDATE erasure_ledger_entries SET request_json=CONCAT(request_json,' {}')");
    failure("ERASURE_LEDGER_CORRUPT", store::head);
  }

  @Test
  @org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable(
      named = "LEDGER_STORE_TEST_URL",
      matches = "jdbc:mysql:.*")
  void nonTransactionalEngineIsRejectedBeforeAppending() {
    ledgerDb.execute("ALTER TABLE erasure_ledger_entries ENGINE=MyISAM");
    try {
      failure("ERASURE_LEDGER_SCHEMA_INVALID", () -> store.append(request()));
      assertEquals(
          0, ledgerDb.queryForObject("SELECT COUNT(*) FROM erasure_ledger_entries", Integer.class));
    } finally {
      ledgerDb.execute("ALTER TABLE erasure_ledger_entries ENGINE=InnoDB");
    }
  }

  @Test
  @org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable(
      named = "LEDGER_STORE_TEST_URL",
      matches = "jdbc:mysql:.*")
  void initializationPinsTransactionalEngineEvenWhenServerDefaultDiffers() {
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_work_admissions");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_admission_pause");
    ledgerDb.execute("DROP TABLE erasure_ledger_entries");
    ledgerDb.execute("DROP TABLE erasure_ledger_head");
    var nonTransactionalDefault =
        new org.springframework.jdbc.datasource.AbstractDataSource() {
          @Override
          public java.sql.Connection getConnection() throws java.sql.SQLException {
            var connection = ledger.getConnection();
            try (var statement = connection.createStatement()) {
              statement.execute("SET SESSION default_storage_engine=MyISAM");
            }
            return connection;
          }

          @Override
          public java.sql.Connection getConnection(String user, String password)
              throws java.sql.SQLException {
            return getConnection();
          }
        };
    ErasureLedgerBootstrap.initialize(nonTransactionalDefault, id);
    assertEquals(
        List.of("InnoDB", "InnoDB", "InnoDB", "InnoDB"),
        ledgerDb.queryForList(
            "SELECT engine FROM information_schema.tables WHERE table_schema=DATABASE() ORDER BY"
                + " table_name",
            String.class));
  }
}
