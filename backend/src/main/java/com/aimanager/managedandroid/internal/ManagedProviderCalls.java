package com.aimanager.managedandroid.internal;

import java.time.Duration;
import java.util.Objects;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.LongSupplier;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Dedicated bounded provider execution. A budget spans multiple calls, including queue time.
 * Cancellation ends caller waiting, not necessarily the underlying provider operation. Running
 * operations continue occupying the real executor until they actually return. Service integration
 * must retain database fencing and pre-write uncertainty checkpoints.
 */
final class ManagedProviderCalls implements AutoCloseable {
  enum Reason {
    TIMEOUT,
    CAPACITY,
    INTERRUPTED,
    UNAVAILABLE,
    PROVIDER_FAILURE
  }

  static final class Failure extends RuntimeException {
    private final Reason reason;

    Failure(Reason reason) {
      super(
          reason == Reason.PROVIDER_FAILURE
              ? "MANAGED_PROVIDER_FAILURE"
              : "MANAGED_PROVIDER_" + reason.name());
      this.reason = reason;
    }

    Reason reason() {
      return reason;
    }
  }

  static final class Budget {
    private final ManagedProviderCalls owner;
    private final long startedAt;
    private final long maximumNanos;

    private Budget(ManagedProviderCalls owner, long startedAt, long maximumNanos) {
      this.owner = owner;
      this.startedAt = startedAt;
      this.maximumNanos = maximumNanos;
    }

    @Override
    public String toString() {
      return "ManagedProviderBudget";
    }
  }

  private final ThreadPoolTaskExecutor executor;
  private final Duration maximumBudget;
  private final LongSupplier ticker;
  private final AtomicBoolean closed = new AtomicBoolean();

  ManagedProviderCalls(int workers, Duration maximumBudget, LongSupplier ticker) {
    Objects.requireNonNull(maximumBudget);
    Objects.requireNonNull(ticker);
    if (workers < 1
        || workers > 32
        || maximumBudget.compareTo(Duration.ofMillis(1)) < 0
        || maximumBudget.compareTo(Duration.ofSeconds(30)) > 0)
      throw new IllegalArgumentException("Invalid provider call executor configuration");
    this.maximumBudget = maximumBudget;
    this.ticker = ticker;
    executor = new ThreadPoolTaskExecutor();
    executor.setCorePoolSize(workers);
    executor.setMaxPoolSize(workers);
    // A bounded handoff allows a caller to submit its next read while the previous worker is
    // returning from Future completion. This is not a durable retry queue.
    executor.setQueueCapacity(workers);
    executor.setThreadNamePrefix("managed-provider-");
    executor.setRejectedExecutionHandler(new ThreadPoolExecutor.AbortPolicy());
    executor.setStrictEarlyShutdown(true);
    executor.setWaitForTasksToCompleteOnShutdown(false);
    executor.setAwaitTerminationMillis(1000);
    executor.initialize();
  }

  /** The supplied remaining authorization can shorten, but never enlarge, the configured budget. */
  Budget budget(Duration remaining) {
    requireOpen();
    Objects.requireNonNull(remaining);
    if (remaining.isZero() || remaining.isNegative()) throw failure(Reason.TIMEOUT);
    Duration bounded = remaining.compareTo(maximumBudget) > 0 ? maximumBudget : remaining;
    return new Budget(this, ticker.getAsLong(), bounded.toNanos());
  }

  <T> T call(Budget budget, Callable<T> operation) {
    Objects.requireNonNull(operation);
    if (budget == null || budget.owner != this)
      throw new IllegalArgumentException("Provider budget belongs to another executor");
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Provider calls require a separate transaction boundary");
    requireOpen();
    requireNotInterrupted();
    remaining(budget);
    Future<T> future;
    try {
      future =
          executor.submit(
              () -> {
                // Admission does not authorize starting an operation after it waited past its
                // deadline.
                requireOpen();
                requireNotInterrupted();
                remaining(budget);
                return operation.call();
              });
    } catch (RejectedExecutionException rejected) {
      throw failure(closed.get() ? Reason.UNAVAILABLE : Reason.CAPACITY);
    }
    try {
      T result = future.get(remaining(budget), TimeUnit.NANOSECONDS);
      requireOpen();
      requireNotInterrupted();
      remaining(budget);
      return result;
    } catch (InterruptedException interrupted) {
      Thread.currentThread().interrupt();
      future.cancel(true);
      throw failure(Reason.INTERRUPTED);
    } catch (TimeoutException timeout) {
      future.cancel(true);
      throw failure(Reason.TIMEOUT);
    } catch (ExecutionException failed) {
      // Never propagate the provider's message, response, cause or suppressed exceptions.
      if (closed.get()) throw failure(Reason.UNAVAILABLE);
      if (failed.getCause() instanceof Failure local) throw failure(local.reason());
      throw failure(Reason.PROVIDER_FAILURE);
    } catch (java.util.concurrent.CancellationException cancelled) {
      throw failure(closed.get() ? Reason.UNAVAILABLE : Reason.INTERRUPTED);
    } catch (Failure expiredOrClosed) {
      future.cancel(true);
      throw expiredOrClosed;
    }
  }

  /** Pure local check, also usable inside a short transaction before returning its result. */
  void check(Budget budget) {
    if (budget == null || budget.owner != this)
      throw new IllegalArgumentException("Provider budget belongs to another executor");
    requireOpen();
    requireNotInterrupted();
    remaining(budget);
  }

  private long remaining(Budget budget) {
    // Subtraction remains valid across nanoTime wraparound for these bounded (<31s) intervals.
    long left = budget.maximumNanos - (ticker.getAsLong() - budget.startedAt);
    if (left <= 0) throw failure(Reason.TIMEOUT);
    return left;
  }

  private void requireOpen() {
    if (closed.get()) throw failure(Reason.UNAVAILABLE);
  }

  private static void requireNotInterrupted() {
    if (Thread.currentThread().isInterrupted()) throw failure(Reason.INTERRUPTED);
  }

  private static Failure failure(Reason reason) {
    return new Failure(reason);
  }

  int activeCalls() {
    return executor.getActiveCount();
  }

  int queuedCalls() {
    return executor.getQueueSize();
  }

  boolean isClosed() {
    return closed.get();
  }

  boolean isTerminated() {
    return executor.getThreadPoolExecutor().isTerminated();
  }

  @Override
  public void close() {
    if (closed.compareAndSet(false, true)) executor.shutdown();
  }
}
