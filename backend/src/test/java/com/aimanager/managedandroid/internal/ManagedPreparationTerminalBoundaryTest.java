package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.aimanager.shared.DomainException;
import com.aimanager.shared.ResourceVersions;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

/** Actual request journal; reproduce the lower binding service's real stale-version error. */
class ManagedPreparationTerminalBoundaryTest {
  ManagedPreparationRequestJournalTest f;

  @BeforeEach
  void setup() {
    f = new ManagedPreparationRequestJournalTest();
    f.setup();
  }

  @AfterEach
  void close() {
    f.close();
  }

  private void staleBindingVersion() {
    doAnswer(
            call -> {
              ResourceVersions.check(2, 3);
              throw new AssertionError("Stale version must fail");
            })
        .when(f.intake.f.bindings)
        .requireVerifiedContext(f.f.tenant(), f.f.actor(), f.f.binding(), 2);
  }

  private void unavailableBindingService() {
    doThrow(new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "EMM_UNAVAILABLE"))
        .when(f.intake.f.bindings)
        .requireVerifiedContext(f.f.tenant(), f.f.actor(), f.f.binding(), 2);
    clearInvocations(f.intake.f.bindings);
  }

  @Test
  void staleBindingVersionIsAContextRejectionAtClaim() {
    staleBindingVersion();
    assertThatCode(() -> assertThat(f.journal.claim(f.f.tenant(), f.request)).isNull())
        .doesNotThrowAnyException();
    assertThat(f.row().get("state")).isEqualTo("REJECTED");
    assertThat(f.row().get("reason_code")).isEqualTo("CONTEXT_CHANGED");
    assertThat(f.row().get("active_device_id")).isNull();
  }

  @Test
  void staleBindingVersionMakesAnExistingLeaseNoncurrent() {
    var claim = f.journal.claim(f.f.tenant(), f.request);
    staleBindingVersion();
    assertThatCode(() -> assertThat(f.journal.current(claim)).isFalse()).doesNotThrowAnyException();
  }

  @Test
  void staleBindingVersionTerminatesTheOwnedFailureCheckpoint() {
    var claim = f.journal.claim(f.f.tenant(), f.request);
    staleBindingVersion();
    assertThatCode(() -> assertThat(f.journal.failed(claim, true)).isTrue())
        .doesNotThrowAnyException();
    assertThat(f.row().get("state")).isEqualTo("REJECTED");
    assertThat(f.row().get("reason_code")).isEqualTo("CONTEXT_CHANGED");
    assertThat(f.row().get("active_device_id")).isNull();
  }

  @Test
  void expiredRequestCanRetireWhileTheConnectorIsUnavailable() {
    f.db.update(
        "UPDATE managed_policy_preparation_requests SET created_at=1,next_attempt_at=1,expires_at=2"
            + " WHERE tenant_id=? AND id=?",
        f.f.tenant(),
        f.request);
    unavailableBindingService();
    assertThatCode(() -> assertThat(f.journal.claim(f.f.tenant(), f.request)).isNull())
        .doesNotThrowAnyException();
    assertThat(f.row().get("state")).isEqualTo("REJECTED");
    assertThat(f.row().get("reason_code")).isEqualTo("DEADLINE_EXCEEDED");
    assertThat(f.row().get("active_device_id")).isNull();
    verifyNoInteractions(f.intake.f.bindings);
  }

  @Test
  void exhaustedUnleasedRequestCanRetireWhileTheConnectorIsUnavailable() {
    f.db.update(
        "UPDATE managed_policy_preparation_requests SET attempts=3 WHERE tenant_id=? AND id=?",
        f.f.tenant(),
        f.request);
    unavailableBindingService();
    assertThatCode(() -> assertThat(f.journal.claim(f.f.tenant(), f.request)).isNull())
        .doesNotThrowAnyException();
    assertThat(f.row().get("state")).isEqualTo("REJECTED");
    assertThat(f.row().get("reason_code")).isEqualTo("ATTEMPTS_EXHAUSTED");
    assertThat(f.row().get("active_device_id")).isNull();
    verifyNoInteractions(f.intake.f.bindings);
  }

  @Test
  void finalAllowedActiveLeaseIsNotRetiredByAnotherWakeup() {
    f.db.update(
        "UPDATE managed_policy_preparation_requests SET attempts=2 WHERE tenant_id=? AND id=?",
        f.f.tenant(),
        f.request);
    var claim = f.journal.claim(f.f.tenant(), f.request);
    var before = f.row();
    assertThat(f.journal.claim(f.f.tenant(), f.request)).isNull();
    assertThat(f.row()).isEqualTo(before);
    assertThat(f.journal.current(claim)).isTrue();
  }

  @Test
  void expiryAndAuditFailureRollBackTogetherWithoutReadingTheConnector() {
    f.db.update(
        "UPDATE managed_policy_preparation_requests SET created_at=1,next_attempt_at=1,expires_at=2"
            + " WHERE tenant_id=? AND id=?",
        f.f.tenant(),
        f.request);
    unavailableBindingService();
    var before = f.row();
    doThrow(new IllegalStateException("TEST_RETIREMENT_AUDIT_FAILURE"))
        .when(f.intake.f.audit)
        .record(f.f.tenant(), f.f.actor(), "PREPARATION_REJECTED", f.request);
    assertThatThrownBy(() -> f.journal.claim(f.f.tenant(), f.request))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("TEST_RETIREMENT_AUDIT_FAILURE");
    assertThat(f.row()).isEqualTo(before);
    verifyNoInteractions(f.intake.f.bindings);
  }
}
