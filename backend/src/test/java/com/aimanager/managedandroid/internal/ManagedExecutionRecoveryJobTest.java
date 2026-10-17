package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.audit.AuditService;
import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Real journal checkpoints with a simulated provider; no device or EMM credentials required. */
class ManagedExecutionRecoveryJobTest {
  ManagedExecutionTestData data;
  ManagedExecutionTestData.Fixture f;
  ManagedPolicyExecutionJournal journal;
  ManagedAndroidGateway gateway;

  @BeforeEach
  void setup() {
    data = new ManagedExecutionTestData();
    f = data.fixture();
    journal = journalFor(f);
    gateway = mock(ManagedAndroidGateway.class);
    when(gateway.available()).thenReturn(true);
    when(gateway.providerCode()).thenReturn("LOCAL_TEST");
  }

  ManagedPolicyExecutionJournal journalFor(ManagedExecutionTestData.Fixture f) {
    var bindings = mock(ManagedAgentBindingStore.class);
    var publications = mock(ManagedExecutionPublicationAccess.class);
    var context =
        new ManagedAgentBindingStore.VerifiedBindingContext(
            f.tenant(),
            f.actor(),
            0,
            f.subject(),
            f.device(),
            f.registration(),
            "a".repeat(64),
            f.binding(),
            2,
            f.enrollment(),
            1,
            "LOCAL_TEST",
            f.enterprise(),
            1,
            f.providerDevice(),
            "DEVICE_OWNER",
            2,
            "com.aimanager.child",
            "b".repeat(64),
            Device.Platform.ANDROID,
            1);
    when(bindings.requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2))
        .thenReturn(context);
    when(publications.requireTarget(
            f.tenant(), f.actor(), f.publication(), f.device(), f.registration()))
        .thenReturn(
            new ManagedExecutionPublicationAccess.Publication(f.version(), "c".repeat(64), 1));
    return new ManagedPolicyExecutionJournal(
        data.db,
        bindings,
        publications,
        new TenantAccess(data.db),
        new AuditService(data.db, Clock.systemUTC()),
        new ManagedPolicyExecutionSettings(30, 24, 1),
        data.transactions);
  }

  @AfterEach
  void close() {
    data.close();
  }

  @Test
  void recoverySelectionLeavesReadyWritesUntouched() throws Exception {
    var task = enqueue();
    assertThat(recoveryClaims()).isEmpty();
    assertThat(journal.get(f.tenant(), f.actor(), task.id()).revision()).isEqualTo(task.revision());
    assertThat(journal.claimDue("LOCAL_TEST", 1)).hasSize(1);
  }

  @Test
  void confirmedExactDeviceVersionBecomesAppliedOutsideTransaction() throws Exception {
    var task = waiting();
    when(gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
              return applied(call.getArgument(2), 7L);
            });
    runRecovery();
    assertThat(journal.get(f.tenant(), f.actor(), task.id()).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.APPLIED);
    verify(gateway)
        .readDeviceState(eq(f.enterprise()), eq(f.providerDevice()), anyString(), eq(7L));
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
  }

  @Test
  void unavailableProviderDoesNotConsumeAttemptOrLease() throws Exception {
    var task = waiting();
    var before = journal.get(f.tenant(), f.actor(), task.id());
    when(gateway.available()).thenReturn(false);
    runRecovery();
    assertThat(journal.get(f.tenant(), f.actor(), task.id())).isEqualTo(before);
    verify(gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void newerVersionIsNotProofOfThisPublication() throws Exception {
    var task = waiting();
    when(gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(call -> applied(call.getArgument(2), 8L));
    runRecovery();
    var after = journal.get(f.tenant(), f.actor(), task.id());
    assertThat(after.state()).isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
    assertThat(after.reason()).isEqualTo(ManagedPolicyExecutionJournal.Reason.DEVICE_PENDING);
  }

  @Test
  void cancellationDuringProviderReadCannotBeOverwrittenByLateSuccess() throws Exception {
    var task = waiting();
    when(gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(
            call -> {
              var current = journal.get(f.tenant(), f.actor(), task.id());
              journal.cancel(f.tenant(), f.actor(), task.id(), current.revision());
              return applied(call.getArgument(2), 7L);
            });
    runRecovery();
    var after = journal.get(f.tenant(), f.actor(), task.id());
    assertThat(after.state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
    assertThat(after.cancellationRequested()).isTrue();
    assertThat(after.reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.CANCELLATION_REQUIRES_REVIEW);
  }

  @Test
  void providerReadFailureUsesDurableBackoffWithoutImmediateRetry() throws Exception {
    var task = waiting();
    when(gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenThrow(new IllegalStateException("provider-private-resource-must-not-be-logged"));
    runRecovery();
    var after = journal.get(f.tenant(), f.actor(), task.id());
    assertThat(after.state()).isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
    assertThat(after.reason()).isEqualTo(ManagedPolicyExecutionJournal.Reason.READ_FAILED);
    verify(gateway, times(1)).readDeviceState(anyString(), anyString(), anyString(), anyLong());
    assertThat(
            data.db.queryForObject(
                "SELECT next_attempt_at-updated_at FROM managed_policy_execution_tasks WHERE id=?",
                Long.class,
                task.id()))
        .isPositive();
  }

  @Test
  void leaseExpiryDuringReadDiscardsResult() throws Exception {
    var task = waiting();
    when(gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(
            call -> {
              data.db.update(
                  "UPDATE managed_policy_execution_tasks SET lease_until=created_at-1,"
                      + "next_attempt_at=expires_at WHERE id=?",
                  task.id());
              return applied(call.getArgument(2), 7L);
            });
    runRecovery();
    assertThat(journal.get(f.tenant(), f.actor(), task.id()).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
  }

  @ParameterizedTest
  @EnumSource(ManagedPolicyExecutionJournal.State.class)
  void selectionOnlyLeasesDeviceObservationStates(ManagedPolicyExecutionJournal.State state) {
    var task = enqueue();
    data.db.update(
        "UPDATE managed_policy_execution_tasks SET state=?,provider_version=7,"
            + "active_device_id=? WHERE id=?",
        state.name(),
        state == ManagedPolicyExecutionJournal.State.APPLIED
                || state == ManagedPolicyExecutionJournal.State.CANCELLED
            ? null
            : f.device(),
        task.id());
    var claims = recoveryClaims();
    if (state == ManagedPolicyExecutionJournal.State.ASSIGNMENT_UNKNOWN
        || state == ManagedPolicyExecutionJournal.State.WAITING_DEVICE) {
      assertThat(claims).hasSize(1);
      assertThat(claims.get(0).action())
          .isEqualTo(ManagedPolicyExecutionJournal.Action.READ_DEVICE);
      assertThat(journal.deviceObservationCurrent(claims.get(0))).isTrue();
    } else {
      assertThat(claims).isEmpty();
      assertThat(journal.get(f.tenant(), f.actor(), task.id()).revision())
          .isEqualTo(task.revision());
    }
  }

  @Test
  void cancelledClaimIsRejectedBeforeRead() {
    var task = waiting();
    var claim = recoveryClaims().get(0);
    var current = journal.get(f.tenant(), f.actor(), task.id());
    journal.cancel(f.tenant(), f.actor(), task.id(), current.revision());
    assertThat(journal.deviceObservationCurrent(claim)).isFalse();
  }

  @Test
  void deadlineRequiresReviewWithoutReading() {
    var task = waiting();
    long now = System.currentTimeMillis();
    data.db.update(
        "UPDATE managed_policy_execution_tasks SET created_at=?,expires_at=?,next_attempt_at=?"
            + " WHERE id=?",
        now - 10_000L,
        now - 1000L,
        now - 10_000L,
        task.id());
    runRecovery();
    assertThat(journal.get(f.tenant(), f.actor(), task.id()).reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.DEADLINE_EXCEEDED);
    verify(gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void attemptExhaustionDoesNotDispatchAnotherRead() {
    var task = waiting();
    data.db.update("UPDATE managed_policy_execution_tasks SET attempts=24 WHERE id=?", task.id());
    runRecovery();
    assertThat(journal.get(f.tenant(), f.actor(), task.id()).reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.ATTEMPTS_EXHAUSTED);
    verify(gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void expiredHeadDoesNotDelayNextValidDeviceForAnotherRound() {
    var expiredFixture = f;
    var expired = waiting();
    data.db.update(
        "UPDATE managed_policy_execution_tasks SET next_attempt_at=expires_at WHERE id=?",
        expired.id());
    f = data.fixture();
    journal = journalFor(f);
    var valid = waiting();
    long now = System.currentTimeMillis();
    data.db.update(
        "UPDATE managed_policy_execution_tasks SET created_at=?,expires_at=?,next_attempt_at=?"
            + " WHERE id=?",
        now - 10_000L,
        now - 1000L,
        now - 10_000L,
        expired.id());
    when(gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(call -> applied(call.getArgument(2), 7L));
    runRecovery();
    assertThat(journal.get(expiredFixture.tenant(), expiredFixture.actor(), expired.id()).reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.DEADLINE_EXCEEDED);
    assertThat(journal.get(f.tenant(), f.actor(), valid.id()).state())
        .as("expired head must not stop recovery of the next valid device")
        .isEqualTo(ManagedPolicyExecutionJournal.State.APPLIED);
  }

  @Test
  void providerSelectionAndLeasePreventDuplicateOwnership() {
    waiting();
    assertThat(journal.claimDeviceObservations("OTHER_PROVIDER", 1)).isEmpty();
    assertThat(recoveryClaims()).hasSize(1);
    assertThat(recoveryClaims()).isEmpty();
  }

  @Test
  void concurrentWorkersCannotOwnTheSameLiveLease() throws Exception {
    waiting();
    var workers = Executors.newFixedThreadPool(2);
    try {
      var first = workers.submit(this::recoveryClaims);
      var second = workers.submit(this::recoveryClaims);
      assertThat(first.get(10, TimeUnit.SECONDS).size() + second.get(10, TimeUnit.SECONDS).size())
          .isEqualTo(1);
    } finally {
      workers.shutdownNow();
      assertThat(workers.awaitTermination(10, TimeUnit.SECONDS)).isTrue();
    }
  }

  @Test
  void outerTransactionIsRejectedBeforeAnyProviderCall() {
    assertThatThrownBy(
            () ->
                new TransactionTemplate(data.transactions)
                    .execute(
                        s -> {
                          runRecovery();
                          return null;
                        }))
        .isInstanceOf(IllegalStateException.class);
    verifyNoInteractions(gateway);
  }

  @Test
  void invalidResponseIsDeferredAndCannotReportApplied() {
    var task = waiting();
    when(gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenReturn(null);
    runRecovery();
    assertThat(journal.get(f.tenant(), f.actor(), task.id()).reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.READ_FAILED);
  }

  @Test
  void batchIsBoundedAndClaimsAreTakenOneAtATime() {
    waiting();
    var claim = recoveryClaims().get(0);
    var store = mock(ManagedPolicyExecutionJournal.class);
    when(store.claimDeviceObservations("LOCAL_TEST", 1)).thenReturn(List.of(claim));
    when(store.deviceObservationCurrent(claim)).thenReturn(true);
    when(gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenReturn(applied(claim.policyId(), 7L));
    new ManagedExecutionRecoveryJob(store, gateway, 2, 30).recover();
    var order = inOrder(store, gateway);
    for (int i = 0; i < 2; i++) {
      order.verify(store).claimDeviceObservations("LOCAL_TEST", 1);
      order.verify(store).deviceObservationCurrent(claim);
      order
          .verify(gateway)
          .readDeviceState(f.enterprise(), f.providerDevice(), claim.policyId(), 7L);
      order.verify(store).deviceObserved(eq(claim), any());
    }
    verify(store, times(2)).claimDeviceObservations("LOCAL_TEST", 1);
  }

  @Test
  void failedCheckpointDoesNotAbortRemainingBatch() {
    waiting();
    var claim = recoveryClaims().get(0);
    var store = mock(ManagedPolicyExecutionJournal.class);
    when(store.claimDeviceObservations("LOCAL_TEST", 1)).thenReturn(List.of(claim));
    when(store.deviceObservationCurrent(claim)).thenReturn(true);
    when(gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenThrow(new IllegalStateException("private-provider-payload"))
        .thenReturn(applied(claim.policyId(), 7L));
    when(store.failed(claim)).thenThrow(new IllegalStateException("private-database-payload"));
    new ManagedExecutionRecoveryJob(store, gateway, 2, 30).recover();
    verify(store).failed(claim);
    verify(store).deviceObserved(eq(claim), any());
  }

  @Test
  void stalePreflightSkipsProviderRead() {
    waiting();
    var claim = recoveryClaims().get(0);
    var store = mock(ManagedPolicyExecutionJournal.class);
    when(store.claimDeviceObservations("LOCAL_TEST", 1)).thenReturn(List.of(claim));
    when(store.deviceObservationCurrent(claim)).thenReturn(false);
    new ManagedExecutionRecoveryJob(store, gateway, 1, 30).recover();
    verify(gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @ParameterizedTest
  @ValueSource(ints = {-1, 0, 26, 100})
  void invalidBatchIsRejected(int batch) {
    assertThatThrownBy(() -> new ManagedExecutionRecoveryJob(journal, gateway, batch, 30))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @ParameterizedTest
  @ValueSource(longs = {-1, 0, 4, 3601, Long.MAX_VALUE})
  void invalidIntervalIsRejected(long interval) {
    assertThatThrownBy(() -> new ManagedExecutionRecoveryJob(journal, gateway, 1, interval))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void schedulerIsOffByDefaultAndRequiresExplicitOptIn() {
    var runner =
        new ApplicationContextRunner()
            .withUserConfiguration(ManagedExecutionRecoveryJob.class)
            .withBean(ManagedPolicyExecutionJournal.class, () -> journal)
            .withBean(ManagedAndroidGateway.class, () -> gateway);
    runner.run(context -> assertThat(context).doesNotHaveBean(ManagedExecutionRecoveryJob.class));
    runner
        .withPropertyValues("manager.emm.execution.device-recovery.enabled=true")
        .run(context -> assertThat(context).hasSingleBean(ManagedExecutionRecoveryJob.class));
    verifyNoInteractions(gateway);
  }

  List<ManagedPolicyExecutionJournal.Claim> recoveryClaims() {
    return journal.claimDeviceObservations("LOCAL_TEST", 1);
  }

  void runRecovery() {
    new ManagedExecutionRecoveryJob(journal, gateway, 5, 30L).recover();
  }

  ManagedPolicyExecutionJournal.View enqueue() {
    return journal.enqueue(
        f.tenant(),
        f.actor(),
        f.publication(),
        f.binding(),
        2,
        ManagedPolicyExecutionJournalTest.DOCUMENT,
        System.currentTimeMillis() + 600_000L);
  }

  ManagedPolicyExecutionJournal.View waiting() {
    var task = enqueue();
    var write = journal.claimDue("LOCAL_TEST", 1).get(0);
    assertThat(journal.beforeWrite(journal.writePreparationTarget(write), write.leaseUntil()))
        .isTrue();
    assertThat(
            journal.policyWritten(
                write, new ManagedAndroidGateway.PolicyReceipt(policy(write.policyId()), 7L)))
        .isTrue();
    var assign = journal.claimDue("LOCAL_TEST", 1).get(0);
    assertThat(journal.beforeWrite(journal.writePreparationTarget(assign), assign.leaseUntil()))
        .isTrue();
    assertThat(
            journal.assignmentAccepted(
                assign,
                new ManagedAndroidGateway.AssignmentReceipt(
                    "enterprises/" + f.enterprise() + "/devices/" + f.providerDevice(),
                    policy(assign.policyId()))))
        .isTrue();
    data.db.update(
        "UPDATE managed_policy_execution_tasks SET next_attempt_at=created_at WHERE id=?",
        task.id());
    return task;
  }

  String policy(String id) {
    return "enterprises/" + f.enterprise() + "/policies/" + id;
  }

  ManagedAndroidGateway.ManagedDeviceState applied(String policyId, long version) {
    return new ManagedAndroidGateway.ManagedDeviceState(
        "enterprises/" + f.enterprise() + "/devices/" + f.providerDevice(),
        "DEVICE_OWNER",
        policy(policyId),
        policy(policyId),
        version,
        ManagedAndroidGateway.ApplyState.APPLIED,
        List.of(),
        null);
  }
}
