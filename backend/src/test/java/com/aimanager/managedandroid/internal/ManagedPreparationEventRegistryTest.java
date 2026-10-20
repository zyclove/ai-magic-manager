package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.awaitility.Awaitility.await;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedExecutionAdmission;
import com.aimanager.managedandroid.ManagedPreparationRequested;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import javax.sql.DataSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.modulith.events.IncompleteEventPublications;
import org.springframework.modulith.events.core.EventPublicationRepository;
import org.springframework.modulith.events.core.TargetEventPublication;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Actual admission/publication reader/JDBC/Modulith; lower qualification and worker are fixtures.
 */
@SpringBootTest(
    properties = {
      "spring.datasource.url=jdbc:h2:mem:preparation_events;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "spring.flyway.enabled=true",
      "manager.emm.execution.admission.enabled=true",
      "manager.emm.execution.preparation.enabled=true",
      "manager.emm.execution.preparation.recovery.enabled=true",
      "manager.emm.execution.dispatch.enabled=true",
      "manager.emm.execution.device-recovery.enabled=true",
      "manager.emm.execution.preparation.executor.workers=1",
      "manager.emm.execution.preparation.executor.queue-capacity=1",
      "manager.events.core-threads=1",
      "manager.events.max-threads=1",
      "manager.events.queue-capacity=1"
    })
class ManagedPreparationEventRegistryTest {
  @Autowired org.springframework.context.ApplicationContext context;
  @Autowired DataSource source;
  @Autowired JdbcTemplate db;
  @Autowired PlatformTransactionManager transactions;
  @Autowired ManagedExecutionAdmission admission;
  @Autowired IncompleteEventPublications incomplete;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean ManagedAgentBindingStore bindings;
  @Autowired ManagedAndroidGateway gateway;
  @MockitoBean ManagedPolicyDocumentCompilers compilers;
  @MockitoBean ManagedPreparationWorker worker;
  // This suite verifies durable event wiring. Downstream schedulers are inert fixtures,
  // explicitly present so the production startup consistency check remains enabled.
  @MockitoBean ManagedPreparationRecoveryJob preparationRecovery;
  @MockitoBean ManagedExecutionDispatchJob dispatch;
  @MockitoBean ManagedExecutionRecoveryJob observation;
  @MockitoSpyBean EventPublicationRepository repository;
  ManagedExecutionTestData data;
  ManagedExecutionTestData.Fixture fixture;
  TransactionTemplate tx;

  @TestConfiguration
  static class Provider {
    @Bean
    @Primary
    ManagedAndroidGateway preparationEventTestGateway() {
      // The provider selection guard runs before @BeforeEach. Register a valid local identity
      // at bean construction, preserving the production guard instead of disabling it.
      var gateway = mock(ManagedAndroidGateway.class);
      when(gateway.providerCode()).thenReturn("LOCAL_TEST");
      return gateway;
    }
  }

  @BeforeEach
  void setup() {
    data = new ManagedExecutionTestData(source);
    fixture = data.fixture();
    tx = new TransactionTemplate(transactions);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    when(gateway.providerCode()).thenReturn("LOCAL_TEST");
    when(gateway.available()).thenReturn(true);
    when(gateway.supportsExecutionProfiles()).thenReturn(true);
    when(gateway.supportsCompletePolicyDocuments()).thenReturn(true);
    when(gateway.supportsPolicyResourceAuthority()).thenReturn(true);
    when(gateway.policyResourceAuthorityRevision()).thenReturn("local-authority-v1");
    when(compilers.supports("LOCAL_TEST")).thenReturn(true);
    when(compilers.revision("LOCAL_TEST")).thenReturn("local-compiler-v1");
    var f = fixture;
    var context =
        new ManagedAgentBindingStore.VerifiedBindingContext(
            f.tenant(),
            f.actor(),
            0,
            f.subject(),
            f.device(),
            f.registration(),
            "a".repeat(64),
            f.binding(),
            2,
            f.enrollment(),
            1,
            "LOCAL_TEST",
            f.enterprise(),
            1,
            f.providerDevice(),
            "DEVICE_OWNER",
            2,
            "com.aimanager.child",
            "b".repeat(64),
            Device.Platform.ANDROID,
            1);
    when(bindings.requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2))
        .thenAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isTrue();
              db.queryForList(
                  "SELECT id FROM managed_agent_bindings WHERE tenant_id=? AND id=? FOR UPDATE",
                  f.tenant(),
                  f.binding());
              return context;
            });
  }

  private String publish() {
    return tx.execute(
        status -> {
          var publication = data.publication(fixture, "ENFORCE");
          admission.accept(publication.tenant(), publication.actor(), publication.publication());
          return db.queryForObject(
              "SELECT id FROM managed_policy_preparation_requests WHERE tenant_id=? AND"
                  + " publication_id=?",
              String.class,
              fixture.tenant(),
              publication.publication());
        });
  }

  private int outstanding() {
    return db.queryForObject(
        "SELECT COUNT(*) FROM event_publication WHERE serialized_event LIKE ?",
        Integer.class,
        "%" + fixture.tenant() + "%");
  }

  private long requests() {
    return db.queryForObject(
        "SELECT COUNT(*) FROM managed_policy_preparation_requests WHERE tenant_id=?",
        Long.class,
        fixture.tenant());
  }

  private long versions() {
    return db.queryForObject(
        "SELECT COUNT(*) FROM policy_versions WHERE tenant_id=?", Long.class, fixture.tenant());
  }

  private void eventually(Runnable assertion) {
    assertThatCode(() -> await().atMost(Duration.ofSeconds(3)).untilAsserted(assertion::run))
        .doesNotThrowAnyException();
  }

  @Test
  void requestAndReferenceEventExistInsideTheSameUncommittedTransaction() {
    var f = fixture;
    doThrow(new IllegalStateException("LOCAL_WAKEUP_FAILED"))
        .when(worker)
        .process(eq(f.tenant()), anyString());
    String request =
        tx.execute(
            status -> {
              var publication = data.publication(f, "ENFORCE");
              admission.accept(f.tenant(), f.actor(), publication.publication());
              assertThat(requests()).isEqualTo(1);
              assertThat(outstanding()).isEqualTo(1);
              verifyNoInteractions(worker);
              String serialized =
                  db.queryForObject(
                      "SELECT serialized_event FROM event_publication WHERE serialized_event LIKE"
                          + " ?",
                      String.class,
                      "%" + f.tenant() + "%");
              assertThat(serialized)
                  .contains("tenantId", "requestId")
                  .doesNotContain("actorId", "document", "bindingId", f.providerDevice());
              return db.queryForObject(
                  "SELECT id FROM managed_policy_preparation_requests WHERE tenant_id=?",
                  String.class,
                  f.tenant());
            });
    eventually(() -> verify(worker).process(f.tenant(), request));
    assertThat(outstanding()).isEqualTo(1);
  }

  @Test
  void rollbackRemovesVersionRequestAndRegisteredEvent() {
    long before = versions();
    assertThatThrownBy(
            () ->
                tx.executeWithoutResult(
                    status -> {
                      var publication = data.publication(fixture, "ENFORCE");
                      admission.accept(
                          fixture.tenant(), fixture.actor(), publication.publication());
                      assertThat(outstanding()).isEqualTo(1);
                      throw new IllegalStateException("OUTER_ROLLBACK");
                    }))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("OUTER_ROLLBACK");
    assertThat(versions()).isEqualTo(before);
    assertThat(requests()).isZero();
    assertThat(outstanding()).isZero();
    verifyNoInteractions(worker);
  }

  @Test
  void registryInsertFailureRollsBackTheWholePublication() {
    long before = versions();
    doAnswer(
            call -> {
              TargetEventPublication publication = call.getArgument(0);
              if (publication.getEvent() instanceof ManagedPreparationRequested)
                throw new IllegalStateException("EVENT_STORE_FAILED");
              return call.callRealMethod();
            })
        .when(repository)
        .create(any(TargetEventPublication.class));
    assertThatThrownBy(this::publish)
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("EVENT_STORE_FAILED");
    assertThat(versions()).isEqualTo(before);
    assertThat(requests()).isZero();
    assertThat(outstanding()).isZero();
    verifyNoInteractions(worker);
  }

  @Test
  void failedWakeupStaysDurableAndExplicitRetryDoesNotDuplicateRequests() {
    var calls = new AtomicInteger();
    doAnswer(
            call -> {
              if (calls.incrementAndGet() == 1)
                throw new IllegalStateException("LOCAL_WAKEUP_FAILED");
              return null;
            })
        .when(worker)
        .process(eq(fixture.tenant()), anyString());
    String request = publish();
    assertThat(outstanding()).isEqualTo(1);
    eventually(() -> assertThat(calls.get()).isEqualTo(1));
    incomplete.resubmitIncompletePublications(
        p ->
            p.getEvent() instanceof ManagedPreparationRequested event
                && event.tenantId().equals(fixture.tenant())
                && event.requestId().equals(request));
    eventually(() -> assertThat(outstanding()).isZero());
    assertThat(calls.get()).isEqualTo(2);
    assertThat(requests()).isEqualTo(1);
  }

  @Test
  void successfulWakeupRunsOutsideTransactionAndSeesOnlyCommittedRequests() {
    var checked = new AtomicBoolean();
    doAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
              assertThat(requests()).isEqualTo(1);
              checked.set(true);
              return null;
            })
        .when(worker)
        .process(eq(fixture.tenant()), anyString());
    publish();
    eventually(() -> assertThat(checked.get()).isTrue());
    eventually(() -> assertThat(outstanding()).isZero());
  }

  @Test
  void intakeReplayDoesNotCreateAnotherDurableWakeup() {
    doThrow(new IllegalStateException("LOCAL_WAKEUP_FAILED"))
        .when(worker)
        .process(eq(fixture.tenant()), anyString());
    publish();
    assertThat(outstanding()).isEqualTo(1);
    String publication =
        db.queryForObject(
            "SELECT publication_id FROM managed_policy_preparation_requests WHERE tenant_id=?",
            String.class,
            fixture.tenant());
    tx.executeWithoutResult(
        status -> admission.accept(fixture.tenant(), fixture.actor(), publication));
    assertThat(outstanding()).isEqualTo(1);
    assertThat(requests()).isEqualTo(1);
  }

  @Test
  void rejectedWakeupRetainsCommittedRequestAndCanBeResubmitted() throws Exception {
    String executorName =
        ManagedPreparationListener.class
            .getMethod("on", ManagedPreparationRequested.class)
            .getAnnotation(org.springframework.scheduling.annotation.Async.class)
            .value();
    var executor =
        context.getBean(
            executorName, org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor.class);
    var started = new java.util.concurrent.CountDownLatch(1);
    var release = new java.util.concurrent.CountDownLatch(1);
    long before = versions();
    try {
      executor.execute(
          () -> {
            started.countDown();
            try {
              release.await();
            } catch (InterruptedException interrupted) {
              Thread.currentThread().interrupt();
            }
          });
      assertThat(started.await(3, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
      executor.execute(() -> {});
      // A post-commit rejection may propagate through the event dispatcher; it cannot roll
      // back or mark complete the already committed business request and publication.
      try {
        publish();
      } catch (org.springframework.core.task.TaskRejectedException rejected) {
      }
      assertThat(versions()).isEqualTo(before + 1);
      assertThat(requests()).isEqualTo(1);
      assertThat(outstanding()).isEqualTo(1);
      verifyNoInteractions(worker);
    } finally {
      release.countDown();
    }
    eventually(
        () -> {
          assertThat(executor.getActiveCount()).isZero();
          assertThat(executor.getQueueSize()).isZero();
        });
    incomplete.resubmitIncompletePublications(
        p ->
            p.getEvent() instanceof ManagedPreparationRequested event
                && event.tenantId().equals(fixture.tenant()));
    eventually(() -> assertThat(outstanding()).isZero());
    verify(worker, times(1)).process(eq(fixture.tenant()), anyString());
    assertThat(requests()).isEqualTo(1);
    assertThat(versions()).isEqualTo(before + 1);
  }
}
