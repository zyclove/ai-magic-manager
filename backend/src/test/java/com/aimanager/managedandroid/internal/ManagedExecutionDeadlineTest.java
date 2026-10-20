package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedDeviceExecutionVerifier;
import com.aimanager.shared.DomainException;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * Real admission/handoff/execution SQL; provider reads and the test clock are explicit fixtures.
 */
class ManagedExecutionDeadlineTest {
  final ManagedProviderCalls calls =
      new ManagedProviderCalls(1, java.time.Duration.ofSeconds(20), System::nanoTime);

  @org.junit.jupiter.api.AfterEach
  void closeProviderCalls() {
    calls.close();
  }

  ManagedPreparationHandoffTest f;

  @BeforeEach
  void setup() {
    f = new ManagedPreparationHandoffTest();
    f.setup();
  }

  @AfterEach
  void close() {
    f.close();
  }

  @ParameterizedTest
  @CsvSource({"30000,60000", "120000,45000", "60000,60000"})
  void taskInheritsOriginalRequestDeadlineWithoutRenewingAuthorization(
      long profileMs, long controlMs) {
    long originalDeadline = requestDeadline();
    f.now.addAndGet(1000);
    proof(f.now.get() + profileMs, f.now.get() + controlMs);
    var task = complete();
    assertThat(taskDeadline(task.id())).isEqualTo(originalDeadline);
    assertThat(requestDeadline()).isEqualTo(originalDeadline);
  }

  @Test
  void freshPreparationReplacesAdmissionProofAfterItsReuseDeadline() {
    long oldEvidenceDeadline = f.now.get() + 30000;
    proof(oldEvidenceDeadline, oldEvidenceDeadline);
    var task = complete();
    var claim = f.executions.claimWriteActions("LOCAL_TEST", 1).get(0);
    f.now.set(oldEvidenceDeadline);
    proof(f.now.get() + 30000, f.now.get() + 30000);
    var preparer = mock(ManagedPolicyPreparationService.class);
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenReturn(f.prepared);
    ManagedExecutionPreparationService.PreparedExecution result;
    try {
      result =
          new ManagedExecutionPreparationService(f.executions, preparer, f.clock, calls)
              .prepare(claim);
    } catch (DomainException failure) {
      throw new AssertionError(
          "Fresh dispatch evidence must remain usable within the original authorization deadline",
          failure);
    }
    assertThat(result.expiresAt()).isGreaterThan(oldEvidenceDeadline);
    assertThat(result.expiresAt()).isLessThanOrEqualTo(claim.leaseUntil());
    assertThat(result.expiresAt()).isLessThanOrEqualTo(requestDeadline());
    assertThat(result.target().claim().taskId()).isEqualTo(task.id());
    verify(preparer)
        .prepare(
            eq(f.f.tenant()),
            eq(f.f.actor()),
            eq(f.f.publication()),
            eq(f.f.binding()),
            eq(f.sql.context.bindingVersion()),
            any(ManagedProviderCalls.Budget.class));
  }

  @ParameterizedTest
  @ValueSource(strings = {"PROFILE", "CONTROL"})
  void expiredEvidenceStillCannotEnterHandoff(String kind) {
    proof(
        f.now.get() + (kind.equals("PROFILE") ? 0 : 30000),
        f.now.get() + (kind.equals("CONTROL") ? 0 : 30000));
    assertThatThrownBy(this::complete).isInstanceOf(DomainException.class);
    assertNoTask();
  }

  @ParameterizedTest
  @ValueSource(strings = {"PROFILE", "CONTROL"})
  void longerTaskDeadlineNeverAllowsExpiredEvidenceAtDispatch(String kind) {
    long expiry = f.now.get() + 30000;
    proof(expiry, expiry);
    complete();
    var claim = f.executions.claimWriteActions("LOCAL_TEST", 1).get(0);
    f.now.set(expiry);
    proof(
        expiry + (kind.equals("PROFILE") ? 0 : 30000),
        expiry + (kind.equals("CONTROL") ? 0 : 30000));
    var preparer = mock(ManagedPolicyPreparationService.class);
    when(preparer.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenReturn(f.prepared);
    var service = new ManagedExecutionPreparationService(f.executions, preparer, f.clock, calls);
    assertThatThrownBy(() -> service.prepare(claim))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_EXPIRED");
  }

  @Test
  void evidenceExpiringDuringCompilationStillRollsBackHandoff() {
    long expiry = f.now.get() + 30000;
    proof(expiry, expiry);
    when(f.compilers.compile(anyString(), anyString(), any(), any(), anySet()))
        .thenAnswer(
            call -> {
              f.now.set(expiry);
              return f.document;
            });
    assertThatThrownBy(this::complete)
        .isInstanceOf(DomainException.class)
        .hasMessage("PREPARATION_HANDOFF_EXPIRED");
    assertNoTask();
  }

  @Test
  void requestDeadlineRemainsAbsoluteWhenEvidenceIsLongerLived() {
    long originalDeadline = requestDeadline();
    proof(originalDeadline + 10000, originalDeadline + 10000);
    assertThat(taskDeadline(complete().id())).isEqualTo(originalDeadline);
    assertThat(requestDeadline()).isEqualTo(originalDeadline);
  }

  private long requestDeadline() {
    return f.sql.db.queryForObject(
        "SELECT expires_at FROM managed_policy_preparation_requests WHERE tenant_id=? AND id=?",
        Long.class,
        f.f.tenant(),
        f.lease.request);
  }

  private long taskDeadline(String taskId) {
    return f.sql.db.queryForObject(
        "SELECT expires_at FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=?",
        Long.class,
        f.f.tenant(),
        taskId);
  }

  private void proof(long profileDeadline, long controlDeadline) {
    var p = f.profile;
    f.profile =
        new ManagedDeviceExecutionVerifier.Verified(
            p.deviceName(),
            p.managementMode(),
            p.apiLevel(),
            Instant.ofEpochMilli(f.now.get() - 1000),
            Instant.ofEpochMilli(f.now.get() - 1),
            Instant.ofEpochMilli(profileDeadline));
    f.checked = new ManagedPolicyControlAdmission.Checked(List.of(), List.of(), controlDeadline);
    f.prepared =
        new ManagedPolicyPreparationService.Prepared(
            f.prepared.publicationId(),
            f.prepared.binding(),
            f.prepared.desired(),
            f.profile,
            f.document,
            f.checked);
  }

  private ManagedPolicyExecutionJournal.View complete() {
    return f.service.complete(f.claim, f.prepared);
  }

  private void assertNoTask() {
    assertThat(
            f.sql.db.queryForObject(
                "SELECT COUNT(*) FROM managed_policy_execution_tasks WHERE tenant_id=?",
                Long.class,
                f.f.tenant()))
        .isZero();
  }
}
