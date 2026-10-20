package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedPreparationRequested;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.FilterType;
import org.springframework.context.annotation.Import;
import org.springframework.core.task.TaskRejectedException;
import org.springframework.scheduling.annotation.Async;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Real Spring async dispatch and threads; no provider or database needed to test capacity. */
class ManagedPreparationExecutorTest {
  private final ApplicationContextRunner runner =
      new ApplicationContextRunner().withUserConfiguration(Context.class);

  @TestConfiguration(proxyBeanMethods = false)
  @EnableAsync
  @Import(ManagedPreparationListener.class)
  @ComponentScan(
      basePackageClasses = ManagedPreparationListener.class,
      useDefaultFilters = false,
      includeFilters =
          @ComponentScan.Filter(
              type = FilterType.REGEX,
              pattern =
                  "com\\.aimanager\\.managedandroid\\.internal\\.ManagedPreparationExecutorConfiguration"))
  static class Context {
    @Bean
    ManagedPreparationWorker worker() {
      return mock(ManagedPreparationWorker.class);
    }

    @Bean(name = "applicationTaskExecutor")
    ThreadPoolTaskExecutor general() {
      var executor = new ThreadPoolTaskExecutor();
      executor.setCorePoolSize(3);
      executor.setMaxPoolSize(3);
      executor.setQueueCapacity(16);
      executor.setThreadNamePrefix("general-fixture-");
      executor.setWaitForTasksToCompleteOnShutdown(true);
      return executor;
    }
  }

  private ApplicationContextRunner enabled() {
    return runner.withPropertyValues("manager.emm.execution.preparation.enabled=true");
  }

  private ThreadPoolTaskExecutor selected(ApplicationContext context) {
    try {
      String name =
          ManagedPreparationListener.class
              .getMethod("on", ManagedPreparationRequested.class)
              .getAnnotation(Async.class)
              .value();
      return context.getBean(name, ThreadPoolTaskExecutor.class);
    } catch (ReflectiveOperationException failure) {
      throw new AssertionError(failure);
    }
  }

  private void waitFor(CountDownLatch latch) {
    try {
      assertThat(latch.await(3, TimeUnit.SECONDS)).isTrue();
    } catch (InterruptedException interrupted) {
      Thread.currentThread().interrupt();
      throw new AssertionError(interrupted);
    }
  }

  private Runnable occupy(CountDownLatch started, CountDownLatch release) {
    return () -> {
      started.countDown();
      try {
        release.await();
      } catch (InterruptedException interrupted) {
        Thread.currentThread().interrupt();
      }
    };
  }

  @Test
  void disabledByDefaultDoesNotCreatePreparationExecutorOrListener() {
    runner.run(
        context -> {
          assertThat(context).hasNotFailed().doesNotHaveBean(ManagedPreparationListener.class);
          assertThat(context.containsBean("managedPreparationExecutor")).isFalse();
        });
  }

  @Test
  void defaultListenerUsesItsOwnFixedCapacityPool() {
    enabled()
        .run(
            context -> {
              var executor = selected(context);
              assertThat(executor).isNotSameAs(context.getBean("applicationTaskExecutor"));
              assertThat(executor.getCorePoolSize()).isEqualTo(2);
              assertThat(executor.getMaxPoolSize()).isEqualTo(2);
              assertThat(executor.getQueueCapacity()).isEqualTo(64);
            });
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "manager.emm.execution.preparation.executor.workers=0",
        "manager.emm.execution.preparation.executor.workers=17",
        "manager.emm.execution.preparation.executor.queue-capacity=0",
        "manager.emm.execution.preparation.executor.queue-capacity=1025"
      })
  void invalidEnabledCapacityFailsStartup(String property) {
    enabled()
        .withPropertyValues(property)
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .hasRootCauseInstanceOf(IllegalArgumentException.class);
            });
  }

  @Test
  void saturationRejectsWithoutCallerRunsAndQueuedWorkCanResume() {
    enabled()
        .withPropertyValues(
            "manager.emm.execution.preparation.executor.workers=1",
            "manager.emm.execution.preparation.executor.queue-capacity=1")
        .run(
            context -> {
              var executor = selected(context);
              var started = new CountDownLatch(1);
              var release = new CountDownLatch(1);
              var queued = new CountDownLatch(1);
              var accidental = new AtomicBoolean();
              try {
                executor.execute(occupy(started, release));
                waitFor(started);
                executor.execute(queued::countDown);
                assertThatThrownBy(() -> executor.execute(() -> accidental.set(true)))
                    .isInstanceOf(TaskRejectedException.class);
                assertThat(accidental).isFalse();
                assertThat(executor.getActiveCount()).isEqualTo(1);
                assertThat(executor.getQueueSize()).isEqualTo(1);
                release.countDown();
                waitFor(queued);
              } finally {
                release.countDown();
              }
            });
  }

  @Test
  void generalEventSaturationCannotPreventPreparationWakeup() {
    enabled()
        .run(
            context -> {
              var general =
                  context.getBean("applicationTaskExecutor", ThreadPoolTaskExecutor.class);
              var started = new CountDownLatch(3);
              var release = new CountDownLatch(1);
              var processed = new CountDownLatch(1);
              doAnswer(
                      call -> {
                        processed.countDown();
                        return null;
                      })
                  .when(context.getBean(ManagedPreparationWorker.class))
                  .process("tenant", "request");
              try {
                for (int i = 0; i < 3; i++) general.execute(occupy(started, release));
                waitFor(started);
                for (int i = 0; i < 16; i++) general.execute(() -> {});
                assertThatCode(
                        () ->
                            context
                                .getBean(ManagedPreparationListener.class)
                                .on(new ManagedPreparationRequested("tenant", "request")))
                    .doesNotThrowAnyException();
                waitFor(processed);
              } finally {
                release.countDown();
              }
            });
  }

  @Test
  void asynchronousWorkerUsesDedicatedThreadWithoutCallerTransaction() {
    enabled()
        .run(
            context -> {
              var worker = context.getBean(ManagedPreparationWorker.class);
              var processed = new CountDownLatch(1);
              var thread = new AtomicReference<String>();
              var active = new AtomicBoolean(true);
              doAnswer(
                      call -> {
                        thread.set(Thread.currentThread().getName());
                        active.set(TransactionSynchronizationManager.isActualTransactionActive());
                        processed.countDown();
                        return null;
                      })
                  .when(worker)
                  .process("tenant", "request");
              TransactionSynchronizationManager.setActualTransactionActive(true);
              try {
                context
                    .getBean(ManagedPreparationListener.class)
                    .on(new ManagedPreparationRequested("tenant", "request"));
              } finally {
                TransactionSynchronizationManager.setActualTransactionActive(false);
              }
              waitFor(processed);
              assertThat(thread.get()).startsWith("managed-preparation-");
              assertThat(active).isFalse();
            });
  }

  @Test
  void shutdownCancelsQueuedWorkAndRejectsNewSubmissions() {
    enabled()
        .withPropertyValues(
            "manager.emm.execution.preparation.executor.workers=1",
            "manager.emm.execution.preparation.executor.queue-capacity=1")
        .run(
            context -> {
              var executor = selected(context);
              int workers = executor.getMaxPoolSize();
              var started = new CountDownLatch(workers);
              var release = new CountDownLatch(1);
              var queuedRan = new AtomicBoolean();
              Future<?> queued = null;
              try {
                for (int i = 0; i < workers; i++) executor.execute(occupy(started, release));
                waitFor(started);
                queued = executor.submit(() -> queuedRan.set(true));
                // Exercise actual context shutdown, including early-shutdown and lifecycle hooks.
                context.getSourceApplicationContext().close();
                assertThat(queued.isCancelled()).isTrue();
                assertThat(queuedRan).isFalse();
                assertThatThrownBy(() -> executor.execute(() -> {}))
                    .isInstanceOf(TaskRejectedException.class);
              } finally {
                release.countDown();
                executor.shutdown();
                try {
                  assertThat(executor.getThreadPoolExecutor().awaitTermination(3, TimeUnit.SECONDS))
                      .isTrue();
                } catch (InterruptedException interrupted) {
                  Thread.currentThread().interrupt();
                  throw new AssertionError(interrupted);
                }
              }
            });
  }
}
