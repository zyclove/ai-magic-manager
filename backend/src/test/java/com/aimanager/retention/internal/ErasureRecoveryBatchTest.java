package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class ErasureRecoveryBatchTest {
  ErasureRecoveryJobsTest data;
  ErasureRecoveryJobs.Claim claim;
  String tenant;

  @BeforeEach
  void setup() {
    data = new ErasureRecoveryJobsTest();
    data.setup();
    var request = data.request();
    tenant = request.tenantId();
    data.db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at)"
            + " VALUES(?,'before','FAMILY','UTC',1)",
        tenant);
    data.ledger.append(request);
    data.jobs.reconcile(10);
    claim = data.jobs.claim(UUID.randomUUID().toString(), 60);
  }

  void change() {
    data.db.update("UPDATE tenants SET name='after' WHERE id=?", tenant);
  }

  String name() {
    return data.db.queryForObject("SELECT name FROM tenants WHERE id=?", String.class, tenant);
  }

  @Test
  void commitsBusinessChangeInsideVerifiedLease() {
    assertEquals(
        42,
        data.jobs.applyBatch(
            claim,
            () -> {
              change();
              return 42;
            }));
    assertEquals("after", name());
  }

  @Test
  void callbackFailureRollsBackEveryBusinessChange() {
    assertThrows(
        IllegalStateException.class,
        () ->
            data.jobs.applyBatch(
                claim,
                () -> {
                  change();
                  throw new IllegalStateException("synthetic failure");
                }));
    assertEquals("before", name());
  }

  @Test
  void expiredLeaseCannotInvokeMutation() {
    data.db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
    var invoked = new AtomicBoolean();
    data.failure(
        "ERASURE_RECOVERY_LEASE_LOST",
        () -> data.jobs.applyBatch(claim, () -> invoked.getAndSet(true)));
    assertFalse(invoked.get());
  }

  @Test
  void oldFenceCannotMutateAfterLeaseReclaimed() {
    data.db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
    var replacement = data.jobs.claim(UUID.randomUUID().toString(), 60);
    assertTrue(replacement.fence() > claim.fence());
    data.failure(
        "ERASURE_RECOVERY_LEASE_LOST",
        () ->
            data.jobs.applyBatch(
                claim,
                () -> {
                  change();
                  return null;
                }));
    assertEquals("before", name());
  }

  @Test
  void independentJournalIsVerifiedAgainBeforeMutation() {
    data.ledgerDb.update("UPDATE erasure_ledger_entries SET entry_hash=?", "b".repeat(64));
    assertThrows(
        com.aimanager.retention.ErasureLedger.Failure.class,
        () ->
            data.jobs.applyBatch(
                claim,
                () -> {
                  change();
                  return null;
                }));
    assertEquals("before", name());
  }

  @Test
  void leaseLossDuringCallbackRollsBackItsChanges() {
    data.failure(
        "ERASURE_RECOVERY_LEASE_LOST",
        () ->
            data.jobs.applyBatch(
                claim,
                () -> {
                  change();
                  data.db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
                  return null;
                }));
    assertEquals("before", name());
  }

  @Test
  void independentJournalLossDuringCallbackAlsoRollsBackMutation() {
    assertThrows(
        com.aimanager.retention.ErasureLedger.Failure.class,
        () ->
            data.jobs.applyBatch(
                claim,
                () -> {
                  change();
                  data.ledgerDb.update(
                      "UPDATE erasure_ledger_head SET ledger_id=?", UUID.randomUUID().toString());
                  return null;
                }));
    assertEquals("before", name());
  }

  @Test
  void realLeaseDeadlinePassingInsideTransactionPreventsCommit() {
    data.db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
    var shortClaim = data.jobs.claim(UUID.randomUUID().toString(), 5);
    data.failure(
        "ERASURE_RECOVERY_LEASE_LOST",
        () ->
            data.jobs.applyBatch(
                shortClaim,
                () -> {
                  change();
                  try {
                    java.util.concurrent.TimeUnit.SECONDS.sleep(6);
                  } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException(interrupted);
                  }
                  return null;
                }));
    assertEquals("before", name());
  }
}
