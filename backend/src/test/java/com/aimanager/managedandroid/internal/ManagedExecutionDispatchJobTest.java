package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import java.util.List;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Scheduler sequencing plus the real dispatch/journal with explicit local provider fixtures. */
class ManagedExecutionDispatchJobTest {
  ManagedPolicyExecutionJournal journal;
  ManagedExecutionDispatchService service;
  ManagedAndroidGateway gateway;

  @BeforeEach
  void setup() {
    journal = mock(ManagedPolicyExecutionJournal.class);
    service = mock(ManagedExecutionDispatchService.class);
    gateway = mock(ManagedAndroidGateway.class);
    when(gateway.available()).thenReturn(true);
    when(gateway.providerCode()).thenReturn("LOCAL_TEST");
    when(gateway.supportsExecutionProfiles()).thenReturn(true);
    when(gateway.supportsCompletePolicyDocuments()).thenReturn(true);
    when(gateway.supportsPolicyResourceAuthority()).thenReturn(true);
    when(journal.claimWriteActions("LOCAL_TEST", 1)).thenReturn(List.of());
  }

  @Test
  void terminalConvergencePrecedesAvailabilityAndRunsWhenProviderIsOffline() {
    when(gateway.available()).thenReturn(false);
    run(job(5, 30));
    var order = inOrder(journal, gateway);
    order.verify(journal).settleUnrunnableTasks(5);
    order.verify(gateway).available();
    verify(journal, never()).claimWriteActions(anyString(), anyInt());
    verifyNoInteractions(service);
  }

  @Test
  void eachWriteIsClaimedJustBeforeDispatchWithoutLeasingObservations() {
    var a = claim();
    var b = claim();
    when(journal.claimWriteActions("LOCAL_TEST", 1)).thenReturn(List.of(a), List.of(b), List.of());
    when(service.execute(any())).thenReturn(true);
    run(job(3, 30));
    var order = inOrder(journal, service);
    order.verify(journal).settleUnrunnableTasks(3);
    order.verify(journal).claimWriteActions("LOCAL_TEST", 1);
    order.verify(service).execute(a);
    order.verify(journal).claimWriteActions("LOCAL_TEST", 1);
    order.verify(service).execute(b);
    order.verify(journal).claimWriteActions("LOCAL_TEST", 1);
    verify(journal, never()).claimDue(anyString(), anyInt());
    verify(journal, never()).claimDeviceObservations(anyString(), anyInt());
  }

  @Test
  void failedDispatchEndsThisRoundWithoutAutomaticResend() {
    var claim = claim();
    when(journal.claimWriteActions("LOCAL_TEST", 1)).thenReturn(List.of(claim));
    when(service.execute(claim)).thenReturn(false);
    run(job(5, 30));
    verify(service).execute(claim);
    verify(journal).claimWriteActions("LOCAL_TEST", 1);
  }

  @Test
  void thrownDispatchFailureAlsoEndsTheBoundedRound() {
    var claim = claim();
    when(journal.claimWriteActions("LOCAL_TEST", 1)).thenReturn(List.of(claim));
    when(service.execute(claim)).thenThrow(new IllegalStateException("private provider response"));
    run(job(5, 30));
    verify(service).execute(claim);
    verify(journal).claimWriteActions("LOCAL_TEST", 1);
  }

  @Test
  void storageFailureDuringSettlementPreventsClaimsAndProviderReads() {
    when(journal.settleUnrunnableTasks(5))
        .thenThrow(new DataAccessResourceFailureException("private connection details"));
    run(job(5, 30));
    verify(journal, never()).claimWriteActions(anyString(), anyInt());
    verifyNoInteractions(service, gateway);
  }

  @Test
  void storageFailureDuringClaimDoesNotKeepLooping() {
    when(journal.claimWriteActions("LOCAL_TEST", 1))
        .thenThrow(new DataAccessResourceFailureException("private connection details"));
    run(job(5, 30));
    verify(journal).claimWriteActions("LOCAL_TEST", 1);
    verifyNoInteractions(service);
  }

  @ParameterizedTest
  @ValueSource(strings = {"PROFILE", "DOCUMENT", "AUTHORITY"})
  void disappearingConnectorCapabilityDoesNotConsumeAWriteAttempt(String missing) {
    switch (missing) {
      case "PROFILE" -> when(gateway.supportsExecutionProfiles()).thenReturn(false);
      case "DOCUMENT" -> when(gateway.supportsCompletePolicyDocuments()).thenReturn(false);
      case "AUTHORITY" -> when(gateway.supportsPolicyResourceAuthority()).thenReturn(false);
    }
    run(job(5, 30));
    verify(journal).settleUnrunnableTasks(5);
    verify(journal, never()).claimWriteActions(anyString(), anyInt());
    verifyNoInteractions(service);
  }

  @Test
  void capabilityIsRecheckedBeforeEveryNewClaim() {
    when(journal.claimWriteActions("LOCAL_TEST", 1)).thenReturn(List.of(claim()));
    when(service.execute(any()))
        .thenAnswer(
            call -> {
              when(gateway.available()).thenReturn(false);
              return true;
            });
    run(job(5, 30));
    verify(journal).claimWriteActions("LOCAL_TEST", 1);
    verify(service).execute(any());
  }

  @Test
  void interruptionBeforeWorkIsPreserved() {
    try {
      Thread.currentThread().interrupt();
      run(job(5, 30));
      assertThat(Thread.currentThread().isInterrupted()).isTrue();
      verifyNoInteractions(journal, gateway, service);
    } finally {
      Thread.interrupted();
    }
  }

  @Test
  void interruptionAfterClaimDoesNotStartAProviderWrite() {
    when(journal.claimWriteActions("LOCAL_TEST", 1))
        .thenAnswer(
            call -> {
              Thread.currentThread().interrupt();
              return List.of(claim());
            });
    try {
      run(job(5, 30));
      assertThat(Thread.currentThread().isInterrupted()).isTrue();
      verifyNoInteractions(service);
    } finally {
      Thread.interrupted();
    }
  }

  @Test
  void roundBudgetBoundsWorkEvenIfClaimsNeverBecomeEmpty() {
    when(journal.claimWriteActions("LOCAL_TEST", 1)).thenAnswer(call -> List.of(claim()));
    when(service.execute(any())).thenReturn(true);
    run(job(2, 30));
    verify(journal, times(2)).claimWriteActions("LOCAL_TEST", 1);
    verify(service, times(2)).execute(any());
  }

  @Test
  void unknownOuterTransactionIsRejectedBeforeAnyConsumerAction() {
    try {
      TransactionSynchronizationManager.setActualTransactionActive(true);
      assertThatThrownBy(() -> run(job(5, 30)))
          .isInstanceOf(IllegalStateException.class)
          .hasMessage("Execution dispatch consumer requires separate transactions");
      verifyNoInteractions(journal, gateway, service);
    } finally {
      TransactionSynchronizationManager.setActualTransactionActive(false);
    }
  }

  @ParameterizedTest
  @CsvSource({"0,30", "26,30", "5,4", "5,3601"})
  void invalidSchedulerConfigurationIsRejected(int batch, long interval) {
    assertThatThrownBy(() -> job(batch, interval)).isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void consumerRemainsDisabledByDefault() {
    var condition = ManagedExecutionDispatchJob.class.getAnnotation(ConditionalOnProperty.class);
    assertThat(condition.name()).containsExactly("manager.emm.execution.dispatch.enabled");
    assertThat(condition.havingValue()).isEqualTo("true");
    assertThat(condition.matchIfMissing()).isFalse();
  }

  @Test
  void realConsumerWritesAndAssignsButWaitsForIndependentDeviceEvidence() {
    var fixture = new ManagedExecutionDispatchTest();
    fixture.setup();
    try {
      var f = fixture.f.f;
      f.sql.db.update(
          "UPDATE managed_policy_execution_tasks SET"
              + " lease_token=NULL,lease_until=NULL,action=NULL,next_attempt_at=created_at WHERE"
              + " id=?",
          f.f.claim.taskId());
      when(fixture.gateway.supportsExecutionProfiles()).thenReturn(true);
      run(
          new ManagedExecutionDispatchJob(
              fixture.journal, fixture.service, fixture.gateway, 2, 30));
      assertThat(f.f.view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
      verify(fixture.gateway, times(1)).writePolicyCandidate(anyString(), anyString(), any());
      verify(fixture.gateway, times(1)).assignPolicy(anyString(), anyString(), anyString());
    } finally {
      fixture.close();
    }
  }

  @Test
  void uncertainRealWriteIsSentOnceAndThenEntersExplicitReview() {
    var fixture = new ManagedExecutionDispatchTest();
    fixture.setup();
    try {
      var f = fixture.f.f;
      f.sql.db.update(
          "UPDATE managed_policy_execution_tasks SET"
              + " lease_token=NULL,lease_until=NULL,action=NULL,next_attempt_at=created_at WHERE"
              + " id=?",
          f.f.claim.taskId());
      when(fixture.gateway.supportsExecutionProfiles()).thenReturn(true);
      doThrow(new IllegalStateException("private provider response"))
          .when(fixture.gateway)
          .writePolicyCandidate(anyString(), anyString(), any());
      var job =
          new ManagedExecutionDispatchJob(fixture.journal, fixture.service, fixture.gateway, 5, 30);
      run(job);
      assertThat(f.f.view().state())
          .isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
      run(job);
      assertThat(f.f.view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
      verify(fixture.gateway, times(1)).writePolicyCandidate(anyString(), anyString(), any());
      verify(fixture.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
      assertThat(
              f.sql.db.queryForObject(
                  "SELECT active_device_id FROM managed_policy_execution_tasks WHERE id=?",
                  String.class,
                  f.f.claim.taskId()))
          .isEqualTo(f.device.device());
    } finally {
      fixture.close();
    }
  }

  private ManagedExecutionDispatchJob job(int batch, long interval) {
    return new ManagedExecutionDispatchJob(journal, service, gateway, batch, interval);
  }

  private void run(ManagedExecutionDispatchJob job) {
    try {
      job.dispatch();
    } catch (UnsupportedOperationException missing) {
      throw new AssertionError(missing.getMessage(), missing);
    }
  }

  private ManagedPolicyExecutionJournal.Claim claim() {
    return new ManagedPolicyExecutionJournal.Claim(
        ManagedExecutionTestData.id(),
        ManagedExecutionTestData.id(),
        ManagedExecutionTestData.id(),
        1,
        ManagedPolicyExecutionJournal.Action.WRITE_POLICY,
        System.currentTimeMillis() + 30000,
        "local-enterprise",
        "local-device",
        "local-policy",
        null,
        "{}",
        "a".repeat(64));
  }
}
