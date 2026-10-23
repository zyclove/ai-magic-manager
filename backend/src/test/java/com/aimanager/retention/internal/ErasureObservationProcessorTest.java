package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;

class ErasureObservationProcessorTest implements AutoCloseable {
  ErasureRecoveryJobsTest data;
  JdbcTemplate db;
  ErasureObservationProcessor processor;
  SubjectDataCatalog catalog;
  ObjectMapper json = new ObjectMapper();
  String tenant, subject, peer, creator;

  record Device(String id, String registration, String subject) {}

  String id() {
    return UUID.randomUUID().toString();
  }

  @Override
  @AfterEach
  public void close() {
    if (data != null) data.close();
  }

  @BeforeEach
  void setup() {
    data = new ErasureRecoveryJobsTest();
    data.setup();
    db = data.db;
    catalog = new SubjectDataCatalog(db, json);
    processor = new ErasureObservationProcessor(data.jobs, db, catalog);
    tenant = id();
    subject = id();
    peer = id();
    creator = "a".repeat(64);
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at)"
            + " VALUES(?,'fixture','FAMILY','UTC',1)",
        tenant);
    for (var person : List.of(subject, peer))
      db.update(
          "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
              + " VALUES(?,?,'private','AGE_7_12',1)",
          tenant,
          person);
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role)"
            + " VALUES(?,'fixture',?,'OWNER')",
        tenant,
        creator);
  }

  Device device(String person) {
    var device = new Device(id(), id(), person);
    insertDevice(device);
    return device;
  }

  void insertDevice(Device device) {
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'private','ANDROID','fixture','REVOKED','{}',?,1)",
        tenant,
        device.id(),
        device.subject(),
        device.registration(),
        "b".repeat(64));
  }

  void observations(Device device, int batches) {
    db.update(
        "INSERT INTO"
            + " application_inventory_snapshots(tenant_id,device_id,registration_id,sequence_number,request_hash,snapshot_json,received_at)"
            + " VALUES(?,?,?,1,?,'private inventory',1)",
        tenant,
        device.id(),
        device.registration(),
        "c".repeat(64));
    db.update(
        "INSERT INTO"
            + " device_observation_settings(tenant_id,device_id,registration_id,version,inventory_enabled,usage_enabled,updated_at,last_reason)"
            + " VALUES(?,?,?,1,true,true,1,'private reason')",
        tenant,
        device.id(),
        device.registration());
    db.update(
        "INSERT INTO"
            + " usage_observation_heads(tenant_id,device_id,registration_id,sequence_number,report_id,request_hash,received_at)"
            + " VALUES(?,?,?,1,?,?,1)",
        tenant,
        device.id(),
        device.registration(),
        id(),
        "c".repeat(64));
    for (int n = 1; n <= batches; n++)
      db.update(
          "INSERT INTO"
              + " usage_observation_batches(tenant_id,device_id,registration_id,sequence_number,report_id,authorization_version,payload_json,received_at)"
              + " VALUES(?,?,?,?,?,1,'private usage',1)",
          tenant,
          device.id(),
          device.registration(),
          n,
          id());
  }

  String report(String reportId, Device... devices) throws Exception {
    String selection =
        json.writeValueAsString(
            Map.of(
                "deviceIds",
                Arrays.stream(devices).map(Device::id).sorted().toList(),
                "from",
                1,
                "to",
                2,
                "timeZone",
                "UTC",
                "period",
                "DAY",
                "scope",
                Map.of("kind", "DEVICES")));
    db.update(
        "INSERT INTO"
            + " usage_report_jobs(tenant_id,id,creator_key,member_version,state,selection_json,selection_hash,total_devices,created_at,updated_at,expires_at,next_attempt_at)"
            + " VALUES(?,?,?,0,'READY',?,?,?,1,1,100000,1)",
        tenant,
        reportId,
        creator,
        selection,
        SecretMaterial.hash(selection),
        devices.length);
    for (int n = 0; n < devices.length; n++) {
      var device = devices[n];
      db.update(
          "INSERT INTO"
              + " usage_report_parts(tenant_id,job_id,ordinal,device_id,registration_id,subject_id,authorization_version,usage_enabled,artifact)"
              + " VALUES(?,?,?,?,?,?,1,true,'private artifact')",
          tenant,
          reportId,
          n,
          device.id(),
          device.registration(),
          device.subject());
    }
    return reportId;
  }

  ErasureRecoveryJobs.Claim accept(Device... devices) {
    var request =
        new ErasureLedger.Request(
            id(),
            tenant,
            subject,
            "a".repeat(64),
            "b".repeat(64),
            "c".repeat(64),
            Arrays.stream(devices)
                .map(d -> new ErasureLedger.Registration(d.id(), d.registration()))
                .toList());
    data.ledger.append(request);
    data.jobs.reconcile(10);
    return data.jobs.claim(id(), 300);
  }

  long count(String table) {
    return db.queryForObject(
        "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Long.class, tenant);
  }

  ErasureObservationProcessor.Result finish(ErasureRecoveryJobs.Claim claim, int limit) {
    for (int n = 0; n < 100; n++) {
      var result = processor.process(claim, limit);
      if (result.complete()) return result;
    }
    fail("Bounded processor did not finish");
    return null;
  }

  @Test
  void removesAllSixStoresAndSharedCopiesWhilePreservingPeerSources() throws Exception {
    var target = device(subject);
    var other = device(peer);
    observations(target, 3);
    observations(other, 2);
    String shared = report(id(), target, other),
        own = report(id(), target),
        retained = report(id(), other);
    var claim = accept(target);
    var result = finish(claim, 2);
    assertEquals(11, result.totalRows());
    assertEquals(2, count("usage_observation_batches"));
    for (var table :
        List.of(
            "usage_observation_heads",
            "application_inventory_snapshots",
            "device_observation_settings",
            "usage_report_jobs",
            "usage_report_parts")) assertEquals(1, count(table), table);
    assertEquals(
        retained,
        db.queryForObject(
            "SELECT id FROM usage_report_jobs WHERE tenant_id=?", String.class, tenant));
    assertEquals("DONE", result.phase());
    assertEquals("CLAIMED", data.jobs.find(claim.job().entry().request().requestId()).state());
    var replay = processor.process(claim, 2);
    assertTrue(replay.complete());
    assertEquals(0, replay.deletedRows());
    assertEquals(result.totalRows(), replay.totalRows());
    assertEquals(result.batches(), replay.batches());
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, data.ledger.workState());
  }

  @Test
  void oldGenerationReportIsRemovedButReenrolledOtherSubjectDeviceIsPreserved() throws Exception {
    var current = device(peer);
    observations(current, 2);
    var old = new Device(current.id(), id(), subject);
    report(id(), old);
    report(id(), current);
    var result = finish(accept(old), 3);
    assertEquals(2, result.totalRows());
    assertEquals(2, count("usage_observation_batches"));
    assertEquals(1, count("usage_report_jobs"));
    assertEquals(
        current.registration(),
        db.queryForObject(
            "SELECT registration_id FROM usage_report_parts WHERE tenant_id=?",
            String.class,
            tenant));
  }

  @Test
  void missingCurrentRegistrationIsRejectedBeforeAnyDeletion() {
    var target = device(subject);
    observations(target, 1);
    data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(accept(), 25));
    assertEquals(1, count("usage_observation_batches"));
  }

  @Test
  void missingHistoricalRegistrationIsRejected() throws Exception {
    report(id(), new Device(id(), id(), subject));
    data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(accept(), 25));
    assertEquals(1, count("usage_report_jobs"));
  }

  @Test
  void sameRegistrationBoundToOtherSubjectIsRejected() {
    var other = device(peer);
    observations(other, 1);
    data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(accept(other), 25));
    assertEquals(1, count("usage_observation_batches"));
  }

  @Test
  void corruptLaterReportRollsBackEarlierReportDeletionAndCheckpoint() throws Exception {
    var target = device(subject);
    report("00000000-0000-0000-0000-000000000001", target);
    String bad = report("00000000-0000-0000-0000-000000000002", target);
    db.update(
        "UPDATE usage_report_jobs SET selection_hash=? WHERE tenant_id=? AND id=?",
        "d".repeat(64),
        tenant,
        bad);
    data.failure("ERASURE_REPORT_SCOPE_CORRUPT", () -> processor.process(accept(target), 25));
    assertEquals(2, count("usage_report_jobs"));
    assertEquals(2, count("usage_report_parts"));
    assertEquals(0, db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_steps", Long.class));
  }

  @Test
  void missingReportPartIsNotMisreportedAsNoTargetData() throws Exception {
    var target = device(subject);
    String report = report(id(), target);
    db.update("DELETE FROM usage_report_parts WHERE tenant_id=? AND job_id=?", tenant, report);
    data.failure("ERASURE_REPORT_SCOPE_CORRUPT", () -> processor.process(accept(target), 25));
    assertEquals(1, count("usage_report_jobs"));
  }

  @Test
  void batchLimitBoundsObservationRowsAndRejectsInvalidLimits() {
    var target = device(subject);
    observations(target, 5);
    var claim = accept(target);
    assertThrows(IllegalArgumentException.class, () -> processor.process(claim, 0));
    assertThrows(IllegalArgumentException.class, () -> processor.process(claim, 26));
    assertEquals("DATA", processor.process(claim, 2).phase());
    var next = processor.process(claim, 2);
    assertEquals(2, next.deletedRows());
    assertFalse(next.complete());
    assertEquals(3, count("usage_observation_batches"));
    assertEquals(8, finish(claim, 2).totalRows());
  }

  @Test
  void checkpointWriteFailureRollsBackDeletedRows() {
    var target = device(subject);
    observations(target, 1);
    var claim = accept(target);
    processor.process(claim, 25);
    var failing =
        new JdbcTemplate(data.business) {
          @Override
          public int update(String sql, Object... args) {
            if (sql.startsWith("UPDATE erasure_recovery_steps"))
              throw new org.springframework.dao.DataAccessResourceFailureException(
                  "synthetic checkpoint failure");
            return super.update(sql, args);
          }
        };
    var faulty = new ErasureObservationProcessor(data.jobs, failing, catalog);
    data.failure("ERASURE_RECOVERY_UNAVAILABLE", () -> faulty.process(claim, 25));
    assertEquals(1, count("usage_observation_batches"));
    assertEquals(
        0L, db.queryForObject("SELECT rows_processed FROM erasure_recovery_steps", Long.class));
  }

  @Test
  void unsupportedCheckpointVersionCannotContinue() {
    var claim = accept();
    processor.process(claim, 25);
    db.update("UPDATE erasure_recovery_steps SET handler_version=99");
    data.failure("ERASURE_STEP_VERSION_UNSUPPORTED", () -> processor.process(claim, 25));
  }

  @Test
  void completedStepCannotHideReappearedData() {
    var target = device(subject);
    var claim = accept(target);
    finish(claim, 25);
    observations(target, 1);
    data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    assertEquals(1, count("usage_observation_batches"));
  }

  @Test
  void identicalDeviceAndSubjectIdsInAnotherTenantAreNeverDeleted() throws Exception {
    var target = device(subject);
    observations(target, 1);
    report(id(), target);
    String original = tenant, otherTenant = id();
    tenant = otherTenant;
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
        creator);
    insertDevice(target);
    observations(target, 1);
    report(id(), target);
    tenant = original;
    assertEquals(6, finish(accept(target), 25).totalRows());
    tenant = otherTenant;
    for (var table :
        List.of(
            "usage_observation_batches",
            "usage_observation_heads",
            "application_inventory_snapshots",
            "device_observation_settings",
            "usage_report_jobs",
            "usage_report_parts")) assertEquals(1, count(table), table);
  }

  @Test
  void aNewProcessorResumesPersistedProgressWithoutRepeatingDeletion() throws Exception {
    var target = device(subject);
    observations(target, 3);
    report(id(), target);
    var claim = accept(target);
    assertEquals(2, processor.process(claim, 25).deletedRows());
    processor =
        new ErasureObservationProcessor(data.jobs, new JdbcTemplate(data.business), catalog);
    var finished = finish(claim, 2);
    assertEquals(8, finished.totalRows());
    assertEquals(0, count("usage_observation_batches"));
  }

  @Test
  void concurrentBatchesSerializeOnTheJobAndNeverDoubleCount() throws Exception {
    var target = device(subject);
    observations(target, 2);
    report(id(), target);
    var claim = accept(target);
    var start = new CountDownLatch(1);
    var executor = Executors.newFixedThreadPool(2);
    try {
      var a =
          executor.submit(
              () -> {
                start.await();
                return finish(claim, 1);
              });
      var b =
          executor.submit(
              () -> {
                start.await();
                return finish(claim, 1);
              });
      start.countDown();
      assertEquals(7, a.get(15, TimeUnit.SECONDS).totalRows());
      assertEquals(7, b.get(15, TimeUnit.SECONDS).totalRows());
      assertEquals(0, count("usage_report_parts"));
    } finally {
      executor.shutdownNow();
    }
  }

  @Test
  void matchingReportHashCannotConcealDifferentPartSelection() throws Exception {
    var target = device(subject);
    var other = device(peer);
    String report = report(id(), target);
    String selection =
        json.writeValueAsString(
            Map.of("deviceIds", List.of(other.id()), "scope", Map.of("kind", "DEVICES")));
    db.update(
        "UPDATE usage_report_jobs SET selection_json=?,selection_hash=? WHERE tenant_id=? AND id=?",
        selection,
        SecretMaterial.hash(selection),
        tenant,
        report);
    data.failure("ERASURE_REPORT_SCOPE_CORRUPT", () -> processor.process(accept(target), 25));
    assertEquals(1, count("usage_report_parts"));
  }

  @Test
  void unreviewedStorageStopsDeletionBeforeAnyRowsChange() {
    var target = device(subject);
    observations(target, 1);
    var claim = accept(target);
    db.execute("CREATE TABLE unreviewed_erasure_probe(id INTEGER)");
    try {
      var rejected =
          assertThrows(
              com.aimanager.shared.DomainException.class, () -> processor.process(claim, 25));
      assertEquals("ERASURE_SCHEMA_REVIEW_REQUIRED", rejected.errorCode());
      assertEquals(1, count("usage_observation_batches"));
    } finally {
      db.execute("DROP TABLE unreviewed_erasure_probe");
    }
  }

  @Test
  void exhaustedProgressCounterCannotWrapOrDeleteMoreData() {
    var target = device(subject);
    observations(target, 1);
    var claim = accept(target);
    processor.process(claim, 25);
    db.update("UPDATE erasure_recovery_steps SET rows_processed=?", Long.MAX_VALUE);
    data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(1, count("usage_observation_batches"));
  }
}
