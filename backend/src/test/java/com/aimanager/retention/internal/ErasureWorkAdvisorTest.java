package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.aimanager.retention.ErasureLedger;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import org.junit.jupiter.api.Test;
import org.springframework.context.*;
import org.springframework.context.annotation.*;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.*;
import org.springframework.transaction.annotation.EnableTransactionManagement;

class ErasureWorkAdvisorTest {
  @Test
  void realSpringAdviceProtectsScheduledAndEventEntrypoints() {
    try (var context = new AnnotationConfigApplicationContext(Fixture.class)) {
      var ledger = context.getBean(ErasureLedger.class);
      var jobs = context.getBean(Jobs.class);
      var permit = mock(ErasureLedger.WorkPermit.class);
      when(ledger.beginWork(anyString())).thenReturn(permit);
      jobs.scheduled();
      assertEquals(1, jobs.calls());
      verify(permit).close();
      when(ledger.beginWork(anyString()))
          .thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_WORK_PAUSED"));
      jobs.scheduled();
      assertEquals(1, jobs.calls());
      assertThrows(ErasureLedger.Failure.class, () -> context.publishEvent(new Probe()));
      assertThrows(
          ErasureLedger.Failure.class, () -> context.publishEvent(new TransactionalProbe()));
      assertEquals(0, jobs.events());
    }
  }

  @Test
  void synchronousNestedEventReusesTheOuterPermit() {
    try (var context = new AnnotationConfigApplicationContext(Fixture.class)) {
      var ledger = context.getBean(ErasureLedger.class);
      var permit = mock(ErasureLedger.WorkPermit.class);
      when(ledger.beginWork(anyString())).thenReturn(permit);
      context.getBean(Jobs.class).nested();
      verify(ledger).beginWork(anyString());
      verify(permit).close();
      assertEquals(1, context.getBean(Jobs.class).events());
    }
  }

  @Test
  void asynchronousExecutionAcquiresPermitOnExecutorThreadAndPropagatesRejection()
      throws Exception {
    try (var context = new AnnotationConfigApplicationContext(Fixture.class)) {
      var ledger = context.getBean(ErasureLedger.class);
      var permit = mock(ErasureLedger.WorkPermit.class);
      var entered = new AtomicReference<Thread>();
      when(ledger.beginWork(anyString()))
          .thenAnswer(
              i -> {
                entered.set(Thread.currentThread());
                return permit;
              });
      var jobs = context.getBean(Jobs.class);
      assertEquals("done", jobs.async().get(5, TimeUnit.SECONDS));
      assertNotSame(Thread.currentThread(), entered.get());
      assertSame(entered.get(), jobs.thread());
      verify(permit).close();
      when(ledger.beginWork(anyString()))
          .thenThrow(new ErasureLedger.Failure("ERASURE_LEDGER_UNAVAILABLE"));
      var rejected =
          assertThrows(ExecutionException.class, () -> jobs.async().get(5, TimeUnit.SECONDS));
      assertInstanceOf(ErasureLedger.Failure.class, rejected.getCause());
      assertEquals(1, jobs.asyncCalls());
    }
  }

  @Test
  void deferredFutureKeepsItsPermitUntilActualCompletion() throws Exception {
    try (var context = new AnnotationConfigApplicationContext(Fixture.class)) {
      var ledger = context.getBean(ErasureLedger.class);
      var permit = mock(ErasureLedger.WorkPermit.class);
      when(ledger.beginWork(anyString())).thenReturn(permit);
      var jobs = context.getBean(Jobs.class);
      var pending = new CompletableFuture<String>();
      var result = jobs.deferred(pending);
      assertTrue(jobs.started().await(5, TimeUnit.SECONDS));
      verifyNoInteractions(permit);
      assertFalse(result.isDone());
      pending.complete("finished");
      assertEquals("finished", result.get(5, TimeUnit.SECONDS));
      verify(permit).close();
    }
  }

  @Test
  void cancelledFutureCannotReleaseAnOperationWhoseActualCompletionIsUnknown() throws Exception {
    try (var context = new AnnotationConfigApplicationContext(Fixture.class)) {
      var ledger = context.getBean(ErasureLedger.class);
      var permit = mock(ErasureLedger.WorkPermit.class);
      var next = mock(ErasureLedger.WorkPermit.class);
      when(ledger.beginWork(anyString())).thenReturn(permit, next);
      var jobs = context.getBean(Jobs.class);
      var pending = new CompletableFuture<String>();
      var result = jobs.deferred(pending);
      assertTrue(jobs.started().await(5, TimeUnit.SECONDS));
      pending.cancel(false);
      var failed = assertThrows(ExecutionException.class, () -> result.get(5, TimeUnit.SECONDS));
      assertInstanceOf(ErasureLedger.Failure.class, failed.getCause());
      verifyNoInteractions(permit);
      assertEquals("done", jobs.async().get(5, TimeUnit.SECONDS));
      verify(next).close();
      verify(ledger, times(2)).beginWork(anyString());
    }
  }

  @Test
  void exceptionalFutureCannotAcceptErasureWhileItsProducerStillRuns() throws Exception {
    var data = new ErasureAdmissionStoreTest();
    data.setup();
    var releaseProducer = new CountDownLatch(1);
    var producerStarted = new CountDownLatch(1);
    var producerFinished = new AtomicBoolean();
    var pending = new CompletableFuture<String>();
    var producer =
        CompletableFuture.runAsync(
            () -> {
              producerStarted.countDown();
              try {
                releaseProducer.await();
                producerFinished.set(true);
                pending.complete("finished");
              } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new CompletionException(interrupted);
              }
            });
    try (var context = new AnnotationConfigApplicationContext(Fixture.class)) {
      var ledger = context.getBean(ErasureLedger.class);
      when(ledger.beginWork(anyString()))
          .thenAnswer(invocation -> data.first.beginWork(invocation.getArgument(0)));
      var jobs = context.getBean(Jobs.class);
      var result = jobs.deferred(pending);
      assertTrue(producerStarted.await(5, TimeUnit.SECONDS));
      assertTrue(jobs.started().await(5, TimeUnit.SECONDS));
      var request = data.request();
      data.failure("ERASURE_LEDGER_WORK_ACTIVE", () -> data.second.append(request));
      pending.completeExceptionally(new TimeoutException("Producer is still running"));
      var failed = assertThrows(ExecutionException.class, () -> result.get(5, TimeUnit.SECONDS));
      assertFalse(producerFinished.get());
      assertEquals(1, data.active(), "Exceptional Future completion must not drain the producer");
      assertEquals(
          "ERASURE_LEDGER_WORK_COMPLETION_UNKNOWN",
          assertInstanceOf(ErasureLedger.Failure.class, failed.getCause()).code());
      data.failure("ERASURE_LEDGER_WORK_ACTIVE", () -> data.second.append(request));
      var next =
          assertThrows(ExecutionException.class, () -> jobs.async().get(5, TimeUnit.SECONDS));
      assertEquals(
          "ERASURE_LEDGER_WORK_PAUSED",
          assertInstanceOf(ErasureLedger.Failure.class, next.getCause()).code());
      verify(ledger, times(2)).beginWork(anyString());
      assertEquals(0, jobs.asyncCalls());
      releaseProducer.countDown();
      producer.get(5, TimeUnit.SECONDS);
      assertTrue(producerFinished.get());
      assertEquals(1, data.active(), "Uncertain work requires a separate safe recovery proof");
      data.failure("ERASURE_LEDGER_WORK_ACTIVE", () -> data.second.append(request));
    } finally {
      releaseProducer.countDown();
      producer.get(5, TimeUnit.SECONDS);
    }
  }

  @Configuration(proxyBeanMethods = false)
  @EnableTransactionManagement
  @EnableAsync
  @Import(ErasureRuntimeConfiguration.class)
  static class Fixture {
    @Bean
    ErasureLedger ledger() {
      return mock(ErasureLedger.class);
    }

    @Bean
    ErasureWorkScope scope(ErasureLedger ledger) {
      return new ErasureWorkScope(ledger, true, "");
    }

    @Bean
    ObjectMapper json() {
      return new ObjectMapper();
    }

    @Bean
    Jobs jobs(ApplicationEventPublisher publisher) {
      return new Jobs(publisher);
    }

    @Bean(destroyMethod = "shutdown")
    ExecutorService testExecutor() {
      return Executors.newSingleThreadExecutor();
    }
  }

  record Probe() {}

  record TransactionalProbe() {}

  static class Jobs {
    final AtomicInteger calls = new AtomicInteger(),
        events = new AtomicInteger(),
        asyncCalls = new AtomicInteger();
    final AtomicReference<Thread> thread = new AtomicReference<>();
    final CountDownLatch started = new CountDownLatch(1);
    private final ApplicationEventPublisher publisher;

    Jobs(ApplicationEventPublisher publisher) {
      this.publisher = publisher;
    }

    public int calls() {
      return calls.get();
    }

    public int events() {
      return events.get();
    }

    public int asyncCalls() {
      return asyncCalls.get();
    }

    public Thread thread() {
      return thread.get();
    }

    public CountDownLatch started() {
      return started;
    }

    @Scheduled(fixedDelay = 60000)
    public void scheduled() {
      calls.incrementAndGet();
    }

    @Scheduled(fixedDelay = 60000)
    public void nested() {
      publisher.publishEvent(new Probe());
    }

    @EventListener
    public void event(Probe probe) {
      events.incrementAndGet();
    }

    @org.springframework.transaction.event.TransactionalEventListener(fallbackExecution = true)
    public void transactionalEvent(TransactionalProbe probe) {
      events.incrementAndGet();
    }

    @Async("testExecutor")
    public CompletableFuture<String> async() {
      thread.set(Thread.currentThread());
      asyncCalls.incrementAndGet();
      return CompletableFuture.completedFuture("done");
    }

    @Async("testExecutor")
    public CompletableFuture<String> deferred(CompletableFuture<String> pending) {
      started.countDown();
      return pending;
    }
  }
}
