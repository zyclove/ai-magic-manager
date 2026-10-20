package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import java.util.List;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Scheduler orchestration only; request selection and worker transitions have separate SQL tests.
 */
class ManagedPreparationRecoveryJobTest {
  ManagedPreparationRequestJournal requests;
  ManagedPreparationWorker worker;
  ManagedPreparationRecoveryJob job;
  final ManagedPreparationRequestJournal.Reference first =
      new ManagedPreparationRequestJournal.Reference(
          ManagedExecutionTestData.id(), ManagedExecutionTestData.id());
  final ManagedPreparationRequestJournal.Reference second =
      new ManagedPreparationRequestJournal.Reference(
          ManagedExecutionTestData.id(), ManagedExecutionTestData.id());

  @BeforeEach
  void setup() {
    requests = mock(ManagedPreparationRequestJournal.class);
    worker = mock(ManagedPreparationWorker.class);
    job = new ManagedPreparationRecoveryJob(requests, worker, 5, 30);
    when(requests.dueRequests(5)).thenReturn(List.of(first, second));
  }

  @AfterEach
  void clearInterrupt() {
    Thread.interrupted();
  }

  void recover() {
    try {
      job.recover();
    } catch (UnsupportedOperationException missing) {
      if ("MANAGED_PREPARATION_RECOVERY_NOT_IMPLEMENTED".equals(missing.getMessage()))
        throw new AssertionError(missing.getMessage(), missing);
      throw missing;
    }
  }

  @Test
  void selectedReferencesAreProcessedSequentiallyWithoutPreclaiming() {
    doAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
              return null;
            })
        .when(worker)
        .process(anyString(), anyString());
    recover();
    var order = inOrder(requests, worker);
    order.verify(requests).dueRequests(5);
    order.verify(worker).process(first.tenantId(), first.requestId());
    order.verify(worker).process(second.tenantId(), second.requestId());
    verify(requests, never()).claim(anyString(), anyString());
  }

  @Test
  void emptyBatchDoesNotInvokeTheWorker() {
    when(requests.dueRequests(5)).thenReturn(List.of());
    recover();
    verifyNoInteractions(worker);
  }

  @Test
  void failedRequestDoesNotPreventOtherReferencesBeingAttempted() {
    doThrow(new IllegalStateException("provider credential=fixture-secret"))
        .when(worker)
        .process(first.tenantId(), first.requestId());
    recover();
    verify(worker).process(second.tenantId(), second.requestId());
  }

  @Test
  void unavailableStorageStopsTheRoundInsteadOfRepeatingCalls() {
    doThrow(new ManagedPreparationWorker.StorageUnavailable())
        .when(worker)
        .process(first.tenantId(), first.requestId());
    recover();
    verify(worker, never()).process(second.tenantId(), second.requestId());
  }

  @Test
  void rawDatabaseFailureAlsoStopsTheRound() {
    doThrow(new DataAccessResourceFailureException("fixture database unavailable"))
        .when(worker)
        .process(first.tenantId(), first.requestId());
    recover();
    verify(worker, never()).process(second.tenantId(), second.requestId());
  }

  @Test
  void scanFailureDoesNotInvokeTheWorker() {
    when(requests.dueRequests(5))
        .thenThrow(new DataAccessResourceFailureException("fixture failure"));
    recover();
    verifyNoInteractions(worker);
  }

  @Test
  void interruptedRoundDoesNotSelectOrProcessAnything() {
    Thread.currentThread().interrupt();
    recover();
    verifyNoInteractions(requests, worker);
    assertThat(Thread.currentThread().isInterrupted()).isTrue();
  }

  @Test
  void interruptionAfterARequestDoesNotStartTheNextOne() {
    doAnswer(
            call -> {
              Thread.currentThread().interrupt();
              return null;
            })
        .when(worker)
        .process(first.tenantId(), first.requestId());
    recover();
    verify(worker, never()).process(second.tenantId(), second.requestId());
  }

  @Test
  void schedulingRequiresBothExplicitFlags() {
    var gate = ManagedPreparationRecoveryJob.class.getAnnotation(ConditionalOnProperty.class);
    assertThat(gate.prefix()).isEqualTo("manager.emm.execution.preparation");
    assertThat(gate.name()).containsExactly("enabled", "recovery.enabled");
    assertThat(gate.havingValue()).isEqualTo("true");
    assertThat(gate.matchIfMissing()).isFalse();
    recover(); // Still requires actual orchestration; this metadata alone is not a successful RED.
  }

  @ParameterizedTest
  @CsvSource({"0,30", "26,30", "5,4", "5,3601"})
  void invalidSchedulerConfigurationIsRejected(int batch, long seconds) {
    assertThatThrownBy(() -> new ManagedPreparationRecoveryJob(requests, worker, batch, seconds))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void schedulerRejectsAnOuterTransaction() {
    try (var data = new ManagedExecutionTestData()) {
      var tx = new org.springframework.transaction.support.TransactionTemplate(data.transactions);
      assertThatThrownBy(() -> tx.executeWithoutResult(status -> recover()))
          .isInstanceOf(IllegalStateException.class)
          .hasMessage("Preparation recovery requires separate transactions");
      verifyNoInteractions(requests, worker);
    }
  }
}
