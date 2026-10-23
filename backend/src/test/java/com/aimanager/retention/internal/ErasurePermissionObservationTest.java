package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;

class ErasurePermissionObservationTest implements AutoCloseable {
  private static final List<String> STORES =
      List.of(
          "device_permission_observation_snapshots",
          "device_permission_observation_rate",
          "device_permission_observation_settings");
  ErasureObservationProcessorTest fixture;
  JdbcTemplate db;

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
  }

  void permissions(ErasureObservationProcessorTest.Device device, boolean enabled) {
    permissionStore(STORES.get(0), device, enabled);
    permissionStore(STORES.get(1), device, enabled);
    permissionStore(STORES.get(2), device, enabled);
  }

  void permissionStore(
      String table, ErasureObservationProcessorTest.Device device, boolean enabled) {
    switch (table) {
      case "device_permission_observation_settings" ->
          db.update(
              "INSERT INTO"
                  + " device_permission_observation_settings(tenant_id,device_id,registration_id,version,enabled,updated_at,last_reason)"
                  + " VALUES(?,?,?,1,?,1,'private reason')",
              fixture.tenant,
              device.id(),
              device.registration(),
              enabled);
      case "device_permission_observation_snapshots" ->
          db.update(
              "INSERT INTO"
                  + " device_permission_observation_snapshots(tenant_id,device_id,registration_id,sequence_number,report_id,request_hash,authorization_version,package_name,profile,snapshot_json,received_at)"
                  + " VALUES(?,?,?,1,?,?,1,'app.private','PERSONAL','private permissions',1)",
              fixture.tenant,
              device.id(),
              device.registration(),
              fixture.id(),
              "c".repeat(64));
      case "device_permission_observation_rate" ->
          db.update(
              "INSERT INTO"
                  + " device_permission_observation_rate(tenant_id,device_id,registration_id,window_started_at,report_count)"
                  + " VALUES(?,?,?,1,3)",
              fixture.tenant,
              device.id(),
              device.registration());
      default -> throw new IllegalArgumentException();
    }
  }

  @ParameterizedTest
  @ValueSource(booleans = {true, false})
  void removesPermissionDataRegardlessOfConsentAndPreservesPeer(boolean enabled) {
    var target = fixture.device(fixture.subject);
    var peer = fixture.device(fixture.peer);
    permissions(target, enabled);
    permissions(peer, true);
    fixture.catalog.requireCurrentSchema();
    var claim = fixture.accept(target);
    var result = fixture.finish(claim, 2);
    assertEquals(3, result.totalRows());
    for (var table : STORES) {
      assertEquals(1, fixture.count(table));
      assertEquals(
          peer.id(),
          db.queryForObject(
              "SELECT device_id FROM " + table + " WHERE tenant_id=?",
              String.class,
              fixture.tenant));
    }
    assertEquals(
        "CLAIMED", fixture.data.jobs.find(claim.job().entry().request().requestId()).state());
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, fixture.data.ledger.workState());
    assertEquals(0, fixture.processor.process(claim, 2).deletedRows());
  }

  @Test
  void sharesPhysicalRowLimitAcrossExistingAndPermissionStoresAndResumes() {
    var target = fixture.device(fixture.subject);
    fixture.observations(target, 21); // 24 existing rows, then 3 permission rows.
    permissions(target, true);
    var claim = fixture.accept(target);
    assertEquals("DATA", fixture.processor.process(claim, 25).phase());
    var first = fixture.processor.process(claim, 25);
    assertEquals(25, first.deletedRows());
    assertFalse(first.complete());
    assertEquals(2, STORES.stream().mapToLong(fixture::count).sum());
    fixture.processor =
        new ErasureObservationProcessor(
            fixture.data.jobs, new JdbcTemplate(fixture.data.business), fixture.catalog);
    var last = fixture.processor.process(claim, 25);
    assertEquals(2, last.deletedRows());
    assertEquals(27, last.totalRows());
    assertTrue(last.complete());
    for (var table : STORES) assertEquals(0, fixture.count(table));
  }

  @Test
  void oldRegistrationNeverDeletesReenrolledPeerPermissionData() {
    var peer = fixture.device(fixture.peer);
    permissions(peer, true);
    var old = new ErasureObservationProcessorTest.Device(peer.id(), fixture.id(), fixture.subject);
    assertEquals(0, fixture.finish(fixture.accept(old), 25).totalRows());
    for (var table : STORES) assertEquals(1, fixture.count(table));
  }

  @Test
  void identicalIdsInAnotherTenantArePreserved() {
    var target = fixture.device(fixture.subject);
    permissions(target, true);
    String original = fixture.tenant, other = fixture.id();
    fixture.tenant = other;
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'other','FAMILY','UTC',1)",
        other);
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'other','AGE_7_12',1)",
        other,
        fixture.subject);
    fixture.insertDevice(target);
    permissions(target, true);
    fixture.tenant = original;
    assertEquals(3, fixture.finish(fixture.accept(target), 25).totalRows());
    for (var table : STORES) assertEquals(0, fixture.count(table));
    fixture.tenant = other;
    for (var table : STORES) assertEquals(1, fixture.count(table));
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "device_permission_observation_snapshots",
        "device_permission_observation_rate",
        "device_permission_observation_settings"
      })
  void eachStoreIsRemovedWithoutRequiringOtherPermissionRows(String table) {
    var target = fixture.device(fixture.subject);
    permissionStore(table, target, false);
    assertEquals(1, fixture.finish(fixture.accept(target), 1).totalRows());
    assertEquals(0, fixture.count(table));
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "device_permission_observation_snapshots",
        "device_permission_observation_rate",
        "device_permission_observation_settings"
      })
  void doneRecheckRejectsEachReappearedPermissionStore(String table) {
    var target = fixture.device(fixture.subject);
    var claim = fixture.accept(target);
    fixture.finish(claim, 25);
    permissionStore(table, target, false);
    fixture.data.failure(
        "ERASURE_STEP_RECHECK_REQUIRED", () -> fixture.processor.process(claim, 25));
    assertEquals(1, fixture.count(table));
  }

  @Test
  void checkpointFailureAfterRealDeletesRollsBackEveryPermissionStore() {
    var target = fixture.device(fixture.subject);
    permissions(target, true);
    var claim = fixture.accept(target);
    fixture.processor.process(claim, 25);
    var failingDb =
        new JdbcTemplate(fixture.data.business) {
          @Override
          public int update(String sql, Object... args) {
            if (sql.startsWith("UPDATE erasure_recovery_steps")) {
              for (var table : STORES) assertEquals(0, fixture.count(table));
              throw new org.springframework.dao.DataAccessResourceFailureException(
                  "synthetic checkpoint failure");
            }
            return super.update(sql, args);
          }
        };
    var failing = new ErasureObservationProcessor(fixture.data.jobs, failingDb, fixture.catalog);
    fixture.data.failure("ERASURE_RECOVERY_UNAVAILABLE", () -> failing.process(claim, 25));
    for (var table : STORES) assertEquals(1, fixture.count(table));
    assertEquals(
        0L, db.queryForObject("SELECT rows_processed FROM erasure_recovery_steps", Long.class));
    assertEquals(3, fixture.finish(claim, 25).totalRows());
  }

  @Test
  void leaseLossAfterRealDeletionRollsBackRowsAndCheckpoint() {
    var target = fixture.device(fixture.subject);
    permissions(target, true);
    var claim = fixture.accept(target);
    fixture.processor.process(claim, 25);
    var failingDb =
        new JdbcTemplate(fixture.data.business) {
          @Override
          public int update(String sql, Object... args) {
            int count = super.update(sql, args);
            if (sql.startsWith("DELETE FROM device_permission_observation_"))
              super.update(
                  "UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
                  claim.job().entry().request().requestId());
            return count;
          }
        };
    var failing = new ErasureObservationProcessor(fixture.data.jobs, failingDb, fixture.catalog);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> failing.process(claim, 25));
    for (var table : STORES) assertEquals(1, fixture.count(table));
    assertEquals(
        0L, db.queryForObject("SELECT rows_processed FROM erasure_recovery_steps", Long.class));
    assertEquals(3, fixture.finish(claim, 25).totalRows());
  }

  @Test
  void concurrentPermissionBatchesNeverDoubleCount() throws Exception {
    var target = fixture.device(fixture.subject);
    permissions(target, true);
    var claim = fixture.accept(target);
    fixture.processor.process(claim, 25);
    var pool = Executors.newFixedThreadPool(2);
    try {
      var first = pool.submit(() -> fixture.processor.process(claim, 1));
      var second = pool.submit(() -> fixture.processor.process(claim, 1));
      assertEquals(
          2,
          first.get(20, TimeUnit.SECONDS).deletedRows()
              + second.get(20, TimeUnit.SECONDS).deletedRows());
      assertEquals(1, STORES.stream().mapToLong(fixture::count).sum());
      assertEquals(3, fixture.finish(claim, 1).totalRows());
    } finally {
      pool.shutdownNow();
      assertTrue(pool.awaitTermination(20, TimeUnit.SECONDS));
    }
  }

  @Test
  void unknownPermissionColumnStopsBeforeDeletion() {
    var target = fixture.device(fixture.subject);
    permissions(target, true);
    var claim = fixture.accept(target);
    db.execute(
        "ALTER TABLE device_permission_observation_snapshots ADD COLUMN unreviewed_payload TEXT");
    try {
      var failure =
          assertThrows(
              com.aimanager.shared.DomainException.class,
              () -> fixture.processor.process(claim, 25));
      assertEquals("ERASURE_SCHEMA_REVIEW_REQUIRED", failure.errorCode());
      for (var table : STORES) assertEquals(1, fixture.count(table));
    } finally {
      db.execute(
          "ALTER TABLE device_permission_observation_snapshots DROP COLUMN unreviewed_payload");
    }
  }
}
