package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

/** Real queue delay after the durable UNKNOWN checkpoint, before the provider mutation starts. */
class ManagedExecutionDispatchQueueBudgetTest {
  ManagedExecutionDispatchBudgetTest f;
  ExecutorService dispatcher;
  ExecutorService occupier;
  CountDownLatch release;

  @BeforeEach
  void setup() {
    f = new ManagedExecutionDispatchBudgetTest();
    f.setup();
    dispatcher = Executors.newSingleThreadExecutor();
    occupier = Executors.newSingleThreadExecutor();
    release = new CountDownLatch(1);
  }

  @AfterEach
  void close() throws Exception {
    release.countDown();
    dispatcher.shutdownNow();
    occupier.shutdownNow();
    try {
      assertThat(dispatcher.awaitTermination(2, TimeUnit.SECONDS)).isTrue();
      assertThat(occupier.awaitTermination(2, TimeUnit.SECONDS)).isTrue();
    } finally {
      f.close();
    }
  }

  @ParameterizedTest
  @CsvSource({
    "WRITE,EXPIRED",
    "WRITE,CONNECTOR",
    "WRITE,AUTHORITY",
    "ASSIGN,EXPIRED",
    "ASSIGN,CONNECTOR",
    "ASSIGN,AUTHORITY"
  })
  void queuedMutationRechecksCurrentAuthorityAtActualExecution(String action, String change)
      throws Exception {
    if (action.equals("ASSIGN")) f.assignment();
    var started = new CountDownLatch(1);
    var occupied = new AtomicReference<Future<Boolean>>();
    var journal = spy(f.f.journal);
    doAnswer(
            invocation -> {
              Object result = invocation.callRealMethod();
              // Occupy the sole provider worker after checkpoint commit and before dispatch submits
              // I/O.
              occupied.set(
                  occupier.submit(
                      () ->
                          f.calls.call(
                              f.calls.budget(Duration.ofSeconds(20)),
                              () -> {
                                started.countDown();
                                if (!release.await(5, TimeUnit.SECONDS))
                                  throw new IllegalStateException("Test worker was not released");
                                return true;
                              })));
              assertThat(started.await(2, TimeUnit.SECONDS)).isTrue();
              return result;
            })
        .when(journal)
        .beforeWrite(any(), anyLong());
    var service =
        new ManagedExecutionDispatchService(
            journal, f.authority, f.f.gateway, f.f.f.f.clock, f.calls, 10000);
    Future<Boolean> result = dispatcher.submit(() -> service.execute(f.claim()));
    try {
      // Earlier authority/inspection reads use this queue too. Observe only the mutation wait
      // after the checkpoint has committed and the occupier is actually running.
      assertThat(started.await(2, TimeUnit.SECONDS)).isTrue();
      long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
      while (f.calls.queuedCalls() == 0 && !result.isDone() && System.nanoTime() < deadline)
        Thread.sleep(1);
      assertThat(f.calls.activeCalls()).isEqualTo(1);
      assertThat(f.calls.queuedCalls()).isEqualTo(1);
      assertThat(result.isDone()).isFalse();
      if (change.equals("EXPIRED")) f.f.f.f.now.set(f.claim().leaseUntil());
      else if (change.equals("AUTHORITY"))
        when(f.f.f.f.sql.bindings.requireVerifiedContext(
                anyString(), anyString(), anyString(), anyLong()))
            .thenThrow(
                new com.aimanager.shared.DomainException(
                    org.springframework.http.HttpStatus.FORBIDDEN, "TEST_AUTHORITY_REVOKED"));
      else when(f.f.gateway.available()).thenReturn(false);
      release.countDown();
      assertThat(occupied.get().get(2, TimeUnit.SECONDS)).isTrue();
      assertThat(result.get(2, TimeUnit.SECONDS)).isFalse();
      assertThat(f.view().state())
          .isEqualTo(
              action.equals("WRITE")
                  ? ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN
                  : ManagedPolicyExecutionJournal.State.ASSIGNMENT_UNKNOWN);
      verify(f.f.gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
      verify(f.f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
    } finally {
      release.countDown();
    }
  }
}
