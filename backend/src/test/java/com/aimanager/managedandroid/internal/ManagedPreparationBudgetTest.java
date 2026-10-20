package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.shared.DomainException;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Real preparation transactions and provider-call executor; only provider facts are fixtures. */
class ManagedPreparationBudgetTest {
  ManagedPolicyPreparationPartnerTest f;
  ManagedProviderCalls calls;
  final AtomicLong ticks = new AtomicLong();
  ManagedPolicyPreparationService service;

  @BeforeEach
  void setup() {
    f = new ManagedPolicyPreparationPartnerTest();
    f.setup();
    calls = new ManagedProviderCalls(1, Duration.ofSeconds(2), ticks::get);
    service = service(calls);
  }

  @AfterEach
  void close() {
    Thread.interrupted();
    TransactionSynchronizationManager.setActualTransactionActive(false);
    calls.close();
    assertThat(calls.isTerminated()).isTrue();
    f.preparationNeverWritesToTheProvider();
  }

  private ManagedPolicyPreparationService service(ManagedProviderCalls executor) {
    return new ManagedPolicyPreparationService(
        f.bindings,
        f.enrollments,
        f.publications,
        f.gateway,
        new ManagedPolicyDocumentCompilers(List.of(f.new LocalCompiler())),
        new ManagedDeviceProfileSettings(f.clock, 600, 120, 15),
        ManagedPreparationTestQualifications.allow(),
        f.clock,
        f.transactions,
        "com.example.safe",
        executor);
  }

  private ManagedPolicyPreparationService.Prepared prepare(ManagedProviderCalls.Budget budget) {
    return service.prepare("tenant", "actor", "publication", "binding", 1, budget);
  }

  @Test
  void normalPreparationPreservesTheExactPublishedDocument() {
    var prepared = prepare(calls.budget(Duration.ofSeconds(1)));
    assertThat(prepared.document().documentJson())
        .contains("local-partner-v1", "com.example.lesson");
    assertThat(f.compilations).isEqualTo(1);
    verify(f.gateway, times(2)).readEnrollmentIdentity("e1", "d1");
  }

  @Test
  void readsRunOnTheDedicatedExecutorOutsideTransactions() {
    var identity = f.gateway.readEnrollmentIdentity("e1", "d1");
    clearInvocations(f.gateway);
    when(f.gateway.readEnrollmentIdentity("e1", "d1"))
        .thenAnswer(
            call -> {
              assertThat(Thread.currentThread().getName()).startsWith("managed-provider-");
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
              return identity;
            });
    assertThatCode(() -> prepare(calls.budget(Duration.ofSeconds(1)))).doesNotThrowAnyException();
  }

  @Test
  void allThreeReadsUseTheSameTotalBudget() {
    var identity = f.gateway.readEnrollmentIdentity("e1", "d1");
    var profile = f.gateway.readExecutionProfile("e1", "d1");
    clearInvocations(f.gateway);
    when(f.gateway.readEnrollmentIdentity("e1", "d1"))
        .thenAnswer(
            call -> {
              ticks.addAndGet(TimeUnit.MILLISECONDS.toNanos(700));
              return identity;
            });
    when(f.gateway.readExecutionProfile("e1", "d1"))
        .thenAnswer(
            call -> {
              ticks.addAndGet(TimeUnit.MILLISECONDS.toNanos(700));
              return profile;
            });
    assertThatThrownBy(() -> prepare(calls.budget(Duration.ofSeconds(2))))
        .isInstanceOf(DomainException.class)
        .hasMessage("MANAGED_PREPARATION_PROVIDER_UNAVAILABLE");
    assertThat(f.compilations).isZero();
  }

  @Test
  void expiredBudgetRejectsBeforeAnyContextOrProviderRead() {
    var budget = calls.budget(Duration.ofMillis(100));
    ticks.set(TimeUnit.MILLISECONDS.toNanos(100));
    clearInvocations(f.bindings, f.enrollments, f.publications, f.gateway);
    assertThatThrownBy(() -> prepare(budget)).isInstanceOf(DomainException.class);
    verifyNoInteractions(f.bindings, f.enrollments, f.publications, f.gateway);
  }

  @Test
  void contextCaptureTimeIsIncludedBeforeTheFirstRead() {
    when(f.publications.requireDesiredTarget(
            anyString(), anyString(), anyString(), anyString(), anyString()))
        .thenAnswer(
            call -> {
              ticks.set(TimeUnit.SECONDS.toNanos(2));
              return f.desired;
            });
    clearInvocations(f.gateway);
    assertThatThrownBy(() -> prepare(calls.budget(Duration.ofSeconds(2))))
        .isInstanceOf(DomainException.class);
    verify(f.gateway, never()).readEnrollmentIdentity(anyString(), anyString());
  }

  @Test
  void aClosedExecutorCannotProducePreparedPolicy() {
    var budget = calls.budget(Duration.ofSeconds(1));
    calls.close();
    assertThatThrownBy(() -> prepare(budget)).isInstanceOf(DomainException.class);
    assertThat(f.compilations).isZero();
  }

  @Test
  void incomingInterruptIsNotConvertedIntoAValidPreparation() {
    var budget = calls.budget(Duration.ofSeconds(1));
    Thread.currentThread().interrupt();
    assertThatThrownBy(() -> prepare(budget)).isInstanceOf(DomainException.class);
    assertThat(Thread.currentThread().isInterrupted()).isTrue();
    assertThat(f.compilations).isZero();
  }

  @Test
  void providerFailureRemainsSanitized() {
    when(f.gateway.readEnrollmentIdentity("e1", "d1"))
        .thenThrow(new IllegalStateException("secret-token"));
    assertThatThrownBy(() -> prepare(calls.budget(Duration.ofSeconds(1))))
        .isInstanceOf(DomainException.class)
        .hasMessage("MANAGED_PREPARATION_PROVIDER_UNAVAILABLE")
        .hasNoCause();
  }

  @Test
  void anOuterTransactionIsStillRejected() {
    var budget = calls.budget(Duration.ofSeconds(1));
    TransactionSynchronizationManager.setActualTransactionActive(true);
    assertThatThrownBy(() -> prepare(budget)).isInstanceOf(IllegalStateException.class);
  }

  @Test
  void blockingProviderTimesOutWithoutASecondReadOrCompilation() throws Exception {
    var release = new CountDownLatch(1);
    var started = new CountDownLatch(1);
    var identity = f.gateway.readEnrollmentIdentity("e1", "d1");
    clearInvocations(f.gateway);
    when(f.gateway.readEnrollmentIdentity("e1", "d1"))
        .thenAnswer(
            call -> {
              started.countDown();
              while (release.getCount() != 0) {
                try {
                  release.await();
                } catch (InterruptedException ignored) {
                }
              }
              return identity;
            });
    var waiter = Executors.newSingleThreadExecutor();
    try (var actual = new ManagedProviderCalls(1, Duration.ofMillis(200), System::nanoTime)) {
      service = service(actual);
      var result =
          waiter.submit(
              () -> {
                assertThatThrownBy(() -> prepare(actual.budget(Duration.ofSeconds(1))))
                    .isInstanceOf(DomainException.class)
                    .hasMessage("MANAGED_PREPARATION_PROVIDER_UNAVAILABLE");
              });
      try {
        assertThat(started.await(1, TimeUnit.SECONDS)).isTrue();
        assertThatCode(() -> result.get(2, TimeUnit.SECONDS)).doesNotThrowAnyException();
        assertThat(actual.activeCalls()).isEqualTo(1);
        verify(f.gateway, never()).readExecutionProfile(anyString(), anyString());
        assertThat(f.compilations).isZero();
      } finally {
        release.countDown();
      }
    } finally {
      release.countDown();
      waiter.shutdownNow();
      assertThat(waiter.awaitTermination(5, TimeUnit.SECONDS)).isTrue();
    }
  }
}
