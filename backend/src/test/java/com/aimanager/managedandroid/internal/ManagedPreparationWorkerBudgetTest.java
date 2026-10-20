package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import java.time.Duration;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Real durable request/handoff; external preparation is an explicit test double. */
class ManagedPreparationWorkerBudgetTest {
  ManagedPreparationWorkerTest f;
  ManagedProviderCalls calls;
  final AtomicLong ticks = new AtomicLong();

  @BeforeEach
  void setup() {
    f = new ManagedPreparationWorkerTest();
    f.setup();
    calls = spy(new ManagedProviderCalls(1, Duration.ofSeconds(20), ticks::get));
    when(f.preparer.prepare(anyString(), anyString(), anyString(), anyString(), anyLong(), any()))
        .thenReturn(f.h.prepared);
    f.worker =
        new ManagedPreparationWorker(
            f.h.requests, f.preparer, f.h.service, calls, f.h.clock, 10000);
  }

  @AfterEach
  void close() {
    calls.close();
    assertThat(calls.isTerminated()).isTrue();
    f.close();
  }

  @Test
  void suppliesOneBudgetToThePreparationOverload() {
    f.process();
    assertThat(f.row().get("state")).isEqualTo("ADMITTED");
    verify(f.preparer)
        .prepare(
            eq(f.h.f.tenant()),
            eq(f.h.f.actor()),
            eq(f.h.f.publication()),
            eq(f.h.f.binding()),
            eq(2L),
            any(ManagedProviderCalls.Budget.class));
    verify(calls, times(1)).budget(any());
  }

  @Test
  void budgetExpiredDuringPreparationCannotBeHandedOff() {
    when(f.preparer.prepare(anyString(), anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(
            call -> {
              ticks.set(TimeUnit.SECONDS.toNanos(20));
              return f.h.prepared;
            });
    when(f.preparer.prepare(anyString(), anyString(), anyString(), anyString(), anyLong(), any()))
        .thenAnswer(
            call -> {
              ticks.set(TimeUnit.SECONDS.toNanos(20));
              return f.h.prepared;
            });
    f.process();
    f.retryScheduled();
    assertThat(f.count()).isZero();
  }

  @Test
  void closedExecutorPreservesDurableRetryWithoutProviderWork() {
    calls.close();
    f.process();
    f.retryScheduled();
    verifyNoInteractions(f.preparer);
  }

  @Test
  void remainingLeaseIncludesASeparateCommitReserve() {
    var requests = mock(ManagedPreparationRequestJournal.class);
    var handoff = mock(ManagedPreparationHandoffService.class);
    var claim = claim(f.h.now.get() + 22000);
    when(requests.claim(f.h.f.tenant(), f.h.lease.request)).thenReturn(claim);
    when(requests.current(claim)).thenReturn(true);
    new ManagedPreparationWorker(requests, f.preparer, handoff, calls, f.h.clock, 10000)
        .process(f.h.f.tenant(), f.h.lease.request);
    verify(calls).budget(Duration.ofSeconds(12));
    verify(handoff).complete(claim, f.h.prepared);
  }

  @Test
  void insufficientLeaseNeverStartsPreparation() {
    var requests = mock(ManagedPreparationRequestJournal.class);
    var handoff = mock(ManagedPreparationHandoffService.class);
    var claim = claim(f.h.now.get() + 10000);
    when(requests.claim(f.h.f.tenant(), f.h.lease.request)).thenReturn(claim);
    when(requests.current(claim)).thenReturn(true);
    new ManagedPreparationWorker(requests, f.preparer, handoff, calls, f.h.clock, 10000)
        .process(f.h.f.tenant(), f.h.lease.request);
    verifyNoInteractions(f.preparer, handoff);
    verify(requests).failed(claim, true);
  }

  @ParameterizedTest
  @ValueSource(longs = {0, -1, 10001})
  void invalidCommitReserveFailsConfiguration(long reserve) {
    assertThatThrownBy(
            () ->
                new ManagedPreparationWorker(
                    f.h.requests, f.preparer, f.h.service, calls, f.h.clock, reserve))
        .isInstanceOf(IllegalArgumentException.class);
  }

  private ManagedPreparationRequestJournal.Claim claim(long until) {
    var c = f.h.claim;
    return new ManagedPreparationRequestJournal.Claim(
        c.tenantId(),
        c.requestId(),
        c.token(),
        c.generation(),
        until,
        c.revision(),
        c.publicationId(),
        c.binding());
  }
}
