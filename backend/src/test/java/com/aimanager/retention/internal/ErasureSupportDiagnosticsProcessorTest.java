package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;

class ErasureSupportDiagnosticsProcessorTest {
  ErasureObservationProcessorTest fixture;
  JdbcTemplate db;
  ErasureSupportDiagnosticsProcessor processor;
  String tenant, subject, peer;

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
    processor = new ErasureSupportDiagnosticsProcessor(fixture.data.jobs, db, fixture.catalog);
  }

  String grant(ErasureObservationProcessorTest.Device device) {
    String pairing = id(), grant = id();
    db.update(
        "INSERT INTO"
            + " support_pairing_requests(id,recipient_actor_id,recipient_key,display_name,verified_email,code_hash,state,created_at,expires_at,updated_at)"
            + " VALUES(?,'support',?,'support"
            + " person','support@example.invalid',?,'CONSUMED',1,100,1)",
        pairing,
        "b".repeat(64),
        id().replace("-", "").repeat(2));
    db.update(
        "INSERT INTO"
            + " support_grants(id,tenant_id,device_id,subject_id,registration_id,creator_actor_id,creator_key,creator_member_version,recipient_actor_id,recipient_key,pairing_id,type_mask,state,created_at,expires_at,updated_at)"
            + " VALUES(?,?,?,?,?,'fixture',?,0,'support',?,?,7,'ACTIVE',1,100,1)",
        grant,
        tenant,
        device.id(),
        device.subject(),
        device.registration(),
        fixture.creator,
        "b".repeat(64),
        pairing);
    return grant;
  }

  String diagnostic(ErasureObservationProcessorTest.Device device, String grant, String state) {
    String id = id();
    db.update(
        "INSERT INTO"
            + " diagnostic_packages(id,tenant_id,requester_actor_id,requester_key,authority_actor_id,authority_key,authority_version,access_mode,grant_id,grant_version,device_id,subject_id,registration_id,type_mask,state,created_at,updated_at,expires_at,next_attempt_at,next_validation_at,artifact)"
            + " VALUES(?,?,'fixture',?,'fixture',?,0,?,?,?, ?,?,?,7,?,1,1,100,1,1,'private"
            + " encrypted artifact')",
        id,
        tenant,
        fixture.creator,
        fixture.creator,
        grant == null ? "ADMIN" : "SUPPORT_GRANT",
        grant,
        grant == null ? null : 0L,
        device.id(),
        device.subject(),
        device.registration(),
        state);
    return id;
  }

  long count(String table) {
    return fixture.count(table);
  }

  ErasureSupportDiagnosticsProcessor.Result finish(ErasureRecoveryJobs.Claim claim, int limit) {
    for (int n = 0; n < 100; n++) {
      var result = processor.process(claim, limit);
      assertTrue(result.deletedRows() <= limit);
      if (result.complete()) return result;
    }
    fail("Processor did not finish bounded work");
    return null;
  }

  @Test
  void deletesArtifactsBeforeGrantsAndPreservesPeerAndSupportAccount() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    String ownGrant = grant(target), peerGrant = grant(other);
    diagnostic(target, ownGrant, "READY");
    diagnostic(target, null, "RUNNING");
    String retained = diagnostic(other, peerGrant, "READY");
    long pairings = db.queryForObject("SELECT COUNT(*) FROM support_pairing_requests", Long.class);
    var claim = fixture.accept(target);
    var result = finish(claim, 1);
    assertEquals(3, result.totalRows());
    assertEquals(1, count("support_grants"));
    assertEquals(1, count("diagnostic_packages"));
    assertEquals(
        retained,
        db.queryForObject(
            "SELECT id FROM diagnostic_packages WHERE tenant_id=?", String.class, tenant));
    assertEquals(
        pairings, db.queryForObject("SELECT COUNT(*) FROM support_pairing_requests", Long.class));
    assertEquals(
        "CLAIMED", fixture.data.jobs.find(claim.job().entry().request().requestId()).state());
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, fixture.data.ledger.workState());
    var replay = processor.process(claim, 1);
    assertTrue(replay.complete());
    assertEquals(0, replay.deletedRows());
    assertEquals(result.totalRows(), replay.totalRows());
    assertEquals(result.batches(), replay.batches());
  }

  @Test
  void historicalGenerationIsRemovedWithoutTouchingReenrolledPeerDevice() {
    var current = fixture.device(peer);
    var old = new ErasureObservationProcessorTest.Device(current.id(), id(), subject);
    String oldGrant = grant(old);
    diagnostic(old, oldGrant, "EXPIRED");
    String retained = diagnostic(current, null, "READY");
    assertEquals(2, finish(fixture.accept(old), 25).totalRows());
    assertEquals(
        retained,
        db.queryForObject(
            "SELECT id FROM diagnostic_packages WHERE tenant_id=?", String.class, tenant));
    assertEquals(
        current.registration(),
        db.queryForObject(
            "SELECT registration_id FROM devices WHERE tenant_id=?", String.class, tenant));
  }

  @Test
  void missingHistoricalGenerationRejectsBeforeDeletingAnyArtifact() {
    var target = fixture.device(subject);
    diagnostic(target, null, "READY");
    var old = new ErasureObservationProcessorTest.Device(target.id(), id(), subject);
    grant(old);
    fixture.data.failure(
        "ERASURE_SCOPE_CHANGED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("diagnostic_packages"));
    assertEquals(1, count("support_grants"));
  }

  @Test
  void targetDiagnosticCannotBorrowAnotherSubjectsGrant() {
    var target = fixture.device(subject);
    String foreignGrant = grant(fixture.device(peer));
    diagnostic(target, foreignGrant, "READY");
    fixture.data.failure(
        "ERASURE_SUPPORT_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("diagnostic_packages"));
  }

  @Test
  void retainedDiagnosticCannotReferenceGrantBeingErased() {
    var target = fixture.device(subject);
    String ownGrant = grant(target);
    diagnostic(fixture.device(peer), ownGrant, "READY");
    fixture.data.failure(
        "ERASURE_SUPPORT_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("support_grants"));
  }

  @Test
  void allStatesAreRemovedWithinThePhysicalRowLimit() {
    var target = fixture.device(subject);
    for (String state :
        List.of("QUEUED", "RUNNING", "READY", "CANCELLED", "EXPIRED", "REVOKED", "FAILED"))
      diagnostic(target, null, state);
    var claim = fixture.accept(target);
    var first = processor.process(claim, 3);
    assertEquals(3, first.deletedRows());
    assertEquals(4, count("diagnostic_packages"));
    processor = new ErasureSupportDiagnosticsProcessor(fixture.data.jobs, db, fixture.catalog);
    assertEquals(7, finish(claim, 3).totalRows());
  }

  @Test
  void completedStepRejectsNewTargetDataWithoutChangingItsReceipt() {
    var target = fixture.device(subject);
    var claim = fixture.accept(target);
    assertTrue(finish(claim, 25).complete());
    diagnostic(target, null, "QUEUED");
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    assertEquals(1, count("diagnostic_packages"));
  }

  @Test
  void missingCurrentDeviceIsRejectedEvenWhenNoDiagnosticsExist() {
    fixture.device(subject);
    fixture.data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(fixture.accept(), 25));
  }

  @Test
  void acceptedRegistrationCannotBeReassignedToAnotherSubject() {
    var target = fixture.device(subject);
    diagnostic(target, null, "READY");
    var claim = fixture.accept(target);
    db.update(
        "UPDATE devices SET subject_id=? WHERE tenant_id=? AND id=?", peer, tenant, target.id());
    fixture.data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(claim, 25));
    assertEquals(1, count("diagnostic_packages"));
  }

  @Test
  void sameSubjectDifferentGrantRegistrationIsNotSilentlyAccepted() {
    var target = fixture.device(subject);
    var old = new ErasureObservationProcessorTest.Device(target.id(), id(), subject);
    diagnostic(target, grant(old), "READY");
    fixture.data.failure(
        "ERASURE_SUPPORT_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target, old), 25));
    assertEquals(1, count("diagnostic_packages"));
  }

  @Test
  void sameSubjectDifferentDeviceGrantIsRejected() {
    var target = fixture.device(subject);
    var second = fixture.device(subject);
    diagnostic(target, grant(second), "READY");
    fixture.data.failure(
        "ERASURE_SUPPORT_SCOPE_CORRUPT",
        () -> processor.process(fixture.accept(target, second), 25));
    assertEquals(1, count("diagnostic_packages"));
  }

  @Test
  void physicalLimitIsSharedAcrossArtifactsAndGrants() {
    var target = fixture.device(subject);
    String grant = grant(target);
    for (int n = 0; n < 26; n++) diagnostic(target, grant, "READY");
    var claim = fixture.accept(target);
    var first = processor.process(claim, 25);
    assertEquals(25, first.deletedRows());
    assertEquals(1, count("diagnostic_packages"));
    assertEquals(1, count("support_grants"));
    var last = processor.process(claim, 25);
    assertTrue(last.complete());
    assertEquals(2, last.deletedRows());
    assertEquals(27, last.totalRows());
  }

  @Test
  void storageFailureAfterDeletionRollsBackDataAndNewCheckpoint() {
    var target = fixture.device(subject);
    String grant = grant(target);
    diagnostic(target, grant, "READY");
    var claim = fixture.accept(target);
    var faulty =
        new JdbcTemplate(fixture.data.business) {
          @Override
          public int update(String sql, Object... values) {
            int changed = super.update(sql, values);
            if (sql.startsWith("DELETE FROM diagnostic_packages"))
              throw new IllegalStateException("Injected storage failure after actual delete");
            return changed;
          }
        };
    var worker = new ErasureSupportDiagnosticsProcessor(fixture.data.jobs, faulty, fixture.catalog);
    assertThrows(IllegalStateException.class, () -> worker.process(claim, 25));
    assertEquals(1, count("diagnostic_packages"));
    assertEquals(1, count("support_grants"));
    assertEquals(
        0,
        db.queryForObject(
            "SELECT COUNT(*) FROM erasure_recovery_steps WHERE request_id=?",
            Integer.class,
            claim.job().entry().request().requestId()));
    assertEquals(2, finish(claim, 25).totalRows());
  }

  @Test
  void leaseLostDuringBatchRollsBackDeletionAndCheckpoint() {
    var target = fixture.device(subject);
    diagnostic(target, null, "READY");
    var claim = fixture.accept(target);
    var expiring =
        new JdbcTemplate(fixture.data.business) {
          @Override
          public int update(String sql, Object... values) {
            int changed = super.update(sql, values);
            if (sql.startsWith("DELETE FROM diagnostic_packages"))
              db.update(
                  "UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
                  claim.job().entry().request().requestId());
            return changed;
          }
        };
    var worker =
        new ErasureSupportDiagnosticsProcessor(fixture.data.jobs, expiring, fixture.catalog);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> worker.process(claim, 25));
    assertEquals(1, count("diagnostic_packages"));
    assertEquals(
        0,
        db.queryForObject(
            "SELECT COUNT(*) FROM erasure_recovery_steps WHERE request_id=?",
            Integer.class,
            claim.job().entry().request().requestId()));
  }

  @Test
  void oldWorkerCannotDeleteAfterReplacementClaim() {
    var target = fixture.device(subject);
    diagnostic(target, null, "READY");
    var claim = fixture.accept(target);
    db.update(
        "UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
        claim.job().entry().request().requestId());
    var next = fixture.data.jobs.claim(id(), 300);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> processor.process(claim, 25));
    assertEquals(1, count("diagnostic_packages"));
    assertEquals(1, finish(next, 25).totalRows());
  }

  @Test
  void concurrentCallsOnSameClaimCannotDoubleCount() throws Exception {
    var target = fixture.device(subject);
    for (int n = 0; n < 7; n++) diagnostic(target, null, "READY");
    var claim = fixture.accept(target);
    var executor = Executors.newFixedThreadPool(2);
    try {
      var first = executor.submit(() -> processor.process(claim, 3));
      var second = executor.submit(() -> processor.process(claim, 3));
      assertEquals(
          6,
          first.get(15, TimeUnit.SECONDS).deletedRows()
              + second.get(15, TimeUnit.SECONDS).deletedRows());
      assertEquals(1, count("diagnostic_packages"));
      assertEquals(7, finish(claim, 3).totalRows());
    } finally {
      executor.shutdownNow();
    }
  }

  @Test
  void invalidBatchSizeCannotStartDeletion() {
    var target = fixture.device(subject);
    diagnostic(target, null, "READY");
    var claim = fixture.accept(target);
    for (int size : new int[] {-1, 0, 26, Integer.MAX_VALUE})
      assertThrows(IllegalArgumentException.class, () -> processor.process(claim, size));
    assertEquals(1, count("diagnostic_packages"));
  }

  @Test
  void futureHandlerVersionBlocksFurtherDeletion() {
    var target = fixture.device(subject);
    diagnostic(target, null, "READY");
    diagnostic(target, null, "READY");
    var claim = fixture.accept(target);
    processor.process(claim, 1);
    db.update(
        "UPDATE erasure_recovery_steps SET handler_version=2 WHERE request_id=?",
        claim.job().entry().request().requestId());
    fixture.data.failure("ERASURE_STEP_VERSION_UNSUPPORTED", () -> processor.process(claim, 25));
    assertEquals(1, count("diagnostic_packages"));
  }

  @Test
  void exhaustedCountersCannotOverflowOrDeleteFurtherRows() {
    var target = fixture.device(subject);
    diagnostic(target, null, "READY");
    diagnostic(target, null, "READY");
    var claim = fixture.accept(target);
    processor.process(claim, 1);
    String request = claim.job().entry().request().requestId();
    db.update(
        "UPDATE erasure_recovery_steps SET rows_processed=? WHERE request_id=?",
        Long.MAX_VALUE,
        request);
    fixture.data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    db.update(
        "UPDATE erasure_recovery_steps SET rows_processed=1,batches_processed=? WHERE request_id=?",
        Long.MAX_VALUE,
        request);
    fixture.data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(1, count("diagnostic_packages"));
  }

  @Test
  void unexpectedStepPhaseDoesNotSkipRemainingData() {
    var target = fixture.device(subject);
    diagnostic(target, null, "READY");
    diagnostic(target, null, "READY");
    var claim = fixture.accept(target);
    processor.process(claim, 1);
    db.update(
        "UPDATE erasure_recovery_steps SET phase='REPORTS',cursor_id=? WHERE request_id=?",
        id(),
        claim.job().entry().request().requestId());
    fixture.data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(1, count("diagnostic_packages"));
  }

  @Test
  void unreviewedStorageCannotBeIgnored() {
    var target = fixture.device(subject);
    diagnostic(target, null, "READY");
    var claim = fixture.accept(target);
    db.execute("CREATE TABLE unreviewed_support_copy(id VARCHAR(36))");
    try {
      assertThrows(com.aimanager.shared.DomainException.class, () -> processor.process(claim, 25));
      assertEquals(1, count("diagnostic_packages"));
    } finally {
      db.execute("DROP TABLE unreviewed_support_copy");
    }
  }

  @Test
  void identicalOpaqueScopeInAnotherTenantRemainsUntouched() {
    var target = fixture.device(subject);
    diagnostic(target, grant(target), "READY");
    String home = tenant;
    tenant = id();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'other','FAMILY','UTC',1)",
        tenant);
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'other','AGE_7_12',1)",
        tenant,
        subject);
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role)"
            + " VALUES(?,'fixture',?,'OWNER')",
        tenant,
        fixture.creator);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'other','ANDROID','fixture','REVOKED','{}',?,1)",
        tenant,
        target.id(),
        subject,
        target.registration(),
        "b".repeat(64));
    String retainedGrant = grant(target),
        retainedPackage = diagnostic(target, retainedGrant, "READY");
    String otherTenant = tenant;
    tenant = home;
    assertEquals(2, finish(fixture.accept(target), 25).totalRows());
    assertEquals(
        retainedGrant,
        db.queryForObject(
            "SELECT id FROM support_grants WHERE tenant_id=?", String.class, otherTenant));
    assertEquals(
        retainedPackage,
        db.queryForObject(
            "SELECT id FROM diagnostic_packages WHERE tenant_id=?", String.class, otherTenant));
  }

  @Test
  void completedStepAlsoRejectsReappearingSupportGrant() {
    var target = fixture.device(subject);
    var claim = fixture.accept(target);
    assertTrue(finish(claim, 25).complete());
    grant(target);
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    assertEquals(1, count("support_grants"));
  }

  @Test
  void retainedTenantHeadsAndSupportPairingHistorySurvive() {
    var target = fixture.device(subject);
    String grant = grant(target);
    String pairing =
        db.queryForObject("SELECT pairing_id FROM support_grants WHERE id=?", String.class, grant);
    String event = id();
    db.update(
        "INSERT INTO support_pairing_events(id,request_id,actor_key,action,occurred_at)"
            + " VALUES(?,?,?,'CONSUMED',1)",
        event,
        pairing,
        fixture.creator);
    db.update("INSERT INTO diagnostic_package_heads(tenant_id) VALUES(?)", tenant);
    db.update("INSERT INTO support_grant_heads(tenant_id) VALUES(?)", tenant);
    diagnostic(target, grant, "READY");
    assertEquals(2, finish(fixture.accept(target), 25).totalRows());
    assertEquals(1, count("diagnostic_package_heads"));
    assertEquals(1, count("support_grant_heads"));
    assertEquals(
        pairing,
        db.queryForObject(
            "SELECT request_id FROM support_pairing_events WHERE id=?", String.class, event));
  }
}
