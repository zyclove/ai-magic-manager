package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import java.time.Clock;
import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;

/** Real journal and provider executor: stale/late evidence must not report device success. */
class ManagedExecutionObservationBudgetTest {
  ManagedExecutionRecoveryJobTest f;
  ManagedProviderCalls calls;
  AtomicLong nanos;

  @BeforeEach
  void setup() {
    f = new ManagedExecutionRecoveryJobTest();
    f.setup();
    nanos = new AtomicLong();
    calls = new ManagedProviderCalls(1, Duration.ofSeconds(20), nanos::get);
  }

  @AfterEach
  void close() {
    Thread.interrupted();
    calls.close();
    f.close();
    assertThat(calls.isTerminated()).isTrue();
  }

  ManagedExecutionRecoveryJob job() {
    return new ManagedExecutionRecoveryJob(
        f.journal, f.gateway, 1, 30, calls, Clock.systemUTC(), 10000);
  }

  @Test
  void deviceReadRunsOnDedicatedWorkerOutsideTransaction() {
    var task = f.waiting();
    var worker = new AtomicReference<Thread>();
    when(f.gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(
            invocation -> {
              worker.set(Thread.currentThread());
              assertThat(
                      org.springframework.transaction.support.TransactionSynchronizationManager
                          .isActualTransactionActive())
                  .isFalse();
              return f.applied(invocation.getArgument(2), 7L);
            });
    job().recover();
    assertThat(worker.get()).isNotSameAs(Thread.currentThread());
    assertThat(worker.get().getName()).startsWith("managed-provider-");
    assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id()).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.APPLIED);
  }

  @Test
  void lateDeviceEvidenceCannotMarkThePolicyApplied() {
    var task = f.waiting();
    when(f.gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(
            invocation -> {
              nanos.set(TimeUnit.SECONDS.toNanos(20));
              return f.applied(invocation.getArgument(2), 7L);
            });
    job().recover();
    var after = f.journal.get(f.f.tenant(), f.f.actor(), task.id());
    assertThat(after.state()).isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
    assertThat(after.reason()).isEqualTo(ManagedPolicyExecutionJournal.Reason.READ_FAILED);
    verify(f.gateway, times(1)).readDeviceState(anyString(), anyString(), anyString(), anyLong());
    verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void interruptedBlockingObservationDefersWithoutLateSuccess() throws Exception {
    calls.close();
    calls = new ManagedProviderCalls(1, Duration.ofMillis(300), System::nanoTime);
    var task = f.waiting();
    var entered = new CountDownLatch(1);
    var exited = new CountDownLatch(1);
    when(f.gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(
            invocation -> {
              entered.countDown();
              try {
                new CountDownLatch(1).await(2, TimeUnit.SECONDS);
              } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
              } finally {
                exited.countDown();
              }
              return f.applied(invocation.getArgument(2), 7L);
            });
    job().recover();
    assertThat(entered.getCount()).isZero();
    assertThat(exited.await(1, TimeUnit.SECONDS)).isTrue();
    assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id()).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
    verify(f.gateway, times(1)).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @ParameterizedTest
  @ValueSource(longs = {0, 10001})
  void invalidCommitReserveIsRejected(long reserve) {
    assertThatThrownBy(
            () ->
                new ManagedExecutionRecoveryJob(
                    f.journal, f.gateway, 1, 30, calls, Clock.systemUTC(), reserve))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void unavailableConnectorLeavesDeviceObservationUnclaimed() {
    var task = f.waiting();
    var before = f.journal.get(f.f.tenant(), f.f.actor(), task.id());
    when(f.gateway.available()).thenReturn(false);
    job().recover();
    assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id())).isEqualTo(before);
    verify(f.gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void exactEvidenceStillCompletesWithoutAnotherWrite() {
    var task = f.waiting();
    when(f.gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(invocation -> f.applied(invocation.getArgument(2), 7L));
    job().recover();
    assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id()).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.APPLIED);
    verify(f.gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void closedExecutorCannotReadOrReportApplied() {
    var task = f.waiting();
    calls.close();
    when(f.gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(invocation -> f.applied(invocation.getArgument(2), 7L));
    job().recover();
    assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id()).reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.READ_FAILED);
    verify(f.gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void incomingInterruptLeavesTaskUnclaimed() {
    var task = f.waiting();
    var before = f.journal.get(f.f.tenant(), f.f.actor(), task.id());
    Thread.currentThread().interrupt();
    try {
      job().recover();
      assertThat(Thread.currentThread().isInterrupted()).isTrue();
    } finally {
      Thread.interrupted();
    }
    assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id())).isEqualTo(before);
    verifyNoInteractions(f.gateway);
  }

  @Test
  void preflightTimeConsumesTheObservationBudget() {
    var task = f.waiting();
    var store = spy(f.journal);
    doAnswer(
            invocation -> {
              var current = invocation.callRealMethod();
              nanos.set(TimeUnit.SECONDS.toNanos(20));
              return current;
            })
        .when(store)
        .deviceObservationCurrent(any());
    when(f.gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(invocation -> f.applied(invocation.getArgument(2), 7L));
    new ManagedExecutionRecoveryJob(store, f.gateway, 1, 30, calls, Clock.systemUTC(), 10000)
        .recover();
    assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id()).reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.READ_FAILED);
    verify(f.gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void exhaustedLeaseReservePreventsRemoteRead() {
    var task = f.waiting();
    // The journal uses its DB clock; this caller clock leaves less than the 10-second reserve.
    var later = Clock.offset(Clock.systemUTC(), Duration.ofSeconds(25));
    when(f.gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(invocation -> f.applied(invocation.getArgument(2), 7L));
    new ManagedExecutionRecoveryJob(f.journal, f.gateway, 1, 30, calls, later, 10000).recover();
    assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id()).reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.READ_FAILED);
    verify(f.gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void connectorLossDuringReadRejectsReturnedEvidence() {
    var task = f.waiting();
    when(f.gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(
            invocation -> {
              when(f.gateway.available()).thenReturn(false);
              return f.applied(invocation.getArgument(2), 7L);
            });
    job().recover();
    assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id()).reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.READ_FAILED);
  }

  enum QueueChange {
    CANCELLED,
    EXPIRED,
    CONNECTOR
  }

  @ParameterizedTest
  @EnumSource(QueueChange.class)
  void queuedObservationRechecksBeforeReading(QueueChange change) throws Exception {
    var task = f.waiting();
    var entered = new CountDownLatch(1);
    var release = new CountDownLatch(1);
    var callers = java.util.concurrent.Executors.newFixedThreadPool(2);
    try {
      var occupied =
          callers.submit(
              () ->
                  calls.call(
                      calls.budget(Duration.ofSeconds(20)),
                      () -> {
                        entered.countDown();
                        if (!release.await(5, TimeUnit.SECONDS))
                          throw new IllegalStateException("Fixture barrier timed out");
                        return true;
                      }));
      assertThat(entered.await(2, TimeUnit.SECONDS)).isTrue();
      when(f.gateway.readDeviceState(anyString(), anyString(), anyString(), anyLong()))
          .thenAnswer(invocation -> f.applied(invocation.getArgument(2), 7L));
      var observed = callers.submit(() -> job().recover());
      long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
      while (calls.queuedCalls() == 0 && !observed.isDone() && System.nanoTime() < deadline)
        Thread.sleep(1);
      // Old synchronous code completes here and is caught by the zero-read business assertion.
      verify(f.gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
      assertThat(calls.queuedCalls()).isEqualTo(1);
      switch (change) {
        case CANCELLED -> {
          var current = f.journal.get(f.f.tenant(), f.f.actor(), task.id());
          f.journal.cancel(f.f.tenant(), f.f.actor(), task.id(), current.revision());
        }
        case EXPIRED ->
            f.data.db.update(
                "UPDATE managed_policy_execution_tasks SET lease_until=created_at-1 WHERE id=?",
                task.id());
        case CONNECTOR -> when(f.gateway.available()).thenReturn(false);
      }
      release.countDown();
      assertThat(occupied.get(2, TimeUnit.SECONDS)).isTrue();
      observed.get(2, TimeUnit.SECONDS);
      verify(f.gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
      assertThat(f.journal.get(f.f.tenant(), f.f.actor(), task.id()).state())
          .isNotEqualTo(ManagedPolicyExecutionJournal.State.APPLIED);
    } finally {
      release.countDown();
      callers.shutdownNow();
      assertThat(callers.awaitTermination(3, TimeUnit.SECONDS)).isTrue();
    }
  }
}
