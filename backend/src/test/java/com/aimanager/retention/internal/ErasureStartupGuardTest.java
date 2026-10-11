package com.aimanager.retention.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

import com.aimanager.retention.ErasureLedger;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.SmartLifecycle;
import org.springframework.context.annotation.*;
import org.springframework.context.event.ContextRefreshedEvent;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;

class ErasureStartupGuardTest {
  static ErasureLedger ledger;
  static ErasureRecoveryJobs recovery;
  static AtomicInteger refreshed, started;
  static CountDownLatch scheduled;
  ApplicationContextRunner runner =
      new ApplicationContextRunner().withUserConfiguration(Fixture.class);

  @BeforeEach
  void setup() {
    ledger = mock(ErasureLedger.class);
    recovery = mock(ErasureRecoveryJobs.class);
    refreshed = new AtomicInteger();
    started = new AtomicInteger();
    scheduled = new CountDownLatch(1);
    when(ledger.head())
        .thenReturn(new ErasureLedger.Checkpoint(UUID.randomUUID().toString(), 0, "a".repeat(64)));
    when(recovery.reconcile(100))
        .thenAnswer(
            invocation -> {
              var head = ledger.head();
              return new ErasureRecoveryJobs.Batch(0, head, head, true);
            });
  }

  @Test
  void requiredMissingLedgerStopsBeforeLifecycleAndRefresh() {
    when(ledger.head()).thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_NOT_CONFIGURED"));
    runner
        .withPropertyValues("manager.erasure-recovery.required=true")
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .hasStackTraceContaining("ERASURE_LEDGER_NOT_CONFIGURED");
              assertThat(refreshed.get()).isZero();
              assertThat(started.get()).isZero();
              assertThat(scheduled.getCount()).isEqualTo(1);
            });
  }

  @Test
  void configuredUnavailableLedgerCannotStartEvenWithoutRequiredFlag() {
    when(ledger.head()).thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_UNAVAILABLE"));
    runner
        .withPropertyValues("manager.erasure-ledger.url=jdbc:mysql://ledger/erasure")
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .hasStackTraceContaining("ERASURE_LEDGER_UNAVAILABLE");
              assertThat(refreshed.get()).isZero();
              assertThat(started.get()).isZero();
            });
  }

  @Test
  void acceptedRecordsCannotBeMistakenForCompletedRecovery() {
    when(ledger.head())
        .thenReturn(new ErasureLedger.Checkpoint(UUID.randomUUID().toString(), 1, "b".repeat(64)));
    runner
        .withPropertyValues("manager.erasure-recovery.required=true")
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .hasStackTraceContaining("ERASURE_LEDGER_RECONCILIATION_REQUIRED");
              assertThat(refreshed.get()).isZero();
              assertThat(started.get()).isZero();
              verify(ledger, never()).readAfter(any(), anyInt());
              verify(ledger, never()).append(any());
              verify(recovery).reconcile(100);
            });
  }

  @Test
  void failedRecoveryPersistenceStopsBeforeAnyApplicationWork() {
    when(ledger.head())
        .thenReturn(new ErasureLedger.Checkpoint(UUID.randomUUID().toString(), 1, "b".repeat(64)));
    when(recovery.reconcile(100))
        .thenThrow(new ErasureLedger.Failure("ERASURE_RECOVERY_UNAVAILABLE"));
    runner
        .withPropertyValues("manager.erasure-recovery.required=true")
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .hasStackTraceContaining("ERASURE_RECOVERY_UNAVAILABLE");
              assertThat(refreshed.get()).isZero();
              assertThat(started.get()).isZero();
              assertThat(scheduled.getCount()).isEqualTo(1);
            });
  }

  @Test
  void verifiedEmptyLedgerAllowsLifecycleAndScheduledWork() {
    runner
        .withPropertyValues("manager.erasure-recovery.required=true")
        .run(
            context -> {
              assertThat(context).hasNotFailed();
              verify(ledger).head();
              verify(recovery).reconcile(100);
              assertThat(refreshed.get()).isEqualTo(1);
              assertThat(started.get()).isEqualTo(1);
              assertThat(scheduled.await(5, TimeUnit.SECONDS)).isTrue();
            });
  }

  @Test
  void unconfiguredSourceDevelopmentDoesNotPretendToCheckLedger() {
    runner.run(
        context -> {
          assertThat(context).hasNotFailed();
          verifyNoInteractions(ledger, recovery);
        });
  }

  @Test
  void globalLazyInitializationCannotBypassTheRequiredLedgerCheck() {
    when(ledger.head()).thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_NOT_CONFIGURED"));
    runner
        .withInitializer(
            context ->
                context.addBeanFactoryPostProcessor(
                    new org.springframework.boot.LazyInitializationBeanFactoryPostProcessor()))
        .withPropertyValues("manager.erasure-recovery.required=true")
        .run(
            context -> {
              assertThat(context).hasFailed();
              assertThat(context.getStartupFailure())
                  .hasStackTraceContaining("ERASURE_LEDGER_NOT_CONFIGURED");
              assertThat(started.get()).isZero();
              assertThat(refreshed.get()).isZero();
            });
  }

  @org.springframework.boot.test.context.TestConfiguration(proxyBeanMethods = false)
  @EnableScheduling
  @ComponentScan(
      basePackageClasses = ErasureStartupGuardTest.class,
      useDefaultFilters = false,
      includeFilters =
          @ComponentScan.Filter(
              type = FilterType.ASSIGNABLE_TYPE,
              classes = SmartInitializingSingleton.class))
  static class Fixture {
    @Bean
    ErasureLedger ledger() {
      return ledger;
    }

    @Bean
    ErasureRecoveryJobs recovery() {
      return recovery;
    }

    @Bean
    Probe probe() {
      return new Probe();
    }
  }

  static class Probe implements SmartLifecycle {
    boolean running;

    @Override
    public void start() {
      running = true;
      started.incrementAndGet();
    }

    @Override
    public void stop() {
      running = false;
    }

    @Override
    public boolean isRunning() {
      return running;
    }

    @EventListener
    void refresh(ContextRefreshedEvent ignored) {
      refreshed.incrementAndGet();
    }

    @Scheduled(fixedDelay = 100)
    public void scheduled() {
      scheduled.countDown();
    }
  }
}
