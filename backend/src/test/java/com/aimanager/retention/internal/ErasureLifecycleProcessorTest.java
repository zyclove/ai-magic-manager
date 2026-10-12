package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.*;
import org.springframework.jdbc.core.JdbcTemplate;

class ErasureLifecycleProcessorTest {
  ErasureObservationProcessorTest fixture;
  JdbcTemplate db;
  ErasureLifecycleProcessor processor;
  String tenant, subject, peer;
  static final List<String> STORES =
      List.of(
          "enrollment_proofs",
          "device_enrollments",
          "deprovision_previews",
          "deprovision_heads",
          "cleanup_receipts",
          "deprovision_operations");

  String id() {
    return UUID.randomUUID().toString();
  }

  @BeforeEach
  void setup() {
    fixture = new ErasureObservationProcessorTest();
    fixture.setup();
    db = fixture.db;
    tenant = fixture.tenant;
    subject = fixture.subject;
    peer = fixture.peer;
    processor = new ErasureLifecycleProcessor(fixture.data.jobs, db, fixture.catalog);
  }

  String enrollment(String person, String device) {
    String key = id();
    db.update(
        "INSERT INTO device_enrollments(tenant_id,id,subject_id,creator_actor_id,platform,"
            + "requested_mode,token_hash,state,created_at,expires_at,device_id,pairing_hash)"
            + " VALUES(?,?,?,'private actor','ANDROID','BYOD',?,'CONFIRMED',1,2,?,'private"
            + " pairing')",
        tenant,
        key,
        person,
        id().replace("-", "").repeat(2),
        device);
    db.update(
        "INSERT INTO enrollment_proofs(tenant_id,enrollment_id,purpose,jti_hash,consumed_at)"
            + " VALUES(?,?,'claim',?,1)",
        tenant,
        key,
        id().replace("-", "").repeat(2));
    return key;
  }

  String operation(ErasureObservationProcessorTest.Device device, String state, long deadline) {
    String key = id();
    String evidence =
        Set.of("CLEANUP_REPORTED", "CLEANUP_FAILED").contains(state)
            ? "DEVICE_REPORT_UNVERIFIED"
            : "NONE";
    db.update(
        "INSERT INTO deprovision_operations(tenant_id,id,device_id,registration_id,command_id,"
            + "key_thumbprint,compact_jws,command_hash,state,local_evidence,issued_at,absolute_not_after,updated_at)"
            + " VALUES(?,?,?,?,?,?,'private signed command',?,?,?,1,?,1)",
        tenant,
        key,
        device.id(),
        device.registration(),
        id(),
        "b".repeat(64),
        "c".repeat(64),
        state,
        evidence,
        deadline);
    return key;
  }

  void preview(ErasureObservationProcessorTest.Device device, String operation) {
    db.update(
        "INSERT INTO deprovision_previews(tenant_id,id,device_id,registration_id,device_version,"
            + "actor_key,preview_hash,expires_at,operation_id) VALUES(?,?,?,?,0,?,?,2,?)",
        tenant,
        id(),
        device.id(),
        device.registration(),
        "d".repeat(64),
        "e".repeat(64),
        operation);
  }

  void head(ErasureObservationProcessorTest.Device device, String operation) {
    db.update(
        "INSERT INTO deprovision_heads(tenant_id,device_id,registration_id,operation_id)"
            + " VALUES(?,?,?,?)",
        tenant,
        device.id(),
        device.registration(),
        operation);
  }

  void receipt(String operation) {
    db.update(
        "INSERT INTO"
            + " cleanup_receipts(tenant_id,operation_id,receipt_id,payload_hash,stage,received_at,response_json)"
            + " VALUES(?,?,?,?,'AGENT_DATA_CLEARED',1,'private response')",
        tenant,
        operation,
        id(),
        "f".repeat(64));
  }

  String graph(ErasureObservationProcessorTest.Device device) {
    enrollment(device.subject(), device.id());
    String key = operation(device, "CLEANUP_REPORTED", 2);
    preview(device, key);
    head(device, key);
    receipt(key);
    return key;
  }

  long count(String table) {
    return db.queryForObject(
        "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Long.class, tenant);
  }

  long steps() {
    return db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_steps", Long.class);
  }

  ErasureLifecycleProcessor.Result finish(ErasureRecoveryJobs.Claim claim, int limit) {
    for (int n = 0; n < 100; n++) {
      var result = processor.process(claim, limit);
      assertTrue(result.deletedRows() >= 0 && result.deletedRows() <= limit);
      assertEquals(
          claim.job().entry().request().registrations().size(),
          result.unverifiedLocalRegistrations());
      if (result.complete()) return result;
    }
    fail("Bounded lifecycle processing did not finish");
    return null;
  }

  @Test
  void sixStoresRemovedWithoutClaimingTerminalCleanupOrDeletingPeer() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    graph(target);
    graph(other);
    var claim = fixture.accept(target);
    var done = finish(claim, 1);
    assertEquals(6, done.totalRows());
    assertEquals(6, done.batches());
    for (String table : STORES) assertEquals(1, count(table), table);
    assertEquals(2, count("devices"));
    assertEquals(
        "CLAIMED", fixture.data.jobs.find(claim.job().entry().request().requestId()).state());
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, fixture.data.ledger.workState());
    var replay = processor.process(claim, 25);
    assertTrue(replay.complete());
    assertEquals(0, replay.deletedRows());
    assertEquals(done.batches(), replay.batches());
    assertEquals(1, replay.unverifiedLocalRegistrations());
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "WAITING_FOR_AGENT",
        "COMMAND_SERVED",
        "COMMAND_RECEIVED",
        "CLEANUP_FAILED",
        "CLEANUP_REPORTED",
        "CLEANUP_EXPIRED",
        "CLEANUP_CANCELLED"
      })
  void expiredServerStatesDoNotBecomeVerifiedLocalCleanup(String state) {
    var target = fixture.device(subject);
    String key = operation(target, state, 2);
    receipt(key);
    var done = finish(fixture.accept(target), 25);
    assertEquals(2, done.totalRows());
    assertEquals(1, done.unverifiedLocalRegistrations());
    assertEquals(0, count("deprovision_operations"));
    assertEquals(0, count("cleanup_receipts"));
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "WAITING_FOR_AGENT",
        "COMMAND_SERVED",
        "COMMAND_RECEIVED",
        "CLEANUP_FAILED",
        "CLEANUP_REPORTED",
        "CLEANUP_EXPIRED"
      })
  void availableWindowBlocksBeforeAnyDeletionIncludingReportedAcknowledgement(String state) {
    var target = fixture.device(subject);
    String key = graph(target);
    db.update(
        "UPDATE deprovision_operations SET state=?,absolute_not_after=? WHERE tenant_id=? AND id=?",
        state,
        Long.MAX_VALUE,
        tenant,
        key);
    fixture.data.failure(
        "ERASURE_LOCAL_CLEANUP_PENDING", () -> processor.process(fixture.accept(target), 25));
    for (String table : STORES) assertEquals(1, count(table), table);
    assertEquals(0, steps());
  }

  @Test
  void cancelledWindowCanBeRemovedButRemainsUnverified() {
    var target = fixture.device(subject);
    operation(target, "CLEANUP_CANCELLED", Long.MAX_VALUE);
    assertEquals(1, finish(fixture.accept(target), 25).totalRows());
  }

  @Test
  void noDeviceOrNoExitEvidenceDoesNotInventLocalCleanup() {
    enrollment(subject, null);
    enrollment(peer, null);
    var done = finish(fixture.accept(), 25);
    assertEquals(2, done.totalRows());
    assertEquals(0, done.unverifiedLocalRegistrations());
    assertEquals(1, count("device_enrollments"));
    assertEquals(1, count("enrollment_proofs"));
  }

  @Test
  void acceptedDeviceWithoutExitRecordsRemainsUnverified() {
    var target = fixture.device(subject);
    assertEquals(1, finish(fixture.accept(target), 25).unverifiedLocalRegistrations());
  }

  @Test
  void orphanPreviewsAndHeadsWithNoOperationCanBeRemoved() {
    var target = fixture.device(subject);
    preview(target, null);
    head(target, null);
    assertEquals(2, finish(fixture.accept(target), 25).totalRows());
  }

  @Test
  void oldRegistrationAndItsSubjectEnrollmentPreserveReenrolledPeer() {
    var target = fixture.device(subject);
    graph(target);
    var replacement = new ErasureObservationProcessorTest.Device(target.id(), id(), peer);
    db.update(
        "UPDATE devices SET registration_id=?,subject_id=? WHERE tenant_id=? AND id=?",
        replacement.registration(),
        peer,
        tenant,
        target.id());
    graph(replacement);
    assertEquals(6, finish(fixture.accept(target), 1).totalRows());
    for (String table : STORES) assertEquals(1, count(table), table);
    assertEquals(
        peer,
        db.queryForObject(
            "SELECT subject_id FROM devices WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            target.id()));
  }

  @ParameterizedTest
  @CsvSource({
    "deprovision_heads,true",
    "deprovision_heads,false",
    "deprovision_previews,true",
    "deprovision_previews,false"
  })
  void crossRegistrationLinksInEitherDirectionBlockBeforeDeletion(
      String table, boolean targetLink) {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    String targetOperation = graph(target), peerOperation = graph(other);
    db.update(
        "UPDATE " + table + " SET operation_id=? WHERE tenant_id=? AND registration_id=?",
        targetLink ? peerOperation : targetOperation,
        tenant,
        targetLink ? target.registration() : other.registration());
    fixture.data.failure(
        "ERASURE_LIFECYCLE_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    for (String store : STORES) assertEquals(2, count(store), store);
    assertEquals(0, steps());
  }

  @ParameterizedTest
  @ValueSource(strings = {"deprovision_heads", "deprovision_previews"})
  void missingOperationLinkBlocks(String table) {
    var target = fixture.device(subject);
    graph(target);
    db.update("UPDATE " + table + " SET operation_id=? WHERE tenant_id=?", id(), tenant);
    fixture.data.failure(
        "ERASURE_LIFECYCLE_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("enrollment_proofs"));
    assertEquals(0, steps());
  }

  @ParameterizedTest
  @ValueSource(strings = {"deprovision_heads", "deprovision_previews", "deprovision_operations"})
  void acceptedRegistrationUnderWrongDeviceBlocks(String table) {
    var target = fixture.device(subject);
    graph(target);
    db.update("UPDATE " + table + " SET device_id=? WHERE tenant_id=?", id(), tenant);
    fixture.data.failure(
        "ERASURE_LIFECYCLE_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("enrollment_proofs"));
    assertEquals(0, steps());
  }

  @Test
  void targetEnrollmentPointingOutsideAcceptedDevicesBlocks() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    enrollment(subject, other.id());
    fixture.data.failure(
        "ERASURE_LIFECYCLE_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("enrollment_proofs"));
    assertEquals(0, steps());
  }

  @ParameterizedTest
  @CsvSource({
    "UNKNOWN,NONE",
    "CLEANUP_REPORTED,VERIFIED",
    "CLEANUP_REPORTED,NONE",
    "CLEANUP_FAILED,NONE"
  })
  void unsupportedStateOrEvidenceBlocks(String state, String evidence) {
    var target = fixture.device(subject);
    String key = graph(target);
    db.update(
        "UPDATE deprovision_operations SET state=?,local_evidence=? WHERE tenant_id=? AND id=?",
        state,
        evidence,
        tenant,
        key);
    fixture.data.failure(
        "ERASURE_LIFECYCLE_STATE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("enrollment_proofs"));
    assertEquals(0, steps());
  }

  @Test
  void currentSubjectDeviceMissingFromManifestBlocks() {
    var target = fixture.device(subject);
    graph(target);
    fixture.data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(fixture.accept(), 25));
    assertEquals(1, count("device_enrollments"));
  }

  @Test
  void acceptedPairReassignedToAnotherSubjectBlocks() {
    var target = fixture.device(subject);
    graph(target);
    db.update(
        "UPDATE devices SET subject_id=? WHERE tenant_id=? AND id=?", peer, tenant, target.id());
    fixture.data.failure(
        "ERASURE_SCOPE_CHANGED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("device_enrollments"));
  }

  @ParameterizedTest
  @ValueSource(strings = {"device", "scope", "credential"})
  void activeDeviceAuthorityBlocks(String kind) {
    var target = fixture.device(subject);
    graph(target);
    switch (kind) {
      case "device" -> db.update("UPDATE devices SET state='ACTIVE' WHERE tenant_id=?", tenant);
      case "scope" ->
          db.update(
              "INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active)"
                  + " VALUES(?,?,?,true)",
              tenant,
              target.registration(),
              target.id());
      case "credential" ->
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
    }
    fixture.data.failure(
        "ERASURE_DEVICE_EXIT_REQUIRED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("enrollment_proofs"));
    assertEquals(0, steps());
  }

  @Test
  void exactTenantScopePreservesIdenticalDeviceAndOperationIds() {
    var target = fixture.device(subject);
    String key = graph(target);
    String otherTenant = id();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'peer','FAMILY','UTC',1)",
        otherTenant);
    db.update(
        "INSERT INTO deprovision_operations SELECT"
            + " ?,id,device_id,registration_id,command_id,key_thumbprint,compact_jws,command_hash,state,local_evidence,reason_code,issued_at,absolute_not_after,served_at,updated_at,version"
            + " FROM deprovision_operations WHERE tenant_id=? AND id=?",
        otherTenant,
        tenant,
        key);
    db.update(
        "INSERT INTO deprovision_heads SELECT ?,device_id,registration_id,operation_id FROM"
            + " deprovision_heads WHERE tenant_id=?",
        otherTenant,
        tenant);
    db.update(
        "INSERT INTO deprovision_previews SELECT"
            + " ?,id,device_id,registration_id,device_version,actor_key,preview_hash,expires_at,operation_id"
            + " FROM deprovision_previews WHERE tenant_id=?",
        otherTenant,
        tenant);
    db.update(
        "INSERT INTO cleanup_receipts SELECT"
            + " ?,operation_id,receipt_id,payload_hash,stage,received_at,response_json FROM"
            + " cleanup_receipts WHERE tenant_id=?",
        otherTenant,
        tenant);
    assertEquals(6, finish(fixture.accept(target), 25).totalRows());
    assertEquals(
        1,
        db.queryForObject(
            "SELECT COUNT(*) FROM deprovision_operations WHERE tenant_id=? AND id=?",
            Integer.class,
            otherTenant,
            key));
    for (String table : List.of("deprovision_heads", "deprovision_previews", "cleanup_receipts"))
      assertEquals(
          1,
          db.queryForObject(
              "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Integer.class, otherTenant));
  }

  @Test
  void sharedBudgetSurvivesRestartAndMultipleRegistrations() {
    var first = fixture.device(subject);
    var second = fixture.device(subject);
    String key = graph(first);
    graph(second);
    for (int n = 0; n < 30; n++) receipt(key);
    var claim = fixture.accept(first, second);
    var initial = processor.process(claim, 25);
    assertEquals(25, initial.deletedRows());
    assertFalse(initial.complete());
    processor = new ErasureLifecycleProcessor(fixture.data.jobs, db, fixture.catalog);
    assertEquals(42, finish(claim, 3).totalRows());
    for (String table : STORES) assertEquals(0, count(table), table);
  }

  @ParameterizedTest
  @ValueSource(strings = {"enrollment", "preview", "head", "operation", "receipt"})
  void doneRejectsReappearingRows(String kind) {
    var target = fixture.device(subject);
    var claim = fixture.accept(target);
    finish(claim, 25);
    switch (kind) {
      case "enrollment" -> enrollment(subject, null);
      case "preview" -> preview(target, null);
      case "head" -> head(target, null);
      case "operation" -> operation(target, "CLEANUP_CANCELLED", 2);
      case "receipt" -> receipt(operation(target, "CLEANUP_REPORTED", 2));
    }
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
  }

  @Test
  void deletionFailureRollsBackDataAndCheckpoint() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    var faulty =
        new JdbcTemplate(Objects.requireNonNull(db.getDataSource())) {
          @Override
          public int update(String sql, Object... args) {
            int count = super.update(sql, args);
            if (sql.startsWith("DELETE FROM deprovision_operations"))
              throw new IllegalStateException("after real delete");
            return count;
          }
        };
    assertThrows(
        IllegalStateException.class,
        () ->
            new ErasureLifecycleProcessor(fixture.data.jobs, faulty, fixture.catalog)
                .process(claim, 25));
    for (String table : STORES) assertEquals(1, count(table), table);
    assertEquals(0, steps());
    assertEquals(6, finish(claim, 25).totalRows());
  }

  @Test
  void leaseLossAfterDeletionRestoresExistingCheckpoint() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    assertEquals(1, processor.process(claim, 1).totalRows());
    var faulty =
        new JdbcTemplate(Objects.requireNonNull(db.getDataSource())) {
          @Override
          public int update(String sql, Object... args) {
            int count = super.update(sql, args);
            if (sql.startsWith("DELETE FROM deprovision_operations"))
              super.update("UPDATE erasure_recovery_jobs SET lease_until=1");
            return count;
          }
        };
    fixture.data.failure(
        "ERASURE_RECOVERY_LEASE_LOST",
        () ->
            new ErasureLifecycleProcessor(fixture.data.jobs, faulty, fixture.catalog)
                .process(claim, 25));
    assertEquals(1, count("device_enrollments"));
    assertEquals(1, count("deprovision_operations"));
    assertEquals(
        1L, db.queryForObject("SELECT rows_processed FROM erasure_recovery_steps", Long.class));
    assertEquals(6, finish(claim, 25).totalRows());
  }

  @Test
  void staleWorkerCannotDelete() {
    var target = fixture.device(subject);
    graph(target);
    var old = fixture.accept(target);
    db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
    var current = fixture.data.jobs.claim(id(), 300);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> processor.process(old, 25));
    assertEquals(1, count("enrollment_proofs"));
    assertEquals(0, steps());
    assertEquals(6, finish(current, 25).totalRows());
  }

  @Test
  void concurrentBatchesCountEachRowOnce() throws Exception {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    var pool = Executors.newFixedThreadPool(2);
    try {
      var a = pool.submit(() -> processor.process(claim, 3));
      var b = pool.submit(() -> processor.process(claim, 3));
      assertEquals(
          6, a.get(20, TimeUnit.SECONDS).deletedRows() + b.get(20, TimeUnit.SECONDS).deletedRows());
    } finally {
      pool.shutdownNow();
      assertTrue(pool.awaitTermination(20, TimeUnit.SECONDS));
    }
    assertEquals(6, finish(claim, 25).totalRows());
  }

  @Test
  void invalidLimitsAndCheckpointsCannotSkipRows() {
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
    db.update("UPDATE erasure_recovery_steps SET phase='DATA',rows_processed=?", Long.MAX_VALUE);
    fixture.data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(1, count("device_enrollments"));
  }

  @Test
  void unknownStoreBlocksBeforeMutation() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    db.execute("CREATE TABLE lifecycle_erasure_unreviewed(id INTEGER PRIMARY KEY)");
    try {
      assertThrows(RuntimeException.class, () -> processor.process(claim, 25));
      assertEquals(1, count("enrollment_proofs"));
      assertEquals(0, steps());
    } finally {
      db.execute("DROP TABLE lifecycle_erasure_unreviewed");
    }
  }
}
