package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.*;
import org.springframework.jdbc.core.JdbcTemplate;

class ErasureConfigurationProcessorTest implements AutoCloseable {
  ErasureObservationProcessorTest fixture;
  JdbcTemplate db;
  ErasureConfigurationProcessor processor;
  String tenant, subject, peer, policy, version, publication;
  static final List<String> STORES =
      List.of(
          "configuration_receipts",
          "configuration_streams",
          "configuration_deliveries",
          "configuration_device_heads");

  String id() {
    return UUID.randomUUID().toString();
  }

  @Override
  @AfterEach
  public void close() {
    if (fixture != null) fixture.close();
  }

  @BeforeEach
  void setup() {
    fixture = new ErasureObservationProcessorTest();
    fixture.setup();
    db = fixture.db;
    tenant = fixture.tenant;
    subject = fixture.subject;
    peer = fixture.peer;
    processor = new ErasureConfigurationProcessor(fixture.data.jobs, db, fixture.catalog);
    policy();
  }

  void policy() {
    policy = id();
    version = id();
    publication = id();
    String preview = id();
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'shared','FAMILY','[]',1,1)",
        tenant,
        policy);
    db.update(
        "INSERT INTO"
            + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at)"
            + " VALUES(?,?,?,1,?,'{}',1,100)",
        tenant,
        preview,
        policy,
        "a".repeat(64));
    db.update(
        "INSERT INTO"
            + " policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at)"
            + " VALUES(?,?,?,1,1,?,?,'FAMILY','{}',1)",
        tenant,
        version,
        policy,
        preview,
        "a".repeat(64));
    db.update(
        "INSERT INTO policy_publications(tenant_id,id,version_id,state,created_at)"
            + " VALUES(?,?,?,'ACTIVE',1)",
        tenant,
        publication,
        version);
  }

  void head(ErasureObservationProcessorTest.Device device) {
    db.update(
        "INSERT INTO configuration_device_heads(tenant_id,registration_id,device_id,next_cursor)"
            + " VALUES(?,?,?,1)",
        tenant,
        device.registration(),
        device.id());
  }

  String delivery(ErasureObservationProcessorTest.Device device, String state) {
    String key = id();
    db.update(
        "INSERT INTO"
            + " configuration_deliveries(tenant_id,id,publication_id,version_id,policy_id,registration_id,device_id,source_sequence,device_cursor,action,document_json,issued_at,delivery_expires_at,state,compact_jws)"
            + " VALUES(?,?,?,?,?,?,?,1,1,'APPLY','private document',1,100,?,'private signed copy')",
        tenant,
        key,
        publication,
        version,
        policy,
        device.registration(),
        device.id(),
        state);
    return key;
  }

  void leaf(String table, ErasureObservationProcessorTest.Device owner, String delivery) {
    if (table.equals("configuration_receipts"))
      db.update(
          "INSERT INTO"
              + " configuration_receipts(tenant_id,registration_id,id,delivery_id,request_hash,response_json,created_at)"
              + " VALUES(?,?,?,?,?,'private response',1)",
          tenant,
          owner.registration(),
          id(),
          delivery,
          "a".repeat(64));
    else
      db.update(
          "INSERT INTO configuration_streams(tenant_id,registration_id,policy_id,delivery_id)"
              + " VALUES(?,?,?,?)",
          tenant,
          owner.registration(),
          policy,
          delivery);
  }

  void graph(ErasureObservationProcessorTest.Device device) {
    head(device);
    String delivery = delivery(device, "READY");
    leaf("configuration_receipts", device, delivery);
    leaf("configuration_streams", device, delivery);
  }

  long count(String table) {
    return db.queryForObject(
        "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Long.class, tenant);
  }

  long steps() {
    return db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_steps", Long.class);
  }

  ErasureConfigurationProcessor.Result finish(ErasureRecoveryJobs.Claim claim, int limit) {
    for (int n = 0; n < 100; n++) {
      var result = processor.process(claim, limit);
      assertTrue(result.deletedRows() >= 0 && result.deletedRows() <= limit);
      if (result.complete()) return result;
    }
    fail("Bounded configuration cleanup did not finish");
    return null;
  }

  @Test
  void removesAllFourStoresAndPreservesSharedPolicyAndPeer() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    graph(target);
    graph(other);
    var claim = fixture.accept(target);
    var done = finish(claim, 1);
    assertEquals(4, done.totalRows());
    assertEquals(4, done.batches());
    for (String table : STORES) assertEquals(1, count(table), table);
    for (String table :
        List.of("policy_drafts", "policy_previews", "policy_versions", "policy_publications"))
      assertEquals(1, count(table), table);
    assertEquals(2, count("devices"));
    assertEquals(
        "CLAIMED", fixture.data.jobs.find(claim.job().entry().request().requestId()).state());
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, fixture.data.ledger.workState());
    var replay = processor.process(claim, 25);
    assertTrue(replay.complete());
    assertEquals(0, replay.deletedRows());
    assertEquals(done.batches(), replay.batches());
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "PENDING_SIGNATURE",
        "READY",
        "SERVED",
        "DEVICE_REPORTED_RECEIVED",
        "DEVICE_REPORTED_STORED",
        "DEVICE_REPORTED_REJECTED",
        "SUPERSEDED"
      })
  void allDeliveryStatesAndPrivateCopiesAreRemoved(String state) {
    var target = fixture.device(subject);
    head(target);
    delivery(target, state);
    assertEquals(2, finish(fixture.accept(target), 25).totalRows());
    for (String table : STORES) assertEquals(0, count(table), table);
  }

  @Test
  void oldGenerationPreservesReenrolledOtherSubject() {
    var current = fixture.device(peer);
    var old = new ErasureObservationProcessorTest.Device(current.id(), id(), subject);
    graph(current);
    graph(old);
    assertEquals(4, finish(fixture.accept(old), 2).totalRows());
    for (String table : STORES) assertEquals(1, count(table), table);
    assertEquals(
        current.registration(),
        db.queryForObject(
            "SELECT registration_id FROM configuration_device_heads WHERE tenant_id=?",
            String.class,
            tenant));
  }

  @Test
  void headOnlyResidueIsDeletedAndEmptyScopePreservesPeers() {
    var target = fixture.device(subject);
    head(target);
    assertEquals(1, finish(fixture.accept(target), 25).totalRows());
    assertEquals(0, count("configuration_device_heads"));
  }

  @Test
  void emptyScopeDoesNotDeleteAnotherSubject() {
    graph(fixture.device(peer));
    assertEquals(0, finish(fixture.accept(), 25).totalRows());
    for (String table : STORES) assertEquals(1, count(table), table);
  }

  @ParameterizedTest
  @CsvSource({
    "configuration_receipts,true",
    "configuration_receipts,false",
    "configuration_streams,true",
    "configuration_streams,false"
  })
  void crossRegistrationLeafInEitherDirectionBlocksBeforeDeletion(
      String table, boolean targetOwnsLeaf) {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    head(target);
    head(other);
    String own = delivery(target, "READY"), retained = delivery(other, "READY");
    leaf(table, targetOwnsLeaf ? target : other, targetOwnsLeaf ? retained : own);
    var claim = fixture.accept(target);
    fixture.data.failure("ERASURE_CONFIGURATION_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(2, count("configuration_deliveries"));
    assertEquals(1, count(table));
    assertEquals(0, steps());
  }

  @Test
  void headWithAcceptedRegistrationButWrongDeviceIsRejected() {
    var target = fixture.device(subject);
    head(target);
    db.update("UPDATE configuration_device_heads SET device_id=? WHERE tenant_id=?", id(), tenant);
    fixture.data.failure(
        "ERASURE_CONFIGURATION_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("configuration_device_heads"));
    assertEquals(0, steps());
  }

  @Test
  void deliveryWithWrongDeviceCannotBeHiddenBehindHead() {
    var target = fixture.device(subject);
    graph(target);
    db.update("UPDATE configuration_deliveries SET device_id=? WHERE tenant_id=?", id(), tenant);
    fixture.data.failure(
        "ERASURE_CONFIGURATION_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    for (String table : STORES) assertEquals(1, count(table));
    assertEquals(0, steps());
  }

  @Test
  void streamWithDifferentPolicyBlocksBeforeDeletingAnyLeaf() {
    var target = fixture.device(subject);
    graph(target);
    db.update("UPDATE configuration_streams SET policy_id=? WHERE tenant_id=?", id(), tenant);
    fixture.data.failure(
        "ERASURE_CONFIGURATION_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("configuration_receipts"));
    assertEquals(0, steps());
  }

  @Test
  void changedSubjectOrMissingAcceptedDeviceCannotProceed() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    db.update(
        "UPDATE devices SET subject_id=? WHERE tenant_id=? AND id=?", peer, tenant, target.id());
    fixture.data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(claim, 25));
    assertEquals(1, count("configuration_deliveries"));
    assertEquals(0, steps());
  }

  @Test
  void activeDeviceCannotHaveItsConfigurationRemoved() {
    var target = fixture.device(subject);
    graph(target);
    db.update("UPDATE devices SET state='ACTIVE' WHERE tenant_id=?", tenant);
    fixture.data.failure(
        "ERASURE_DEVICE_EXIT_REQUIRED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("configuration_deliveries"));
  }

  @Test
  void restartContinuesFromPersistedCheckpointWithinSharedBatchBudget() {
    var target = fixture.device(subject);
    graph(target);
    for (int n = 0; n < 30; n++) delivery(target, "SUPERSEDED");
    var claim = fixture.accept(target);
    var first = processor.process(claim, 25);
    assertEquals(25, first.deletedRows());
    assertFalse(first.complete());
    processor = new ErasureConfigurationProcessor(fixture.data.jobs, db, fixture.catalog);
    assertEquals(34, finish(claim, 3).totalRows());
    for (String table : STORES) assertEquals(0, count(table));
  }

  @Test
  void doneCannotHideReappearingRows() {
    var target = fixture.device(subject);
    var claim = fixture.accept(target);
    assertTrue(finish(claim, 25).complete());
    graph(target);
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    for (String table : STORES) assertEquals(1, count(table));
  }

  @Test
  void storageFailureAfterRealDeletionRollsBackRowsAndCheckpoint() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    var faulty =
        new JdbcTemplate(Objects.requireNonNull(db.getDataSource())) {
          @Override
          public int update(String sql, Object... args) {
            int result = super.update(sql, args);
            if (sql.startsWith("DELETE FROM configuration_deliveries"))
              throw new IllegalStateException("Injected after deletion");
            return result;
          }
        };
    var failing = new ErasureConfigurationProcessor(fixture.data.jobs, faulty, fixture.catalog);
    assertThrows(IllegalStateException.class, () -> failing.process(claim, 25));
    for (String table : STORES) assertEquals(1, count(table));
    assertEquals(0, steps());
    assertEquals(4, finish(claim, 25).totalRows());
  }

  @Test
  void leaseLossAfterDeletionRollsBackExistingCheckpoint() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    assertEquals(1, processor.process(claim, 1).totalRows());
    var faulty =
        new JdbcTemplate(Objects.requireNonNull(db.getDataSource())) {
          @Override
          public int update(String sql, Object... args) {
            int result = super.update(sql, args);
            if (sql.startsWith("DELETE FROM configuration_deliveries"))
              super.update(
                  "UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
                  claim.job().entry().request().requestId());
            return result;
          }
        };
    var failing = new ErasureConfigurationProcessor(fixture.data.jobs, faulty, fixture.catalog);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> failing.process(claim, 25));
    assertEquals(1, count("configuration_streams"));
    assertEquals(1, count("configuration_deliveries"));
    assertEquals(
        1L, db.queryForObject("SELECT rows_processed FROM erasure_recovery_steps", Long.class));
    assertEquals(4, finish(claim, 25).totalRows());
  }

  @Test
  void obsoleteWorkerCannotMutateRows() {
    var target = fixture.device(subject);
    graph(target);
    var old = fixture.accept(target);
    db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
    var current = fixture.data.jobs.claim(id(), 300);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> processor.process(old, 25));
    assertEquals(1, count("configuration_receipts"));
    assertEquals(0, steps());
    assertEquals(4, finish(current, 25).totalRows());
  }

  @Test
  void concurrentBatchesCountEveryPhysicalRowOnce() throws Exception {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    var pool = Executors.newFixedThreadPool(2);
    try {
      var a = pool.submit(() -> processor.process(claim, 2));
      var b = pool.submit(() -> processor.process(claim, 2));
      assertEquals(
          4, a.get(20, TimeUnit.SECONDS).deletedRows() + b.get(20, TimeUnit.SECONDS).deletedRows());
    } finally {
      pool.shutdownNow();
      assertTrue(pool.awaitTermination(20, TimeUnit.SECONDS));
    }
    assertEquals(4, finish(claim, 25).totalRows());
  }

  @Test
  void invalidBatchOrCheckpointCannotSkipRows() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    for (int limit : new int[] {-1, 0, 26, Integer.MAX_VALUE})
      assertThrows(IllegalArgumentException.class, () -> processor.process(claim, limit));
    assertEquals(0, steps());
    processor.process(claim, 1);
    db.update("UPDATE erasure_recovery_steps SET handler_version=2");
    fixture.data.failure("ERASURE_STEP_VERSION_UNSUPPORTED", () -> processor.process(claim, 25));
    db.update("UPDATE erasure_recovery_steps SET handler_version=1,phase='REPORTS'");
    fixture.data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    var rejectedCursor =
        assertThrows(
            org.springframework.dao.DataAccessException.class,
            () -> db.update("UPDATE erasure_recovery_steps SET phase='DATA',cursor_id=?", id()));
    var sqlFailure =
        assertInstanceOf(java.sql.SQLException.class, rejectedCursor.getMostSpecificCause());
    assertTrue(Set.of(23513, 3819).contains(sqlFailure.getErrorCode()));
    assertTrue(sqlFailure.getMessage().contains("ck_erasure_step_cursor"));
    assertEquals(
        "REPORTS", db.queryForObject("SELECT phase FROM erasure_recovery_steps", String.class));
    assertNull(db.queryForObject("SELECT cursor_id FROM erasure_recovery_steps", String.class));
    db.update(
        "UPDATE erasure_recovery_steps SET phase='DATA',cursor_id=NULL,rows_processed=?",
        Long.MAX_VALUE);
    fixture.data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(1, count("configuration_deliveries"));
  }

  @Test
  void unknownStorageBlocksBeforeDeletion() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    db.execute("CREATE TABLE configuration_erasure_unreviewed(id INTEGER PRIMARY KEY)");
    try {
      assertThrows(RuntimeException.class, () -> processor.process(claim, 25));
      assertEquals(1, count("configuration_receipts"));
      assertEquals(0, steps());
    } finally {
      db.execute("DROP TABLE configuration_erasure_unreviewed");
    }
  }

  @Test
  void deliveryUsingTargetDeviceUnderPeerHeadCannotEscapeScopeValidation() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    head(target);
    head(other);
    String key = delivery(other, "READY");
    db.update(
        "UPDATE configuration_deliveries SET device_id=? WHERE tenant_id=? AND id=?",
        target.id(),
        tenant,
        key);
    fixture.data.failure(
        "ERASURE_CONFIGURATION_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(2, count("configuration_device_heads"));
    assertEquals(1, count("configuration_deliveries"));
    assertEquals(0, steps());
  }

  @Test
  void equalOpaqueIdsInAnotherTenantRemainIntact() {
    var target = fixture.device(subject);
    graph(target);
    String original = tenant;
    tenant = id();
    String otherTenant = tenant;
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'peer','FAMILY','UTC',1)",
        tenant);
    policy();
    graph(target);
    tenant = original;
    assertEquals(4, finish(fixture.accept(target), 25).totalRows());
    for (String table : STORES) {
      assertEquals(0, count(table));
      assertEquals(
          1,
          db.queryForObject(
              "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Integer.class, otherTenant));
    }
  }

  @ParameterizedTest
  @ValueSource(booleans = {true, false})
  void activeCredentialOrScopeBlocksCleanup(boolean credential) {
    var target = fixture.device(subject);
    graph(target);
    if (credential)
      db.update(
          "INSERT INTO"
              + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
              + " VALUES(?,?,?,?,?,true,1,?)",
          id(),
          tenant,
          target.id(),
          target.registration(),
          id().replace("-", "").repeat(2),
          Long.MAX_VALUE);
    else
      db.update(
          "INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active)"
              + " VALUES(?,?,?,true)",
          tenant,
          target.registration(),
          target.id());
    fixture.data.failure(
        "ERASURE_DEVICE_EXIT_REQUIRED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("configuration_deliveries"));
    assertEquals(0, steps());
  }

  @Test
  void currentTargetDeviceMissingFromAcceptedScopeBlocks() {
    var target = fixture.device(subject);
    graph(target);
    fixture.data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(fixture.accept(), 25));
    assertEquals(1, count("configuration_deliveries"));
    assertEquals(0, steps());
  }

  @Test
  void multipleAcceptedRegistrationsShareOneBatchBudget() {
    var first = fixture.device(subject);
    var second = fixture.device(subject);
    graph(first);
    graph(second);
    assertEquals(8, finish(fixture.accept(first, second), 3).totalRows());
    for (String table : STORES) assertEquals(0, count(table));
  }
}
