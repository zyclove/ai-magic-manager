package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.shared.DomainException;
import java.util.Map;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.http.HttpStatus;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Real request/task SQL and handoff; external preparation and lower qualification are fixtures. */
class ManagedPreparationWorkerTest {
  final ManagedProviderCalls calls =
      new ManagedProviderCalls(1, java.time.Duration.ofSeconds(20), System::nanoTime);

  ManagedPreparationHandoffTest h;
  ManagedPolicyPreparationService preparer;
  ManagedPreparationWorker worker;

  @BeforeEach
  void setup() {
    h = new ManagedPreparationHandoffTest();
    h.setup();
    h.sql.db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " lease_token=NULL,lease_until=NULL,generation=0,attempts=0,revision=1,reason_code='QUEUED',next_attempt_at=created_at"
            + " WHERE tenant_id=? AND id=?",
        h.f.tenant(),
        h.lease.request);
    preparer = mock(ManagedPolicyPreparationService.class);
    when(preparer.prepare(
            eq(h.f.tenant()),
            eq(h.f.actor()),
            eq(h.f.publication()),
            eq(h.f.binding()),
            eq(2L),
            any(ManagedProviderCalls.Budget.class)))
        .thenAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
              return h.prepared;
            });
    worker = new ManagedPreparationWorker(h.requests, preparer, h.service, calls, h.clock, 10000);
  }

  @AfterEach
  void close() {
    Thread.interrupted();
    calls.close();
    h.close();
  }

  void process() {
    invoke(() -> worker.process(h.f.tenant(), h.lease.request));
  }

  static void invoke(Runnable work) {
    try {
      work.run();
    } catch (UnsupportedOperationException missing) {
      if ("MANAGED_PREPARATION_WORKER_NOT_IMPLEMENTED".equals(missing.getMessage()))
        throw new AssertionError(missing.getMessage(), missing);
      throw missing;
    }
  }

  Map<String, Object> row() {
    return h.lease.row();
  }

  long count() {
    return h.sql.db.queryForObject(
        "SELECT COUNT(*) FROM managed_policy_execution_tasks WHERE tenant_id=?",
        Long.class,
        h.f.tenant());
  }

  void retryScheduled() {
    assertThat(row().get("state")).isEqualTo("PENDING");
    assertThat(row().get("reason_code")).isEqualTo("READ_RETRY_SCHEDULED");
    assertThat(row().get("lease_token")).isNull();
    assertThat(row().get("active_device_id")).isEqualTo(h.f.device());
    assertThat(((Number) row().get("next_attempt_at")).longValue()).isGreaterThan(h.lease.now());
    assertThat(count()).isZero();
  }

  @Test
  void completePreparationCreatesOnlyAReadyTaskWithoutAnOuterTransaction() {
    process();
    assertThat(row().get("state")).isEqualTo("ADMITTED");
    assertThat(count()).isEqualTo(1);
    var state =
        h.sql.db.queryForObject(
            "SELECT state FROM managed_policy_execution_tasks WHERE tenant_id=?",
            String.class,
            h.f.tenant());
    assertThat(state).isEqualTo("READY_TO_WRITE");
    verify(preparer)
        .prepare(
            eq(h.f.tenant()),
            eq(h.f.actor()),
            eq(h.f.publication()),
            eq(h.f.binding()),
            eq(2L),
            any(ManagedProviderCalls.Budget.class));
  }

  @Test
  void repeatedWakeupCannotPrepareOrCreateTheTaskTwice() {
    process();
    var before = row();
    process();
    assertThat(row()).isEqualTo(before);
    assertThat(count()).isEqualTo(1);
    verify(preparer, times(1))
        .prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class));
  }

  @Test
  void aLiveLeaseHeldElsewhereDoesNotReadTheProvider() {
    h.requests.claim(h.f.tenant(), h.lease.request);
    var before = row();
    process();
    assertThat(row()).isEqualTo(before);
    verifyNoInteractions(preparer);
  }

  @Test
  void cancelledRequestDoesNotReadTheProvider() {
    h.requests.cancel(h.f.tenant(), h.f.actor(), h.lease.request, 1);
    var before = row();
    process();
    assertThat(row()).isEqualTo(before);
    verifyNoInteractions(preparer);
  }

  @Test
  void revokedOriginalAuthorityIsRetiredBeforeAnyRead() {
    h.sql.db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", h.f.tenant());
    process();
    assertThat(row().get("state")).isEqualTo("REJECTED");
    verifyNoInteractions(preparer);
    assertThat(count()).isZero();
  }

  @Test
  void noncurrentOwnedClaimCannotStartPreparation() {
    var requests = spy(h.requests);
    doReturn(false).when(requests).current(any());
    worker = new ManagedPreparationWorker(requests, preparer, h.service, calls, h.clock, 10000);
    process();
    verifyNoInteractions(preparer);
    assertThat(row().get("state")).isEqualTo("REJECTED");
  }

  @ParameterizedTest
  @ValueSource(ints = {400, 403, 404, 409, 412, 422})
  void permanentDomainRejectionEndsTheRequest(int status) {
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenThrow(new DomainException(HttpStatus.valueOf(status), "FIXTURE_REJECTED"));
    process();
    assertThat(row().get("state")).isEqualTo("REJECTED");
    assertThat(row().get("reason_code")).isEqualTo("PREPARATION_FAILED");
    assertThat(row().get("active_device_id")).isNull();
    assertThat(count()).isZero();
  }

  @ParameterizedTest
  @ValueSource(ints = {429, 500, 503})
  void transientDomainFailureSchedulesBoundedRetry(int status) {
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenThrow(new DomainException(HttpStatus.valueOf(status), "FIXTURE_UNAVAILABLE"));
    process();
    retryScheduled();
  }

  @Test
  void unexpectedPreparationFailureIsRetriedWithoutLeakingItsMessage() {
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenThrow(new IllegalStateException("credential=fixture-secret"));
    process();
    retryScheduled();
    assertThat(row().toString()).doesNotContain("fixture-secret");
  }

  @Test
  void aNewWorkerCanResumeADurableRetry() {
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenThrow(new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "FIXTURE_UNAVAILABLE"))
        .thenReturn(h.prepared);
    process();
    retryScheduled();
    h.sql.db.update(
        "UPDATE managed_policy_preparation_requests SET next_attempt_at=created_at WHERE"
            + " tenant_id=?",
        h.f.tenant());
    worker = new ManagedPreparationWorker(h.requests, preparer, h.service, calls, h.clock, 10000);
    process();
    assertThat(row().get("state")).isEqualTo("ADMITTED");
    assertThat(((Number) row().get("attempts")).intValue()).isEqualTo(2);
  }

  @Test
  void aNewWorkerRecoversAnExpiredLeaseFromAnAbandonedAttempt() {
    var abandoned = h.requests.claim(h.f.tenant(), h.lease.request);
    h.sql.db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " created_at=1,next_attempt_at=1,lease_until=2 WHERE tenant_id=?",
        h.f.tenant());
    worker = new ManagedPreparationWorker(h.requests, preparer, h.service, calls, h.clock, 10000);
    process();
    assertThat(row().get("state")).isEqualTo("ADMITTED");
    assertThat(((Number) row().get("generation")).longValue())
        .isEqualTo(abandoned.generation() + 1);
    assertThat(h.requests.current(abandoned)).isFalse();
  }

  @Test
  void cancellationDuringPreparationPreventsHandoff() {
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenAnswer(
            call -> {
              h.requests.cancel(
                  h.f.tenant(),
                  h.cancellingActor,
                  h.lease.request,
                  ((Number) row().get("revision")).longValue());
              return h.prepared;
            });
    process();
    assertThat(row().get("state")).isEqualTo("CANCELLED");
    assertThat(count()).isZero();
  }

  @Test
  void aReplacementLeaseCannotBeReleasedByTheOldWorker() {
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenAnswer(
            call -> {
              h.sql.db.update(
                  "UPDATE managed_policy_preparation_requests SET"
                      + " created_at=1,next_attempt_at=1,lease_until=2 WHERE tenant_id=?",
                  h.f.tenant());
              h.requests.claim(h.f.tenant(), h.lease.request);
              return h.prepared;
            });
    process();
    assertThat(row().get("state")).isEqualTo("PENDING");
    assertThat(row().get("lease_token")).isNotNull();
    assertThat(((Number) row().get("generation")).longValue()).isEqualTo(2);
    assertThat(count()).isZero();
  }

  @Test
  void authorityRevokedDuringPreparationIsRejectedWithoutTaskCreation() {
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenAnswer(
            call -> {
              h.sql.db.update(
                  "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?",
                  h.f.tenant());
              return h.prepared;
            });
    process();
    assertThat(row().get("state")).isEqualTo("REJECTED");
    assertThat(count()).isZero();
  }

  @Test
  void taskAuditFailureRollsBackTaskThenSchedulesRequestRetry() {
    doThrow(new IllegalStateException("FIXTURE_AUDIT_FAILED"))
        .when(h.sql.audit)
        .record(eq(h.f.tenant()), eq(h.f.actor()), eq("MANAGED_EXECUTION_QUEUED"), anyString());
    process();
    retryScheduled();
  }

  @Test
  void interruptedWorkerDoesNotAcquireAnotherLease() {
    var before = row();
    Thread.currentThread().interrupt();
    process();
    assertThat(row()).isEqualTo(before);
    verifyNoInteractions(preparer);
    assertThat(Thread.currentThread().isInterrupted()).isTrue();
  }

  @Test
  void interruptionDuringReadLeavesLeaseForRecoveryWithoutHandoff() {
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenAnswer(
            call -> {
              Thread.currentThread().interrupt();
              return h.prepared;
            });
    process();
    assertThat(row().get("state")).isEqualTo("PENDING");
    assertThat(row().get("lease_token")).isNotNull();
    assertThat(count()).isZero();
    assertThat(Thread.currentThread().isInterrupted()).isTrue();
  }

  @Test
  void workerRejectsAnOuterTransactionBeforeClaiming() {
    assertThatThrownBy(() -> h.lease.intake.tx.executeWithoutResult(status -> process()))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Preparation worker requires separate transactions");
    assertThat(((Number) row().get("attempts")).intValue()).isZero();
    verifyNoInteractions(preparer);
  }

  @Test
  void malformedReferenceCannotCauseProviderReads() {
    assertThatThrownBy(() -> invoke(() -> worker.process("bad", h.lease.request)))
        .isInstanceOf(DomainException.class);
    verifyNoInteractions(preparer);
    assertThat(count()).isZero();
  }

  @Test
  void databaseFailureWhileClaimingIsSanitizedForTheScanner() {
    var requests = spy(h.requests);
    doThrow(new DataAccessResourceFailureException("credential=fixture-secret"))
        .when(requests)
        .claim(anyString(), anyString());
    worker = new ManagedPreparationWorker(requests, preparer, h.service, calls, h.clock, 10000);
    assertThatThrownBy(this::process)
        .isInstanceOf(ManagedPreparationWorker.StorageUnavailable.class)
        .hasMessage("Preparation storage unavailable")
        .hasNoCause();
    verifyNoInteractions(preparer);
    assertThat(count()).isZero();
  }

  @Test
  void failedCheckpointLeavesItsDurableLeaseAndSanitizesTheStorageFailure() {
    var requests = spy(h.requests);
    doThrow(new DataAccessResourceFailureException("credential=fixture-secret"))
        .when(requests)
        .failed(any(), anyBoolean());
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenThrow(new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "FIXTURE_UNAVAILABLE"));
    worker = new ManagedPreparationWorker(requests, preparer, h.service, calls, h.clock, 10000);
    assertThatThrownBy(this::process)
        .isInstanceOf(ManagedPreparationWorker.StorageUnavailable.class)
        .hasNoCause();
    assertThat(row().get("state")).isEqualTo("PENDING");
    assertThat(row().get("lease_token")).isNotNull();
  }
}
