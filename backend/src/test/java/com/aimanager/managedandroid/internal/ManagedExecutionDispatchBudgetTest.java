package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedAndroidGateway.*;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.transaction.support.TransactionTemplate;

/** Real durable dispatch with a bounded executor and explicit local provider fixtures. */
class ManagedExecutionDispatchBudgetTest {
  ManagedExecutionDispatchTest f;
  ManagedProviderCalls calls;
  ManagedExecutionResourceAuthorityService authority;
  ManagedExecutionDispatchService dispatch;
  AtomicLong nanos;

  @BeforeEach
  void setup() {
    f = new ManagedExecutionDispatchTest();
    f.setup();
    nanos = new AtomicLong();
    calls = new ManagedProviderCalls(1, Duration.ofSeconds(20), nanos::get);
    var preparer =
        new ManagedExecutionPreparationService(f.journal, f.f.f.preparation, f.f.f.clock, calls);
    authority =
        new ManagedExecutionResourceAuthorityService(
            f.journal, preparer, f.gateway, f.f.mapper, f.f.f.clock, 120, 30, 5, calls);
    dispatch =
        new ManagedExecutionDispatchService(
            f.journal, authority, f.gateway, f.f.f.clock, calls, 10000);
  }

  @AfterEach
  void close() {
    Thread.interrupted();
    calls.close();
    f.close();
    assertThat(calls.isTerminated()).isTrue();
  }

  ManagedPolicyExecutionJournal.Claim claim() {
    return f.f.f.f.claim;
  }

  ManagedPolicyExecutionJournal.View view() {
    return f.f.f.f.view();
  }

  String policy() {
    return "enterprises/" + claim().enterpriseId() + "/policies/" + claim().policyId();
  }

  String device() {
    return "enterprises/" + claim().enterpriseId() + "/devices/" + claim().deviceId();
  }

  void expireBudget() {
    nanos.set(TimeUnit.SECONDS.toNanos(20));
  }

  void assignment() {
    assertThat(
            f.journal.beforeWrite(f.journal.writePreparationTarget(claim()), claim().leaseUntil()))
        .isTrue();
    assertThat(f.journal.policyWritten(claim(), new PolicyReceipt(policy(), 7L))).isTrue();
    f.f.f.f.claim = f.journal.claimWriteActions("LOCAL_TEST", 1).get(0);
  }

  @ParameterizedTest
  @ValueSource(strings = {"WRITE", "ASSIGN"})
  void providerMutationUsesDedicatedWorker(String action) {
    if (action.equals("ASSIGN")) assignment();
    var worker = new AtomicReference<Thread>();
    if (action.equals("WRITE")) {
      doAnswer(
              invocation -> {
                worker.set(Thread.currentThread());
                assertThat(view().state())
                    .isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
                return new PolicyReceipt(policy(), 7L);
              })
          .when(f.gateway)
          .writePolicyCandidate(anyString(), anyString(), any());
    } else {
      doAnswer(
              invocation -> {
                worker.set(Thread.currentThread());
                assertThat(view().state())
                    .isEqualTo(ManagedPolicyExecutionJournal.State.ASSIGNMENT_UNKNOWN);
                return new AssignmentReceipt(device(), policy());
              })
          .when(f.gateway)
          .assignPolicy(anyString(), anyString(), anyString());
    }
    assertThat(dispatch.execute(claim())).isTrue();
    assertThat(worker.get()).isNotSameAs(Thread.currentThread());
    assertThat(worker.get().getName()).startsWith("managed-provider-");
  }

  @Test
  void assignmentRevalidationUsesOneOriginalBudgetForAllFourPreparations() {
    assignment();
    List<ManagedProviderCalls.Budget> seen = new ArrayList<>();
    when(f.f.f.preparation.prepare(
            anyString(), anyString(), anyString(), anyString(), anyLong(), any()))
        .thenAnswer(
            invocation -> {
              seen.add(invocation.getArgument(5));
              return f.f.f.prepared;
            });
    assertThat(dispatch.execute(claim())).isTrue();
    assertThat(seen).hasSize(4);
    seen.forEach(budget -> assertThat(budget).isSameAs(seen.get(0)));
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
  }

  @Test
  void inspectionBeforeAssignmentCannotRenewConsumedBudget() {
    assignment();
    doAnswer(
            invocation -> {
              expireBudget();
              return new CompletePolicyInspection(policy(), 7L, CompletePolicyState.MATCHED);
            })
        .when(f.gateway)
        .inspectCompletePolicy(anyString(), anyString(), any(), anyLong());
    assertThat(dispatch.execute(claim())).isFalse();
    verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.CANCELLED);
  }

  @Test
  void lateWriteReceiptLeavesUncertaintyAndIsNeverReplayed() {
    doAnswer(
            invocation -> {
              expireBudget();
              return new PolicyReceipt(policy(), 7L);
            })
        .when(f.gateway)
        .writePolicyCandidate(anyString(), anyString(), any());
    assertThat(dispatch.execute(claim())).isFalse();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
    verify(f.gateway, never()).inspectCompletePolicy(anyString(), anyString(), any(), anyLong());
    assertThat(dispatch.execute(claim())).isFalse();
    verify(f.gateway, times(1)).writePolicyCandidate(anyString(), anyString(), any());
    verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void latePostWriteInspectionDoesNotConfirmWrite() {
    doAnswer(
            invocation -> {
              expireBudget();
              return new CompletePolicyInspection(policy(), 7L, CompletePolicyState.MATCHED);
            })
        .when(f.gateway)
        .inspectCompletePolicy(anyString(), anyString(), any(), anyLong());
    assertThat(dispatch.execute(claim())).isFalse();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
    verify(f.gateway, times(1)).writePolicyCandidate(anyString(), anyString(), any());
  }

  @Test
  void lateAssignmentReceiptDoesNotBecomeDeviceEvidence() {
    assignment();
    doAnswer(
            invocation -> {
              expireBudget();
              return new AssignmentReceipt(device(), policy());
            })
        .when(f.gateway)
        .assignPolicy(anyString(), anyString(), anyString());
    assertThat(dispatch.execute(claim())).isFalse();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.ASSIGNMENT_UNKNOWN);
    assertThat(dispatch.execute(claim())).isFalse();
    verify(f.gateway, times(1)).assignPolicy(anyString(), anyString(), anyString());
    verify(f.gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void elapsedCheckpointCannotStartRemoteWrite() {
    var journal = spy(f.journal);
    doAnswer(
            invocation -> {
              Object result = invocation.callRealMethod();
              expireBudget();
              return result;
            })
        .when(journal)
        .beforeWrite(any(), anyLong());
    dispatch =
        new ManagedExecutionDispatchService(
            journal, authority, f.gateway, f.f.f.clock, calls, 10000);
    assertThat(dispatch.execute(claim())).isFalse();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
    verify(f.gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
  }

  @Test
  void insufficientLeaseReserveRejectsBeforeAnyProviderRead() {
    f.f.f.now.set(claim().leaseUntil() - 5000);
    assertThat(dispatch.execute(claim())).isFalse();
    verify(f.gateway, never()).readPolicyResourceAuthority(any());
    verify(f.gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verifyNoInteractions(f.f.f.preparation);
  }

  @Test
  void repeatedAuthorityChecksConsumeCumulativeTime() {
    assignment();
    when(f.f.f.preparation.prepare(
            anyString(), anyString(), anyString(), anyString(), anyLong(), any()))
        .thenAnswer(
            invocation -> {
              nanos.addAndGet(TimeUnit.SECONDS.toNanos(6));
              return f.f.f.prepared;
            });
    assertThat(dispatch.execute(claim())).isFalse();
    verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void blockingWriteTimesOutWithoutReplayingOrConfirmingItsLateReceipt() throws Exception {
    calls.close();
    calls = new ManagedProviderCalls(1, Duration.ofMillis(300), System::nanoTime);
    var preparer =
        new ManagedExecutionPreparationService(f.journal, f.f.f.preparation, f.f.f.clock, calls);
    authority =
        new ManagedExecutionResourceAuthorityService(
            f.journal, preparer, f.gateway, f.f.mapper, f.f.f.clock, 120, 30, 5, calls);
    dispatch =
        new ManagedExecutionDispatchService(
            f.journal, authority, f.gateway, f.f.f.clock, calls, 10000);
    var entered = new CountDownLatch(1);
    var exited = new CountDownLatch(1);
    doAnswer(
            invocation -> {
              entered.countDown();
              try {
                new CountDownLatch(1).await(2, TimeUnit.SECONDS);
              } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
              } finally {
                exited.countDown();
              }
              return new PolicyReceipt(policy(), 7L);
            })
        .when(f.gateway)
        .writePolicyCandidate(anyString(), anyString(), any());
    assertThat(dispatch.execute(claim())).isFalse();
    assertThat(entered.getCount()).isZero();
    assertThat(exited.await(1, TimeUnit.SECONDS)).isTrue();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
    verify(f.gateway, never()).inspectCompletePolicy(anyString(), anyString(), any(), anyLong());
    assertThat(dispatch.execute(claim())).isFalse();
    verify(f.gateway, times(1)).writePolicyCandidate(anyString(), anyString(), any());
  }

  @ParameterizedTest
  @ValueSource(longs = {0, 10001})
  void invalidCommitReserveIsRejected(long reserve) {
    assertThatThrownBy(
            () ->
                new ManagedExecutionDispatchService(
                    f.journal, authority, f.gateway, f.f.f.clock, calls, reserve))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void successfulWriteStillWaitsForAssignmentAndDeviceEvidence() {
    assertThat(dispatch.execute(claim())).isTrue();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_ASSIGN);
    verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
    verify(f.gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void outerTransactionRemainsRejectedBeforeProviderCalls() {
    assertThatThrownBy(
            () ->
                new TransactionTemplate(f.f.f.sql.data.transactions)
                    .execute(status -> dispatch.execute(claim())))
        .isInstanceOf(IllegalStateException.class);
    verifyNoInteractions(f.gateway, f.f.f.preparation);
  }

  @Test
  void incomingInterruptionRemainsSetAndPreventsWrites() {
    Thread.currentThread().interrupt();
    try {
      assertThat(dispatch.execute(claim())).isFalse();
      assertThat(Thread.currentThread().isInterrupted()).isTrue();
      verify(f.gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
      verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
    } finally {
      Thread.interrupted();
    }
  }
}
