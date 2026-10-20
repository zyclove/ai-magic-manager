package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.*;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.Instant;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Actual request/execution SQL and atomic rollback; lower qualification and compiler are fixtures.
 */
class ManagedPreparationHandoffTest {
  private static final String DOCUMENT =
      "{\"adapterRevision\":\"local-v1\",\"policy\":{\"applications\":[]},\"schemaVersion\":1}";
  private static final String OTHER_DOCUMENT =
      "{\"adapterRevision\":\"local-v1\",\"policy\":{\"applications\":[],\"cameraDisabled\":true},\"schemaVersion\":1}";
  ManagedPreparationRequestJournalTest lease;
  ManagedPolicyExecutionJournalTest sql;
  ManagedExecutionTestData.Fixture f;
  ManagedPreparationRequestJournal requests;
  ManagedPolicyExecutionJournal executions;
  ManagedPreparationHandoffService service;
  ManagedPreparationRequestJournal.Claim claim;
  ManagedPolicyControlAdmission controls;
  ManagedPolicyDocumentCompilers compilers;
  ManagedAndroidGateway gateway;
  ManagedPolicyPreparationService.Prepared prepared;
  ManagedDesiredPolicy desired;
  ManagedAndroidGateway.PolicyDocument document;
  ManagedPolicyControlAdmission.Checked checked;
  ManagedDeviceExecutionVerifier.Verified profile;
  AtomicLong now;
  Clock clock;
  String cancellingActor;

  @BeforeEach
  void setup() {
    lease = new ManagedPreparationRequestJournalTest();
    lease.setup();
    sql = lease.intake.f;
    f = sql.f;
    cancellingActor = "canceller-" + ManagedExecutionTestData.id();
    sql.db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'ORG_ADMIN')",
        f.tenant(),
        cancellingActor,
        com.aimanager.identity.ActorKeys.key(cancellingActor));
    requests = lease.journal;
    executions = sql.journal;
    claim = requests.claim(f.tenant(), lease.request);
    now = new AtomicLong(System.currentTimeMillis());
    clock = mock(Clock.class);
    when(clock.millis()).thenAnswer(call -> now.get());
    when(clock.instant()).thenAnswer(call -> Instant.ofEpochMilli(now.get()));
    desired =
        new ManagedDesiredPolicy(
            new ManagedExecutionPublicationAccess.Publication(f.version(), "c".repeat(64), 1),
            f.device(),
            f.registration(),
            List.of(),
            List.of(),
            List.of());
    when(sql.publications.requireDesiredTarget(
            f.tenant(), f.actor(), f.publication(), f.device(), f.registration()))
        .thenReturn(desired);
    profile =
        new ManagedDeviceExecutionVerifier.Verified(
            "enterprises/" + f.enterprise() + "/devices/" + f.providerDevice(),
            "DEVICE_OWNER",
            30,
            Instant.ofEpochMilli(now.get() - 1000),
            Instant.ofEpochMilli(now.get()),
            Instant.ofEpochMilli(now.get() + 60000));
    checked = new ManagedPolicyControlAdmission.Checked(List.of(), List.of(), Long.MAX_VALUE);
    document =
        document(
            DOCUMENT,
            SecretMaterial.hash(DOCUMENT),
            sql.context.agentPackageName(),
            30,
            "DEVICE_OWNER");
    controls = mock(ManagedPolicyControlAdmission.class);
    when(controls.check(any(), any()))
        .thenAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isTrue();
              return checked;
            });
    compilers = mock(ManagedPolicyDocumentCompilers.class);
    when(compilers.supports("LOCAL_TEST")).thenReturn(true);
    when(compilers.revision("LOCAL_TEST")).thenReturn("local-v1");
    when(compilers.compile(anyString(), anyString(), any(), any(), anySet())).thenReturn(document);
    gateway = lease.intake.gateway;
    prepared = result("VALID");
    rebuildService();
  }

  @AfterEach
  void close() {
    lease.close();
  }

  private void rebuildService() {
    service =
        new ManagedPreparationHandoffService(
            requests,
            executions,
            sql.publications,
            controls,
            compilers,
            gateway,
            clock,
            sql.data.transactions,
            "");
  }

  private ManagedPolicyExecutionJournal.View complete() {
    try {
      return service.complete(claim, prepared);
    } catch (UnsupportedOperationException missing) {
      if ("MANAGED_PREPARATION_HANDOFF_NOT_IMPLEMENTED".equals(missing.getMessage()))
        throw new AssertionError(missing.getMessage(), missing);
      throw missing;
    }
  }

  private long tasks() {
    return sql.db.queryForObject(
        "SELECT COUNT(*) FROM managed_policy_execution_tasks WHERE tenant_id=?",
        Long.class,
        f.tenant());
  }

  private Map<String, Object> row() {
    return lease.row();
  }

  private void rejected() {
    var before = row();
    assertThatThrownBy(this::complete).isInstanceOf(DomainException.class);
    assertThat(tasks()).isZero();
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void completeTaskAndPreparationLinkCommitTogetherWithoutAnyProviderIo() {
    var task = complete();
    assertThat(task.state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
    assertThat(tasks()).isEqualTo(1);
    assertThat(row().get("state")).isEqualTo("ADMITTED");
    assertThat(row().get("execution_task_id")).isEqualTo(task.id());
    assertThat(row().get("active_device_id")).isNull();
    assertThat(row().get("lease_token")).isNull();
    var stored =
        sql.db.queryForMap(
            "SELECT * FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=?",
            f.tenant(),
            task.id());
    for (var field :
        List.of(
            "tenant_id",
            "publication_id",
            "policy_version_id",
            "subject_id",
            "device_id",
            "registration_id",
            "binding_id",
            "binding_version",
            "actor_id",
            "authority_version",
            "context_sha256")) assertThat(stored.get(field)).as(field).isEqualTo(row().get(field));
    assertThat(stored.get("document_json")).isEqualTo(DOCUMENT);
    assertThat(stored.get("document_sha256")).isEqualTo(SecretMaterial.hash(DOCUMENT));
    assertThat(stored.get("active_device_id")).isEqualTo(f.device());
    assertThat(((Number) stored.get("expires_at")).longValue())
        .isEqualTo(((Number) row().get("expires_at")).longValue());
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
    verify(gateway, never()).readExecutionProfile(anyString(), anyString());
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "PUBLICATION",
        "BINDING",
        "VERSION",
        "DEVICE",
        "REGISTRATION",
        "DOCUMENT",
        "DIGEST",
        "AGENT",
        "API",
        "MODE",
        "PROFILE_DEVICE",
        "PROFILE_EXPIRED",
        "CONTROL_EXPIRED",
        "DESIRED_CONTENT",
        "PROFILE_MODE",
        "PROFILE_API"
      })
  void incompleteOrMismatchedResultCannotCreateATask(String change) {
    prepared = result(change);
    rejected();
  }

  @Test
  void currentApplicationQualificationsMustStillEqualThePreparedEvidence() {
    checked = new ManagedPolicyControlAdmission.Checked(List.of(), List.of(), now.get() + 50000);
    rejected();
  }

  @Test
  void currentCompilerMustStillProduceTheExactCompleteDocument() {
    when(compilers.compile(anyString(), anyString(), any(), any(), anySet()))
        .thenReturn(
            document(
                OTHER_DOCUMENT,
                SecretMaterial.hash(OTHER_DOCUMENT),
                sql.context.agentPackageName(),
                30,
                "DEVICE_OWNER"));
    rejected();
  }

  @Test
  void evidenceExpiringDuringCompilationCannotBeHandedOff() {
    when(compilers.compile(anyString(), anyString(), any(), any(), anySet()))
        .thenAnswer(
            call -> {
              now.addAndGet(120000);
              return document;
            });
    rejected();
  }

  @Test
  void cancellationBeforeHandoffPreservesTheCancelledRequest() {
    requests.cancel(f.tenant(), f.actor(), lease.request, claim.revision());
    rejected();
  }

  @Test
  void revokedAuthorityCannotCreateATask() {
    sql.db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    rejected();
  }

  @Test
  void expiredLeaseCannotCreateATask() {
    sql.db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " created_at=1,next_attempt_at=1,lease_until=2 WHERE tenant_id=? AND id=?",
        f.tenant(),
        lease.request);
    rejected();
  }

  @Test
  void aReclaimedLeaseCannotAcceptTheOldResult() {
    sql.db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " created_at=1,next_attempt_at=1,lease_until=2 WHERE tenant_id=? AND id=?",
        f.tenant(),
        lease.request);
    var next = requests.claim(f.tenant(), lease.request);
    assertThat(next.generation()).isGreaterThan(claim.generation());
    rejected();
  }

  @Test
  void executionAuditFailureRollsBackBothSides() {
    doThrow(new IllegalStateException("TEST_EXECUTION_AUDIT_FAILED"))
        .when(sql.audit)
        .record(eq(f.tenant()), eq(f.actor()), eq("MANAGED_EXECUTION_QUEUED"), anyString());
    var before = row();
    assertThatThrownBy(this::complete)
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("TEST_EXECUTION_AUDIT_FAILED");
    assertThat(tasks()).isZero();
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void preparationAuditFailureRollsBackTheAlreadyInsertedTask() {
    doThrow(new IllegalStateException("TEST_PREPARATION_AUDIT_FAILED"))
        .when(sql.audit)
        .record(f.tenant(), f.actor(), "PREPARATION_ADMITTED", lease.request);
    var before = row();
    assertThatThrownBy(this::complete)
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("TEST_PREPARATION_AUDIT_FAILED");
    assertThat(tasks()).isZero();
    assertThat(row()).isEqualTo(before);
    assertThat(
            sql.db.queryForObject(
                "SELECT COUNT(*) FROM managed_policy_execution_events WHERE tenant_id=?",
                Long.class,
                f.tenant()))
        .isZero();
  }

  @Test
  void linkingFailureRollsBackTheAlreadyInsertedTask() {
    JdbcTemplate failing = spy(sql.db);
    doAnswer(
            call -> {
              String statement = call.getArgument(0);
              Object[] values = (Object[]) call.getRawArguments()[1];
              if (statement.contains("UPDATE managed_policy_preparation_requests")
                  && (statement.contains("'ADMITTED'")
                      || Arrays.asList(values).contains("ADMITTED")))
                throw new DataAccessResourceFailureException("TEST_LINK_WRITE_FAILED");
              return call.callRealMethod();
            })
        .when(failing)
        .update(anyString(), any(Object[].class));
    requests =
        new ManagedPreparationRequestJournal(
            failing,
            sql.bindings,
            sql.publications,
            new TenantAccess(failing),
            sql.audit,
            sql.data.transactions,
            new ObjectMapper(),
            30,
            3,
            5);
    executions =
        new ManagedPolicyExecutionJournal(
            failing,
            sql.bindings,
            sql.publications,
            new TenantAccess(failing),
            sql.audit,
            new ManagedPolicyExecutionSettings(30, 24, 1),
            sql.data.transactions);
    rebuildService();
    var before = row();
    assertThatThrownBy(this::complete)
        .isInstanceOf(DataAccessResourceFailureException.class)
        .hasMessage("TEST_LINK_WRITE_FAILED");
    assertThat(tasks()).isZero();
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void replayedOldResultCannotCreateASecondTask() {
    var first = complete();
    var before = row();
    assertThatThrownBy(this::complete).isInstanceOf(DomainException.class);
    assertThat(tasks()).isEqualTo(1);
    assertThat(row()).isEqualTo(before);
    assertThat(row().get("execution_task_id")).isEqualTo(first.id());
  }

  @Test
  void admittedRequestDirectsCancellationToTheExecutionTask() {
    var task = complete();
    long revision = ((Number) row().get("revision")).longValue();
    assertThatThrownBy(() -> requests.cancel(f.tenant(), f.actor(), lease.request, revision))
        .isInstanceOf(DomainException.class)
        .hasMessage("PREPARATION_ALREADY_ADMITTED");
    assertThat(executions.get(f.tenant(), f.actor(), task.id()).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
  }

  @Test
  void handoffCannotJoinAnUnknownOuterTransaction() {
    assertThatThrownBy(() -> lease.intake.tx.executeWithoutResult(status -> complete()))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Preparation handoff requires a separate transaction");
    assertThat(tasks()).isZero();
  }

  @Test
  void absentPreparedResultCannotCreateATask() {
    prepared = null;
    rejected();
  }

  @Test
  void anotherTenantCannotUseThisPreparationClaim() {
    claim =
        new ManagedPreparationRequestJournal.Claim(
            ManagedExecutionTestData.id(),
            claim.requestId(),
            claim.token(),
            claim.generation(),
            claim.leaseUntil(),
            claim.revision(),
            claim.publicationId(),
            claim.binding());
    rejected();
  }

  @Test
  void handoffHoldingTheRequestLockWinsBeforeConcurrentStaleCancellation() throws Exception {
    var entered = new CountDownLatch(1);
    var release = new CountDownLatch(1);
    var cancellationStarted = new CountDownLatch(1);
    var executor = Executors.newFixedThreadPool(2);
    when(compilers.compile(anyString(), anyString(), any(), any(), anySet()))
        .thenAnswer(
            call -> {
              entered.countDown();
              if (!release.await(3, TimeUnit.SECONDS))
                throw new AssertionError("HANDOFF_RELEASE_TIMEOUT");
              return document;
            });
    try {
      var handing = executor.submit(this::complete);
      assertThat(entered.await(3, TimeUnit.SECONDS)).isTrue();
      var cancelling =
          executor.submit(
              () -> {
                cancellationStarted.countDown();
                return catchThrowable(
                    () ->
                        requests.cancel(
                            f.tenant(), cancellingActor, lease.request, claim.revision()));
              });
      assertThat(cancellationStarted.await(3, TimeUnit.SECONDS)).isTrue();
      release.countDown();
      assertThat(handing.get(4, TimeUnit.SECONDS).state())
          .isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
      assertThat(cancelling.get(4, TimeUnit.SECONDS))
          .isInstanceOf(DomainException.class)
          .hasMessage("RESOURCE_VERSION_CONFLICT");
      assertThat(row().get("state")).isEqualTo("ADMITTED");
      assertThat(tasks()).isEqualTo(1);
    } finally {
      release.countDown();
      executor.shutdownNow();
      assertThat(executor.awaitTermination(4, TimeUnit.SECONDS)).isTrue();
    }
  }

  @Test
  void cancellationHoldingTheRequestLockPreventsConcurrentHandoff() throws Exception {
    var cancelled = new CountDownLatch(1);
    var release = new CountDownLatch(1);
    var handoffStarted = new CountDownLatch(1);
    var executor = Executors.newFixedThreadPool(2);
    try {
      var cancelling =
          executor.submit(
              () ->
                  lease.intake.tx.executeWithoutResult(
                      status -> {
                        requests.cancel(
                            f.tenant(), cancellingActor, lease.request, claim.revision());
                        cancelled.countDown();
                        try {
                          if (!release.await(3, TimeUnit.SECONDS))
                            throw new AssertionError("CANCEL_RELEASE_TIMEOUT");
                        } catch (InterruptedException error) {
                          Thread.currentThread().interrupt();
                          throw new AssertionError(error);
                        }
                      }));
      assertThat(cancelled.await(3, TimeUnit.SECONDS)).isTrue();
      var handing =
          executor.submit(
              () -> {
                handoffStarted.countDown();
                return catchThrowable(this::complete);
              });
      assertThat(handoffStarted.await(3, TimeUnit.SECONDS)).isTrue();
      release.countDown();
      cancelling.get(4, TimeUnit.SECONDS);
      assertThat(handing.get(4, TimeUnit.SECONDS)).isInstanceOf(DomainException.class);
      assertThat(row().get("state")).isEqualTo("CANCELLED");
      assertThat(tasks()).isZero();
      verifyNoInteractions(compilers);
    } finally {
      release.countDown();
      executor.shutdownNow();
      assertThat(executor.awaitTermination(4, TimeUnit.SECONDS)).isTrue();
    }
  }

  private ManagedAndroidGateway.PolicyDocument document(
      String value, String hash, String agent, int api, String mode) {
    return new ManagedAndroidGateway.PolicyDocument(value, hash, agent, api, mode);
  }

  private ManagedPolicyPreparationService.Prepared result(String change) {
    var c = sql.context;
    var binding =
        change.equals("BINDING")
            ? new ManagedAgentBindingStore.VerifiedBindingContext(
                c.tenantId(),
                c.actorId(),
                c.authorityVersion(),
                c.subjectId(),
                c.deviceId(),
                c.registrationId(),
                c.keyThumbprint(),
                c.bindingId(),
                c.bindingVersion() + 1,
                c.enrollmentId(),
                c.enrollmentVersion(),
                c.provider(),
                c.enterpriseId(),
                c.enterpriseBindingVersion(),
                c.providerDeviceId(),
                c.managementMode(),
                c.bindingVerifiedAt(),
                c.agentPackageName(),
                c.agentTrustRevision(),
                c.platform(),
                c.registeredAt())
            : c;
    var source = desired.publication();
    var desiredResult =
        new ManagedDesiredPolicy(
            change.equals("VERSION")
                ? new ManagedExecutionPublicationAccess.Publication(
                    ManagedExecutionTestData.id(), source.previewHash(), source.createdAt())
                : source,
            change.equals("DEVICE") ? ManagedExecutionTestData.id() : desired.deviceId(),
            change.equals("REGISTRATION")
                ? ManagedExecutionTestData.id()
                : desired.registrationId(),
            desired.applications(),
            change.equals("DESIRED_CONTENT")
                ? List.of(
                    new ManagedDesiredPolicy.RuleReadiness(
                        ManagedExecutionTestData.id(), "BLOCKED", "UNSUPPORTED"))
                : desired.rules(),
            desired.protectedPackages());
    var profileResult =
        new ManagedDeviceExecutionVerifier.Verified(
            change.equals("PROFILE_DEVICE")
                ? "enterprises/other/devices/other"
                : profile.deviceName(),
            change.equals("PROFILE_MODE") ? "PROFILE_OWNER" : profile.managementMode(),
            change.equals("PROFILE_API") ? 29 : profile.apiLevel(),
            profile.reportedAt(),
            profile.retrievedAt(),
            change.equals("PROFILE_EXPIRED")
                ? Instant.ofEpochMilli(now.get() - 1)
                : profile.expiresAt());
    String body = change.equals("DOCUMENT") ? OTHER_DOCUMENT : DOCUMENT;
    var doc =
        document(
            body,
            change.equals("DIGEST") ? "f".repeat(64) : SecretMaterial.hash(body),
            change.equals("AGENT") ? "com.other.agent" : c.agentPackageName(),
            change.equals("API") ? 31 : 30,
            change.equals("MODE") ? "PROFILE_OWNER" : "DEVICE_OWNER");
    var controlResult =
        change.equals("CONTROL_EXPIRED")
            ? new ManagedPolicyControlAdmission.Checked(List.of(), List.of(), now.get() - 1)
            : checked;
    return new ManagedPolicyPreparationService.Prepared(
        change.equals("PUBLICATION") ? ManagedExecutionTestData.id() : f.publication(),
        binding,
        desiredResult,
        profileResult,
        doc,
        controlResult);
  }
}
