package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Real bounded threads and interrupts; latches release every intentionally stuck provider. */
class ManagedProviderCallsTest {
  private final List<ManagedProviderCalls> pools = new ArrayList<>();
  private final List<CountDownLatch> releases = new ArrayList<>();
  private final List<ExecutorService> callers = new ArrayList<>();

  @AfterEach
  void clean() throws Exception {
    Thread.interrupted();
    TransactionSynchronizationManager.setActualTransactionActive(false);
    releases.forEach(CountDownLatch::countDown);
    pools.forEach(ManagedProviderCalls::close);
    for (var caller : callers) {
      caller.shutdownNow();
      assertThat(caller.awaitTermination(5, TimeUnit.SECONDS)).isTrue();
    }
    long end = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
    for (var pool : pools) {
      while (!pool.isTerminated() && System.nanoTime() < end) Thread.yield();
      // The initial RED stub has no threads. Implemented pools must expose their real termination.
      if (pool.isClosed()) assertThat(pool.isTerminated()).isTrue();
    }
  }

  private ManagedProviderCalls pool(int size, java.util.function.LongSupplier ticker) {
    var p = new ManagedProviderCalls(size, Duration.ofSeconds(2), ticker);
    pools.add(p);
    return p;
  }

  private CountDownLatch release() {
    var latch = new CountDownLatch(1);
    releases.add(latch);
    return latch;
  }

  private ExecutorService caller() {
    var executor = Executors.newSingleThreadExecutor();
    callers.add(executor);
    return executor;
  }

  @Test
  void returnsResultOnDedicatedThreadWithoutCallerTransaction() {
    var p = pool(1, System::nanoTime);
    String callerName = Thread.currentThread().getName();
    String thread =
        p.call(
            p.budget(Duration.ofSeconds(1)),
            () -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
              return Thread.currentThread().getName();
            });
    assertThat(thread).startsWith("managed-provider-").isNotEqualTo(callerName);
    assertThat(p.queuedCalls()).isZero();
  }

  @Test
  void consecutiveCallsShareBudgetInsteadOfRestartingIt() {
    var ticker = new AtomicLong();
    var p = pool(1, ticker::get);
    var budget = p.budget(Duration.ofMillis(100));
    assertThat(
            p.call(
                budget,
                () -> {
                  ticker.addAndGet(TimeUnit.MILLISECONDS.toNanos(60));
                  return "first";
                }))
        .isEqualTo("first");
    assertThatThrownBy(
            () ->
                p.call(
                    budget,
                    () -> {
                      ticker.addAndGet(TimeUnit.MILLISECONDS.toNanos(40));
                      return "late";
                    }))
        .isInstanceOf(ManagedProviderCalls.Failure.class)
        .hasMessage("MANAGED_PROVIDER_TIMEOUT");
  }

  @Test
  void expiredBudgetDoesNotStartProvider() {
    var ticker = new AtomicLong();
    var p = pool(1, ticker::get);
    var budget = p.budget(Duration.ofMillis(100));
    ticker.set(TimeUnit.MILLISECONDS.toNanos(100));
    var invoked = new AtomicInteger();
    assertThatThrownBy(() -> p.call(budget, invoked::incrementAndGet))
        .hasMessage("MANAGED_PROVIDER_TIMEOUT");
    assertThat(invoked).hasValue(0);
  }

  @Test
  void callerCannotRequestMoreThanConfiguredTotalBudget() {
    var ticker = new AtomicLong();
    var p = pool(1, ticker::get);
    var budget = p.budget(Duration.ofDays(1));
    ticker.set(TimeUnit.SECONDS.toNanos(2));
    assertThatThrownBy(() -> p.call(budget, () -> "forbidden"))
        .hasMessage("MANAGED_PROVIDER_TIMEOUT");
  }

  @Test
  void remainingAuthorizationCanShortenConfiguredBudget() {
    var ticker = new AtomicLong();
    var p = pool(1, ticker::get);
    var budget = p.budget(Duration.ofMillis(20));
    ticker.set(TimeUnit.MILLISECONDS.toNanos(20));
    assertThatThrownBy(() -> p.call(budget, () -> "forbidden"))
        .hasMessage("MANAGED_PROVIDER_TIMEOUT");
  }

  @Test
  void nanoTimeWraparoundDoesNotRenewBudget() {
    var ticker = new AtomicLong(Long.MAX_VALUE - 10_000_000L);
    var p = pool(1, ticker::get);
    var budget = p.budget(Duration.ofMillis(20));
    ticker.addAndGet(20_000_000L);
    assertThatThrownBy(() -> p.call(budget, () -> "forbidden"))
        .hasMessage("MANAGED_PROVIDER_TIMEOUT");
  }

  @Test
  void saturatedPoolAndBoundedQueueRejectWithoutCallerRunsFallback() throws Exception {
    var p = pool(1, System::nanoTime);
    var budget = p.budget(Duration.ofSeconds(2));
    var started = new CountDownLatch(1);
    var release = release();
    var first =
        caller()
            .submit(
                () ->
                    p.call(
                        budget,
                        () -> {
                          started.countDown();
                          release.await();
                          return "done";
                        }));
    assertThat(started.await(1, TimeUnit.SECONDS)).isTrue();
    var second = caller().submit(() -> p.call(budget, () -> "queued"));
    awaitQueued(p);
    var invoked = new AtomicInteger();
    assertThatThrownBy(() -> p.call(budget, invoked::incrementAndGet))
        .hasMessage("MANAGED_PROVIDER_CAPACITY");
    assertThat(invoked).hasValue(0);
    assertThat(p.activeCalls()).isEqualTo(1);
    assertThat(p.queuedCalls()).isEqualTo(1);
    release.countDown();
    assertThat(first.get(1, TimeUnit.SECONDS)).isEqualTo("done");
    assertThat(second.get(1, TimeUnit.SECONDS)).isEqualTo("queued");
  }

  @Test
  void timeoutDoesNotReleaseCapacityOfProviderIgnoringInterruption() throws Exception {
    var p = pool(1, System::nanoTime);
    var started = new CountDownLatch(1);
    var interrupted = new CountDownLatch(1);
    var release = release();
    var first =
        caller()
            .submit(
                () -> {
                  assertThatThrownBy(
                          () ->
                              p.call(
                                  p.budget(Duration.ofMillis(200)),
                                  () -> {
                                    started.countDown();
                                    while (release.getCount() != 0) {
                                      try {
                                        release.await();
                                      } catch (InterruptedException ignored) {
                                        interrupted.countDown();
                                      }
                                    }
                                    return "late-secret-result";
                                  }))
                      .hasMessage("MANAGED_PROVIDER_TIMEOUT");
                });
    assertThat(started.await(1, TimeUnit.SECONDS)).isTrue();
    first.get(2, TimeUnit.SECONDS);
    assertThat(interrupted.await(1, TimeUnit.SECONDS)).isTrue();
    assertThat(p.activeCalls()).isEqualTo(1);
    assertThat(p.queuedCalls()).isZero();
    var invoked = new AtomicInteger();
    assertThatThrownBy(() -> p.call(p.budget(Duration.ofMillis(100)), invoked::incrementAndGet))
        .hasMessage("MANAGED_PROVIDER_TIMEOUT");
    assertThat(invoked).hasValue(0);
    assertThat(p.activeCalls()).isEqualTo(1);
    assertThat(p.queuedCalls()).isLessThanOrEqualTo(1);
    release.countDown();
  }

  @Test
  void sequentialCallsCanHandOffWithoutSpuriousCapacityFailure() {
    var p = pool(1, System::nanoTime);
    var budget = p.budget(Duration.ofSeconds(2));
    for (int i = 0; i < 100; i++) assertThat(p.call(budget, () -> 1)).isEqualTo(1);
  }

  private static void awaitQueued(ManagedProviderCalls p) {
    long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(1);
    while (p.queuedCalls() != 1 && System.nanoTime() < until) Thread.yield();
    assertThat(p.queuedCalls()).isEqualTo(1);
  }

  @Test
  void incomingInterruptionIsPreservedWithoutStartingProvider() {
    var p = pool(1, System::nanoTime);
    var budget = p.budget(Duration.ofSeconds(1));
    var invoked = new AtomicInteger();
    Thread.currentThread().interrupt();
    assertThatThrownBy(() -> p.call(budget, invoked::incrementAndGet))
        .hasMessage("MANAGED_PROVIDER_INTERRUPTED");
    assertThat(Thread.currentThread().isInterrupted()).isTrue();
    assertThat(invoked).hasValue(0);
  }

  @Test
  void providerExceptionHasNoSecretMessageOrCause() {
    var p = pool(1, System::nanoTime);
    assertThatThrownBy(
            () ->
                p.call(
                    p.budget(Duration.ofSeconds(1)),
                    () -> {
                      throw new IllegalStateException("secret-provider-token");
                    }))
        .isInstanceOf(ManagedProviderCalls.Failure.class)
        .hasMessage("MANAGED_PROVIDER_FAILURE")
        .hasNoCause()
        .satisfies(error -> assertThat(error.getSuppressed()).isEmpty());
  }

  @Test
  void callerTransactionIsRejectedBeforeProviderStarts() {
    var p = pool(1, System::nanoTime);
    var budget = p.budget(Duration.ofSeconds(1));
    var invoked = new AtomicInteger();
    TransactionSynchronizationManager.setActualTransactionActive(true);
    assertThatThrownBy(() -> p.call(budget, invoked::incrementAndGet))
        .isInstanceOf(IllegalStateException.class);
    assertThat(invoked).hasValue(0);
  }

  @Test
  void interruptionWhileWaitingCancelsProviderAndPreservesCallerFlag() throws Exception {
    var p = pool(1, System::nanoTime);
    var started = new CountDownLatch(1);
    var release = release();
    var interrupted = new CountDownLatch(1);
    var finished = new CountDownLatch(1);
    var failure = new java.util.concurrent.atomic.AtomicReference<Throwable>();
    var thread =
        new Thread(
            () -> {
              try {
                assertThatThrownBy(
                        () ->
                            p.call(
                                p.budget(Duration.ofSeconds(2)),
                                () -> {
                                  started.countDown();
                                  try {
                                    release.await();
                                  } catch (InterruptedException expected) {
                                    interrupted.countDown();
                                    throw expected;
                                  }
                                  return "late";
                                }))
                    .hasMessage("MANAGED_PROVIDER_INTERRUPTED");
                assertThat(Thread.currentThread().isInterrupted()).isTrue();
              } catch (Throwable error) {
                failure.set(error);
              } finally {
                finished.countDown();
              }
            },
            "provider-budget-test-caller");
    thread.start();
    try {
      assertThat(started.await(1, TimeUnit.SECONDS)).isTrue();
      thread.interrupt();
      assertThat(finished.await(2, TimeUnit.SECONDS)).isTrue();
      assertThat(failure.get()).isNull();
      assertThat(interrupted.await(1, TimeUnit.SECONDS)).isTrue();
    } finally {
      release.countDown();
      thread.interrupt();
      thread.join(5000);
      assertThat(thread.isAlive()).isFalse();
    }
  }

  @Test
  void foreignBudgetCannotBeUsedByAnotherExecutor() {
    var first = pool(1, System::nanoTime);
    var second = pool(1, System::nanoTime);
    var budget = first.budget(Duration.ofSeconds(1));
    assertThatThrownBy(() -> second.call(budget, () -> "never"))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void closingRejectsNewBudgetsAndExistingBudgets() {
    var p = pool(1, System::nanoTime);
    var budget = p.budget(Duration.ofSeconds(1));
    p.close();
    p.close();
    assertThat(p.isClosed()).isTrue();
    assertThatThrownBy(() -> p.budget(Duration.ofSeconds(1)))
        .hasMessage("MANAGED_PROVIDER_UNAVAILABLE");
    assertThatThrownBy(() -> p.call(budget, () -> "never"))
        .hasMessage("MANAGED_PROVIDER_UNAVAILABLE");
  }

  @ParameterizedTest
  @ValueSource(ints = {0, -1, 33})
  void invalidWorkerCountsAreRejected(int workers) {
    assertThatThrownBy(
            () -> new ManagedProviderCalls(workers, Duration.ofSeconds(1), System::nanoTime))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @ParameterizedTest
  @ValueSource(longs = {0, -1, 30001})
  void invalidMaximumBudgetsAreRejected(long millis) {
    assertThatThrownBy(
            () -> new ManagedProviderCalls(1, Duration.ofMillis(millis), System::nanoTime))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @ParameterizedTest
  @ValueSource(longs = {0, -1})
  void expiredRemainingAuthorizationCannotCreateBudget(long millis) {
    var p = pool(1, System::nanoTime);
    assertThatThrownBy(() -> p.budget(Duration.ofMillis(millis)))
        .hasMessage("MANAGED_PROVIDER_TIMEOUT");
  }
}
