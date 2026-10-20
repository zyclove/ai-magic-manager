package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedPolicyResourceEvidence;
import com.aimanager.shared.DomainException;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import org.springframework.transaction.support.TransactionTemplate;

/** Actual persisted preparation/authority joins and bounded executor; no live EMM is used. */
class ManagedExecutionReadBudgetTest {
  ManagedExecutionResourceAuthorityTest f;
  ManagedProviderCalls calls;
  ManagedExecutionPreparationService preparation;
  ManagedExecutionResourceAuthorityService authority;
  AtomicLong nanos;

  @BeforeEach
  void setup() {
    f = new ManagedExecutionResourceAuthorityTest();
    f.setup();
    nanos = new AtomicLong();
    calls = new ManagedProviderCalls(1, Duration.ofSeconds(20), nanos::get);
    connect();
    when(f.f.preparation.prepare(
            anyString(), anyString(), anyString(), anyString(), anyLong(), any()))
        .thenAnswer(invocation -> f.f.prepared);
  }

  void connect() {
    preparation =
        new ManagedExecutionPreparationService(f.f.sql.journal, f.f.preparation, f.f.clock, calls);
    authority =
        new ManagedExecutionResourceAuthorityService(
            f.f.sql.journal, preparation, f.gateway, f.mapper, f.f.clock, 120, 30, 5, calls);
  }

  @AfterEach
  void close() {
    Thread.interrupted();
    calls.close();
    f.close();
    assertThat(calls.isTerminated()).isTrue();
  }

  ManagedProviderCalls.Budget budget() {
    return calls.budget(Duration.ofSeconds(10));
  }

  void elapsed(int seconds) {
    nanos.set(TimeUnit.SECONDS.toNanos(seconds));
  }

  ManagedPolicyResourceEvidence evidence(ManagedPolicyResourceEvidence.Target target) {
    return new ManagedPolicyResourceEvidence(
        target,
        ManagedPolicyResourceEvidence.Mechanism.AUDITED_EXCLUSIVE_NAMESPACE,
        "local-evidence",
        "local-namespace",
        Instant.ofEpochMilli(f.f.now.get()),
        Instant.ofEpochMilli(f.f.now.get() + 60000));
  }

  void rejected(Runnable action) {
    assertThatThrownBy(action::run).isInstanceOf(DomainException.class);
  }

  @Test
  void bothPreparationsReceiveTheExactSameBudget() {
    var shared = budget();
    authority.verify(f.f.f.claim, shared);
    verify(f.f.preparation, times(2))
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong(), same(shared));
    verify(f.f.preparation, never())
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void expiredBudgetRejectsBeforePreparationOrProviderRead() {
    var shared = budget();
    elapsed(10);
    rejected(() -> authority.verify(f.f.f.claim, shared));
    verifyNoInteractions(f.f.preparation);
    verify(f.gateway, never()).readPolicyResourceAuthority(any());
  }

  @Test
  void firstPreparationCannotRenewExpiredBudget() {
    when(f.f.preparation.prepare(
            anyString(), anyString(), anyString(), anyString(), anyLong(), any()))
        .thenAnswer(
            invocation -> {
              elapsed(10);
              return f.f.prepared;
            });
    rejected(() -> authority.verify(f.f.f.claim, budget()));
    verify(f.gateway, never()).readPolicyResourceAuthority(any());
  }

  @Test
  void providerReadSharesTimeAlreadyConsumedByPreparation() {
    when(f.f.preparation.prepare(
            anyString(), anyString(), anyString(), anyString(), anyLong(), any()))
        .thenAnswer(
            invocation -> {
              elapsed(6);
              return f.f.prepared;
            });
    f.observer =
        target -> {
          elapsed(10);
          return Optional.of(evidence(target));
        };
    rejected(() -> authority.verify(f.f.f.claim, budget()));
    verify(f.f.preparation, times(1))
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong(), any());
  }

  @Test
  void secondPreparationCannotReturnAfterSharedDeadline() {
    var reads = new AtomicInteger();
    when(f.f.preparation.prepare(
            anyString(), anyString(), anyString(), anyString(), anyLong(), any()))
        .thenAnswer(
            invocation -> {
              if (reads.incrementAndGet() == 2) elapsed(10);
              return f.f.prepared;
            });
    rejected(() -> authority.verify(f.f.f.claim, budget()));
    assertThat(reads.get()).isEqualTo(2);
  }

  @Test
  void authorityReadRunsOnDedicatedWorker() {
    Thread caller = Thread.currentThread();
    var worker = new AtomicReference<Thread>();
    f.observer =
        target -> {
          worker.set(Thread.currentThread());
          return Optional.of(evidence(target));
        };
    authority.verify(f.f.f.claim, budget());
    assertThat(worker.get()).isNotSameAs(caller);
    assertThat(worker.get().getName()).startsWith("managed-provider-");
  }

  @Test
  void foreignBudgetIsRejectedBeforeReads() {
    try (var other = new ManagedProviderCalls(1, Duration.ofSeconds(20), nanos::get)) {
      rejected(() -> authority.verify(f.f.f.claim, other.budget(Duration.ofSeconds(10))));
      verifyNoInteractions(f.f.preparation);
      verify(f.gateway, never()).readPolicyResourceAuthority(any());
    }
  }

  @Test
  void closedExecutorRejectsBeforeReads() {
    var shared = budget();
    calls.close();
    rejected(() -> authority.verify(f.f.f.claim, shared));
    verifyNoInteractions(f.f.preparation);
  }

  @Test
  void interruptionIsPreservedAndPreventsAllReads() {
    var shared = budget();
    Thread.currentThread().interrupt();
    try {
      rejected(() -> authority.verify(f.f.f.claim, shared));
      assertThat(Thread.currentThread().isInterrupted()).isTrue();
      verifyNoInteractions(f.f.preparation);
    } finally {
      Thread.interrupted();
    }
  }

  @Test
  void blockingProviderIsBoundedAndNoLateEvidenceIsAccepted() {
    calls.close();
    calls = new ManagedProviderCalls(1, Duration.ofMillis(200), System::nanoTime);
    connect();
    var entered = new CountDownLatch(1);
    var exited = new CountDownLatch(1);
    f.observer =
        target -> {
          entered.countDown();
          try {
            new CountDownLatch(1).await(2, TimeUnit.SECONDS);
          } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
          } finally {
            exited.countDown();
          }
          return Optional.of(evidence(target));
        };
    try {
      rejected(() -> authority.verify(f.f.f.claim, calls.budget(Duration.ofSeconds(10))));
      assertThat(entered.getCount()).isZero();
      assertThat(exited.await(1, TimeUnit.SECONDS)).isTrue();
      verify(f.f.preparation, times(1))
          .prepare(anyString(), anyString(), anyString(), anyString(), anyLong(), any());
    } catch (InterruptedException unexpected) {
      throw new AssertionError(unexpected);
    }
  }

  @Test
  void preparationJoinIndependentlyRejectsExpiredBudget() {
    var shared = budget();
    elapsed(10);
    rejected(() -> preparation.prepare(f.f.f.claim, shared));
    verifyNoInteractions(f.f.preparation);
  }

  @Test
  void currentPolicyAndTaskRemainUnchangedOnSuccess() {
    var before = f.f.f.view();
    var result = authority.verify(f.f.f.claim, budget());
    assertThat(result.prepared().preparation()).isEqualTo(f.f.prepared);
    assertThat(f.f.f.view()).isEqualTo(before);
    verify(f.gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void outerTransactionRemainsRejectedBeforeReads() {
    assertThatThrownBy(
            () ->
                new TransactionTemplate(f.f.sql.data.transactions)
                    .execute(status -> authority.verify(f.f.f.claim, budget())))
        .isInstanceOf(IllegalStateException.class);
    verifyNoInteractions(f.gateway, f.f.preparation);
  }

  @Test
  void providerFailureRemainsSanitized() {
    f.observer =
        target -> {
          throw new IllegalStateException("secret-provider-body");
        };
    assertThatThrownBy(() -> authority.verify(f.f.f.claim, budget()))
        .isInstanceOf(DomainException.class)
        .hasMessage("MANAGED_RESOURCE_PROVIDER_UNAVAILABLE")
        .hasCause(null);
  }
}
