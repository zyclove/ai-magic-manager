package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;

class ErasureDeviceIdentityProcessorTest {
  ErasureObservationProcessorTest fixture;
  JdbcTemplate db;
  ErasureDeviceIdentityProcessor processor;
  String tenant, subject, peer;
  final Set<String> testTenants = new LinkedHashSet<>();

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
    testTenants.clear();
    testTenants.add(tenant);
    processor = new ErasureDeviceIdentityProcessor(fixture.data.jobs, db, fixture.catalog);
  }

  String credential(ErasureObservationProcessorTest.Device device) {
    return credential(device, false, 1L, 100L);
  }

  String credential(
      ErasureObservationProcessorTest.Device device, boolean active, Long revoked, long expires) {
    String key = id();
    db.update(
        "INSERT INTO"
            + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at,revoked_at)"
            + " VALUES(?,?,?,?,?,?,1,?,?)",
        key,
        tenant,
        device.id(),
        device.registration(),
        id().replace("-", "").repeat(2),
        active,
        expires,
        revoked);
    return key;
  }

  void scope(ErasureObservationProcessorTest.Device device, boolean active) {
    db.update(
        "INSERT INTO"
            + " device_credential_scopes(tenant_id,registration_id,device_id,active,revoked_at)"
            + " VALUES(?,?,?,?,?)",
        tenant,
        device.registration(),
        device.id(),
        active,
        active ? null : 1L);
  }

  void rotation(String parent, String next) {
    db.update(
        "INSERT INTO device_credential_rotations(parent_id,new_id,expires_at) VALUES(?,?,100)",
        parent,
        next);
  }

  void capability(ErasureObservationProcessorTest.Device device, String name) {
    db.update(
        "INSERT INTO"
            + " device_capabilities(tenant_id,device_id,capability_key,reported_supported,grant_status,checked_at)"
            + " VALUES(?,?,?,true,'GRANTED',1)",
        tenant,
        device.id(),
        name);
  }

  String group() {
    String group = id();
    db.update(
        "INSERT INTO device_groups(tenant_id,id,name,name_key,created_at,updated_at)"
            + " VALUES(?,?,'shared',?,1,1)",
        tenant,
        group,
        id().replace("-", "").repeat(2));
    return group;
  }

  void member(String group, ErasureObservationProcessorTest.Device device) {
    db.update(
        "INSERT INTO device_group_members(tenant_id,group_id,device_id,registration_id,added_at)"
            + " VALUES(?,?,?,?,1)",
        tenant,
        group,
        device.id(),
        device.registration());
  }

  long count(String table) {
    if (table.equals("erasure_recovery_steps"))
      return db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_steps", Long.class);
    if (table.equals("device_credential_rotations"))
      return db.queryForObject(
          "SELECT COUNT(*) FROM device_credential_rotations r JOIN device_credentials c ON"
              + " c.id=r.parent_id WHERE c."
              + tenantFilter(),
          Long.class,
          testTenants.toArray());
    return db.queryForObject(
        "SELECT COUNT(*) FROM " + table + " WHERE " + tenantFilter(),
        Long.class,
        testTenants.toArray());
  }

  String tenantFilter() {
    return "tenant_id IN (" + String.join(",", Collections.nCopies(testTenants.size(), "?")) + ")";
  }

  List<String> strings(String selection) {
    return db.queryForList(
        selection + " WHERE " + tenantFilter(), String.class, testTenants.toArray());
  }

  ErasureDeviceIdentityProcessor.Result finish(ErasureRecoveryJobs.Claim claim, int limit) {
    for (int n = 0; n < 100; n++) {
      var result = processor.process(claim, limit);
      assertTrue(result.deletedRows() <= limit);
      if (result.complete()) return result;
    }
    fail("Bounded processor did not finish");
    return null;
  }

  @Test
  void deletesFiveStoresInLeafOrderAndRetainsSharedGroupAndPeer() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    String parent = credential(target), next = credential(target);
    String retained = credential(other), group = group();
    rotation(parent, next);
    scope(target, false);
    scope(other, false);
    capability(target, "target-capability");
    capability(other, "peer-capability");
    member(group, target);
    member(group, other);
    var claim = fixture.accept(target);
    var result = finish(claim, 1);
    assertEquals(6, result.totalRows());
    assertEquals(0, count("device_credential_rotations"));
    assertEquals(List.of(retained), strings("SELECT id FROM device_credentials"));
    for (String table :
        List.of(
            "device_credential_scopes",
            "device_capabilities",
            "device_group_members",
            "device_groups")) assertEquals(1, count(table));
    assertEquals(2, count("devices"));
    assertEquals(
        "CLAIMED", fixture.data.jobs.find(claim.job().entry().request().requestId()).state());
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, fixture.data.ledger.workState());
    var replay = processor.process(claim, 25);
    assertTrue(replay.complete());
    assertEquals(0, replay.deletedRows());
    assertEquals(result.batches(), replay.batches());
  }

  @Test
  void oldRegistrationCannotEraseReenrolledPeerCapabilitiesOrCredentials() {
    var current = fixture.device(peer);
    var old = new ErasureObservationProcessorTest.Device(current.id(), id(), subject);
    credential(current);
    scope(current, false);
    capability(current, "current");
    member(group(), current);
    assertEquals(0, finish(fixture.accept(old), 25).totalRows());
    for (String table :
        List.of(
            "device_credentials",
            "device_credential_scopes",
            "device_capabilities",
            "device_group_members")) assertEquals(1, count(table));
  }

  @Test
  void rotationToPeerCredentialBlocksBeforeAnyDeletion() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    rotation(credential(target), credential(other));
    fixture.data.failure(
        "ERASURE_CREDENTIAL_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(2, count("device_credentials"));
    assertEquals(1, count("device_credential_rotations"));
    assertEquals(0, count("erasure_recovery_steps"));
  }

  @Test
  void rotationFromPeerCredentialAlsoBlocksBeforeAnyDeletion() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    rotation(credential(other), credential(target));
    fixture.data.failure(
        "ERASURE_CREDENTIAL_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(2, count("device_credentials"));
  }

  @Test
  void unexitedDeviceCannotBePhysicallyCleanedEvenWithoutCredentials() {
    var target = fixture.device(subject);
    db.update("UPDATE devices SET state='ACTIVE' WHERE tenant_id=? AND id=?", tenant, target.id());
    capability(target, "keep");
    fixture.data.failure(
        "ERASURE_DEVICE_EXIT_REQUIRED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("device_capabilities"));
  }

  @Test
  void activeCredentialScopeCannotBeSilentlyRemoved() {
    var target = fixture.device(subject);
    scope(target, true);
    fixture.data.failure(
        "ERASURE_DEVICE_EXIT_REQUIRED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("device_credential_scopes"));
  }

  @Test
  void usableActiveCredentialCannotBeSilentlyRemoved() {
    var target = fixture.device(subject);
    credential(target, true, null, Long.MAX_VALUE);
    fixture.data.failure(
        "ERASURE_DEVICE_EXIT_REQUIRED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("device_credentials"));
  }

  @Test
  void capabilityRowsAreIncludedInThePhysicalBatchBudget() {
    var target = fixture.device(subject);
    for (int n = 0; n < 26; n++) capability(target, "cap-" + n);
    var claim = fixture.accept(target);
    var first = processor.process(claim, 25);
    assertEquals(25, first.deletedRows());
    assertFalse(first.complete());
    assertEquals(1, count("device_capabilities"));
    var last =
        new ErasureDeviceIdentityProcessor(fixture.data.jobs, db, fixture.catalog)
            .process(claim, 25);
    assertTrue(last.complete());
    assertEquals(26, last.totalRows());
    assertEquals(2, last.batches());
  }

  @Test
  void doneReplayRejectsReappearingCredentialWithoutAdvancingCheckpoint() {
    var target = fixture.device(subject);
    var claim = fixture.accept(target);
    var completed = finish(claim, 25);
    credential(target);
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    assertEquals(1, count("device_credentials"));
    assertEquals(
        completed.batches(),
        db.queryForObject("SELECT batches_processed FROM erasure_recovery_steps", Long.class));
  }

  @Test
  void omittedCurrentRegistrationCannotBeIgnored() {
    var target = fixture.device(subject);
    credential(target);
    fixture.data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(fixture.accept(), 25));
    assertEquals(1, count("device_credentials"));
    assertEquals(0, count("erasure_recovery_steps"));
  }

  @Test
  void acceptedTupleCannotBeReassignedToPeer() {
    var target = fixture.device(subject);
    credential(target);
    var claim = fixture.accept(target);
    db.update(
        "UPDATE devices SET subject_id=? WHERE tenant_id=? AND id=?", peer, tenant, target.id());
    fixture.data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(claim, 25));
    assertEquals(1, count("device_credentials"));
  }

  @Test
  void twoAcceptedDevicesStillCannotShareACredentialRotation() {
    var first = fixture.device(subject);
    var second = fixture.device(subject);
    rotation(credential(first), credential(second));
    fixture.data.failure(
        "ERASURE_CREDENTIAL_SCOPE_CORRUPT",
        () -> processor.process(fixture.accept(first, second), 25));
    assertEquals(2, count("device_credentials"));
  }

  String secondTenantWithSameOpaqueDevice(ErasureObservationProcessorTest.Device device) {
    String other = id();
    testTenants.add(other);
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'other','FAMILY','UTC',1)",
        other);
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'other','AGE_7_12',1)",
        other,
        device.subject());
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'other','ANDROID','fixture','REVOKED','{}',?,1)",
        other,
        device.id(),
        device.subject(),
        device.registration(),
        "b".repeat(64));
    return other;
  }

  @Test
  void identicalOpaqueDeviceInOtherTenantIsPreserved() {
    var target = fixture.device(subject);
    credential(target);
    capability(target, "same-key");
    String home = tenant;
    tenant = secondTenantWithSameOpaqueDevice(target);
    String retained = credential(target);
    scope(target, false);
    capability(target, "same-key");
    member(group(), target);
    tenant = home;
    assertEquals(2, finish(fixture.accept(target), 25).totalRows());
    assertEquals(List.of(retained), strings("SELECT id FROM device_credentials"));
    for (String table :
        List.of(
            "device_credentials",
            "device_credential_scopes",
            "device_capabilities",
            "device_group_members")) assertEquals(1, count(table));
  }

  @Test
  void crossTenantRotationCannotHideBehindEqualDeviceAndRegistrationIds() {
    var target = fixture.device(subject);
    String own = credential(target), home = tenant;
    tenant = secondTenantWithSameOpaqueDevice(target);
    String other = credential(target);
    tenant = home;
    rotation(own, other);
    var claim = fixture.accept(target);
    fixture.data.failure("ERASURE_CREDENTIAL_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    db.update("DELETE FROM device_credential_rotations WHERE parent_id=?", own);
    rotation(other, own);
    fixture.data.failure("ERASURE_CREDENTIAL_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(2, count("device_credentials"));
    assertEquals(0, count("erasure_recovery_steps"));
  }

  @Test
  void revokedExpiredAndNeverActivatedCredentialsAreAllRemoved() {
    var target = fixture.device(subject);
    credential(target, false, 1L, Long.MAX_VALUE);
    credential(target, true, 1L, Long.MAX_VALUE);
    credential(target, true, null, 1L);
    credential(target, false, null, Long.MAX_VALUE);
    scope(target, false);
    assertEquals(5, finish(fixture.accept(target), 2).totalRows());
    assertEquals(0, count("device_credentials"));
    assertEquals(0, count("device_credential_scopes"));
  }

  @Test
  void emptyAcceptedScopeDoesNotBlockOnActivePeer() {
    var other = fixture.device(peer);
    credential(other, true, null, Long.MAX_VALUE);
    scope(other, true);
    db.update("UPDATE devices SET state='ACTIVE' WHERE tenant_id=? AND id=?", tenant, other.id());
    assertEquals(0, finish(fixture.accept(), 25).totalRows());
    assertEquals(1, count("device_credentials"));
  }

  @Test
  void compositeMembershipAndCapabilityKeysPreserveOtherMembers() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    String first = group(), second = group();
    for (String group : List.of(first, second)) {
      member(group, target);
      member(group, other);
    }
    for (String key : List.of("shared-capability", "second-capability")) {
      capability(target, key);
      capability(other, key);
    }
    assertEquals(4, finish(fixture.accept(target), 3).totalRows());
    assertEquals(2, count("device_group_members"));
    assertEquals(2, count("device_capabilities"));
    assertEquals(2, count("device_groups"));
    assertEquals(
        List.of(other.id()), strings("SELECT DISTINCT device_id FROM device_capabilities"));
  }

  @Test
  void storageFailureAfterActualDeletionRollsBackNewCheckpointAndRows() {
    var target = fixture.device(subject);
    credential(target);
    var claim = fixture.accept(target);
    var faulty =
        new JdbcTemplate(Objects.requireNonNull(db.getDataSource())) {
          @Override
          public int update(String sql, Object... args) {
            int result = super.update(sql, args);
            if (sql.startsWith("DELETE FROM device_credentials"))
              throw new IllegalStateException("Injected after deletion");
            return result;
          }
        };
    var failing = new ErasureDeviceIdentityProcessor(fixture.data.jobs, faulty, fixture.catalog);
    assertThrows(IllegalStateException.class, () -> failing.process(claim, 25));
    assertEquals(1, count("device_credentials"));
    assertEquals(0, count("erasure_recovery_steps"));
    assertEquals(1, finish(claim, 25).totalRows());
  }

  @Test
  void leaseLossAfterDeletionRollsBackAnExistingCheckpoint() {
    var target = fixture.device(subject);
    for (int n = 0; n < 3; n++) credential(target);
    var claim = fixture.accept(target);
    assertEquals(1, processor.process(claim, 1).totalRows());
    var faulty =
        new JdbcTemplate(Objects.requireNonNull(db.getDataSource())) {
          @Override
          public int update(String sql, Object... args) {
            int result = super.update(sql, args);
            if (sql.startsWith("DELETE FROM device_credentials"))
              super.update(
                  "UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
                  claim.job().entry().request().requestId());
            return result;
          }
        };
    var failing = new ErasureDeviceIdentityProcessor(fixture.data.jobs, faulty, fixture.catalog);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> failing.process(claim, 25));
    assertEquals(2, count("device_credentials"));
    assertEquals(
        1L, db.queryForObject("SELECT rows_processed FROM erasure_recovery_steps", Long.class));
    assertEquals(
        1L, db.queryForObject("SELECT batches_processed FROM erasure_recovery_steps", Long.class));
    assertEquals(3, finish(claim, 25).totalRows());
  }

  @Test
  void replacedWorkerCannotDeleteOrAdvanceCheckpoint() {
    var target = fixture.device(subject);
    credential(target);
    var old = fixture.accept(target);
    db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
    var current = fixture.data.jobs.claim(id(), 300);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> processor.process(old, 25));
    assertEquals(1, count("device_credentials"));
    assertEquals(0, count("erasure_recovery_steps"));
    assertEquals(1, finish(current, 25).totalRows());
  }

  @Test
  void concurrentBatchesDoNotDoubleDeleteOrDoubleCount() throws Exception {
    var target = fixture.device(subject);
    for (int n = 0; n < 7; n++) credential(target);
    var claim = fixture.accept(target);
    var pool = Executors.newFixedThreadPool(2);
    try {
      var first = pool.submit(() -> processor.process(claim, 3));
      var second = pool.submit(() -> processor.process(claim, 3));
      assertEquals(
          6,
          first.get(20, TimeUnit.SECONDS).deletedRows()
              + second.get(20, TimeUnit.SECONDS).deletedRows());
    } finally {
      pool.shutdownNow();
      assertTrue(pool.awaitTermination(20, TimeUnit.SECONDS));
    }
    assertEquals(1, count("device_credentials"));
    assertEquals(7, finish(claim, 25).totalRows());
    assertEquals(
        3L, db.queryForObject("SELECT batches_processed FROM erasure_recovery_steps", Long.class));
  }

  @Test
  void invalidBatchLimitsCannotStartDeletion() {
    var target = fixture.device(subject);
    credential(target);
    var claim = fixture.accept(target);
    for (int limit : new int[] {-1, 0, 26, Integer.MAX_VALUE})
      assertThrows(IllegalArgumentException.class, () -> processor.process(claim, limit));
    assertEquals(1, count("device_credentials"));
    assertEquals(0, count("erasure_recovery_steps"));
  }

  @Test
  void unsupportedCheckpointVersionCannotAdvance() {
    var target = fixture.device(subject);
    credential(target);
    credential(target);
    var claim = fixture.accept(target);
    processor.process(claim, 1);
    db.update("UPDATE erasure_recovery_steps SET handler_version=2");
    fixture.data.failure("ERASURE_STEP_VERSION_UNSUPPORTED", () -> processor.process(claim, 25));
    assertEquals(1, count("device_credentials"));
  }

  @Test
  void unsupportedCheckpointPhaseOrCursorCannotSkipRemainingRows() {
    var target = fixture.device(subject);
    credential(target);
    credential(target);
    var claim = fixture.accept(target);
    processor.process(claim, 1);
    db.update("UPDATE erasure_recovery_steps SET phase='REPORTS',cursor_id=?", id());
    fixture.data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(1, count("device_credentials"));
  }

  @Test
  void exhaustedCountersCannotWrapOrDeleteFurtherRows() {
    var target = fixture.device(subject);
    credential(target);
    credential(target);
    var claim = fixture.accept(target);
    processor.process(claim, 1);
    for (String column : List.of("rows_processed", "batches_processed")) {
      db.update("UPDATE erasure_recovery_steps SET " + column + "=?", Long.MAX_VALUE);
      fixture.data.failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
      assertEquals(1, count("device_credentials"));
      db.update("UPDATE erasure_recovery_steps SET " + column + "=1");
    }
  }

  @Test
  void doneReplayRejectsReappearingCapabilitiesAndMemberships() {
    var target = fixture.device(subject);
    var claim = fixture.accept(target);
    finish(claim, 25);
    capability(target, "new");
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    db.update(
        "DELETE FROM device_capabilities WHERE tenant_id=? AND device_id=?", tenant, target.id());
    member(group(), target);
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    assertEquals(1, count("device_group_members"));
  }

  @Test
  void unreviewedStorageBlocksBeforeAnyDeletion() {
    var target = fixture.device(subject);
    credential(target);
    var claim = fixture.accept(target);
    db.execute("CREATE TABLE identity_erasure_unreviewed(id INTEGER PRIMARY KEY)");
    try {
      assertThrows(RuntimeException.class, () -> processor.process(claim, 25));
      assertEquals(1, count("device_credentials"));
      assertEquals(0, count("erasure_recovery_steps"));
    } finally {
      db.execute("DROP TABLE identity_erasure_unreviewed");
    }
  }
}
