package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.Timestamp;
import java.util.List;
import java.util.Map;
import java.util.concurrent.*;
import java.util.function.Supplier;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;

/** Proposed real request SQL/lease/cancellation checks; not compiled or executed yet. */
class ManagedPreparationRequestJournalTest {
  ManagedPreparationAdmissionTest intake;
  ManagedPreparationRequestJournal journal;
  ManagedExecutionTestData.Fixture f;
  JdbcTemplate db;
  String request;

  @BeforeEach
  void setup() {
    intake = new ManagedPreparationAdmissionTest();
    intake.setup();
    intake.accept();
    f = intake.f.f;
    db = intake.f.db;
    request =
        db.queryForObject(
            "SELECT id FROM managed_policy_preparation_requests WHERE tenant_id=?",
            String.class,
            f.tenant());
    journal =
        new ManagedPreparationRequestJournal(
            db,
            intake.f.bindings,
            intake.f.publications,
            new TenantAccess(db),
            intake.f.audit,
            intake.f.data.transactions,
            new ObjectMapper(),
            30,
            3,
            5);
  }

  @AfterEach
  void close() {
    intake.close();
  }

  <T> T invoke(Supplier<T> work) {
    try {
      return work.get();
    } catch (UnsupportedOperationException missing) {
      if ("MANAGED_PREPARATION_REQUEST_JOURNAL_NOT_IMPLEMENTED".equals(missing.getMessage()))
        throw new AssertionError(missing.getMessage(), missing);
      throw missing;
    }
  }

  ManagedPreparationRequestJournal.Claim claim() {
    return invoke(() -> journal.claim(f.tenant(), request));
  }

  Map<String, Object> row() {
    return db.queryForMap(
        "SELECT * FROM managed_policy_preparation_requests WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
  }

  long now() {
    return db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
  }

  @Test
  void claimUsesFrozenAuthorityAndDatabaseTimeWithoutExtendingTheDeadline() {
    long before = now(), deadline = ((Number) row().get("expires_at")).longValue();
    var claim = claim();
    assertThat(claim.requestId()).isEqualTo(request);
    assertThat(claim.binding()).isEqualTo(intake.f.context);
    assertThat(claim.generation()).isEqualTo(1);
    assertThat(claim.revision()).isEqualTo(2);
    assertThat(claim.leaseUntil()).isBetween(before + 30000, now() + 30000);
    assertThat(row().get("expires_at")).isEqualTo(deadline);
    assertThat(((Number) row().get("attempts")).intValue()).isEqualTo(1);
    assertThat(row().get("lease_token")).isEqualTo(claim.token());
    assertThat(invoke(() -> journal.current(claim))).isTrue();
  }

  @Test
  void activeLeaseCannotBeClaimedTwice() {
    claim();
    var before = row();
    assertThat(claim()).isNull();
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void expiredLeaseAdvancesGenerationAndRejectsTheOldResult() {
    var first = claim();
    db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " created_at=1,next_attempt_at=1,lease_until=2 WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
    var second = claim();
    assertThat(second.generation()).isEqualTo(first.generation() + 1);
    assertThat(second.token()).isNotEqualTo(first.token());
    assertThat(invoke(() -> journal.current(first))).isFalse();
    assertThat(invoke(() -> journal.failed(first, true))).isFalse();
    assertThat(row().get("lease_token")).isEqualTo(second.token());
  }

  @Test
  void deadlineExhaustionRejectsAndReleasesTheDeviceSlot() {
    db.update(
        "UPDATE managed_policy_preparation_requests SET created_at=1,next_attempt_at=1,expires_at=2"
            + " WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
    assertThat(claim()).isNull();
    assertThat(row().get("state")).isEqualTo("REJECTED");
    assertThat(row().get("reason_code")).isEqualTo("DEADLINE_EXCEEDED");
    assertThat(row().get("active_device_id")).isNull();
  }

  @Test
  void attemptExhaustionDoesNotStartAnotherRead() {
    db.update(
        "UPDATE managed_policy_preparation_requests SET attempts=3 WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
    assertThat(claim()).isNull();
    assertThat(row().get("state")).isEqualTo("REJECTED");
    assertThat(row().get("reason_code")).isEqualTo("ATTEMPTS_EXHAUSTED");
  }

  @Test
  void temporaryReadFailureReleasesLeaseAndDelaysWithinOriginalDeadline() {
    var claim = claim();
    long before = now();
    assertThat(invoke(() -> journal.failed(claim, true))).isTrue();
    assertThat(row().get("state")).isEqualTo("PENDING");
    assertThat(row().get("lease_token")).isNull();
    assertThat(row().get("active_device_id")).isEqualTo(f.device());
    assertThat(((Number) row().get("next_attempt_at")).longValue())
        .isBetween(before + 5000, now() + 5000);
    assertThat(claim()).isNull();
  }

  @Test
  void permanentReadFailureNeverRequeues() {
    var claim = claim();
    assertThat(invoke(() -> journal.failed(claim, false))).isTrue();
    assertThat(row().get("state")).isEqualTo("REJECTED");
    assertThat(row().get("active_device_id")).isNull();
    assertThat(claim()).isNull();
  }

  @Test
  void cancellationInvalidatesAnInFlightReadAndReleasesItsSlot() {
    var claim = claim();
    var cancelled = invoke(() -> journal.cancel(f.tenant(), f.actor(), request, claim.revision()));
    assertThat(cancelled.state()).isEqualTo(ManagedPreparationRequestJournal.State.CANCELLED);
    assertThat(row().get("lease_token")).isNull();
    assertThat(row().get("active_device_id")).isNull();
    assertThat(invoke(() -> journal.current(claim))).isFalse();
    assertThat(invoke(() -> journal.failed(claim, true))).isFalse();
  }

  @Test
  void cancelledRequestCannotBeClaimedAgain() {
    invoke(() -> journal.cancel(f.tenant(), f.actor(), request, 1));
    assertThat(claim()).isNull();
  }

  @Test
  void staleCancellationIsNotNewConsent() {
    var claim = claim();
    assertThatThrownBy(() -> invoke(() -> journal.cancel(f.tenant(), f.actor(), request, 1)))
        .isInstanceOf(DomainException.class);
    assertThat(row().get("lease_token")).isEqualTo(claim.token());
  }

  @ParameterizedTest
  @ValueSource(strings = {"CHILD", "GUARDIAN", "AUDITOR", "TEACHER"})
  void onlyCurrentManagedAdministratorsMayCancel(String role) {
    db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
    assertThatThrownBy(() -> invoke(() -> journal.cancel(f.tenant(), f.actor(), request, 1)))
        .isInstanceOf(DomainException.class);
    assertThat(row().get("state")).isEqualTo("PENDING");
  }

  @Test
  void childCannotInspectInternalPreparationProgress() {
    db.update("UPDATE tenant_members SET role='CHILD' WHERE tenant_id=?", f.tenant());
    assertThatThrownBy(() -> invoke(() -> journal.get(f.tenant(), f.actor(), request)))
        .isInstanceOf(DomainException.class);
  }

  @Test
  void anotherTenantCannotClaimARequestByKnowingItsId() {
    assertThat(invoke(() -> journal.claim(ManagedExecutionTestData.id(), request))).isNull();
    assertThat(row().get("lease_token")).isNull();
  }

  @Test
  void claimCannotJoinAnOuterTransactionAcrossProviderReads() {
    assertThatThrownBy(() -> intake.tx.executeWithoutResult(s -> claim()))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Preparation claim requires a separate transaction");
  }

  @Test
  void revokedOriginalAuthorizerCannotLeaseAnotherRead() {
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    assertThat(claim()).isNull();
    assertThat(row().get("state")).isEqualTo("REJECTED");
    assertThat(row().get("active_device_id")).isNull();
  }

  @Test
  void currentLeaseDoesNotPreserveAnOldAuthorityVersion() {
    var claim = claim();
    db.update("UPDATE tenant_members SET version=version+1 WHERE tenant_id=?", f.tenant());
    assertThat(invoke(() -> journal.current(claim))).isFalse();
  }

  @Test
  void anotherCurrentAdministratorCanCancelAfterOriginalAuthorizerRevocation() {
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    String replacement = "replacement-" + ManagedExecutionTestData.id();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'ORG_ADMIN')",
        f.tenant(),
        replacement,
        ActorKeys.key(replacement));
    var result = invoke(() -> journal.cancel(f.tenant(), replacement, request, 1));
    assertThat(result.state()).isEqualTo(ManagedPreparationRequestJournal.State.CANCELLED);
    assertThat(row().get("active_device_id")).isNull();
  }

  @Test
  void replayingCancellationWithItsCurrentRevisionIsANoOp() {
    var first = invoke(() -> journal.cancel(f.tenant(), f.actor(), request, 1));
    var before = row();
    var replay = invoke(() -> journal.cancel(f.tenant(), f.actor(), request, first.revision()));
    assertThat(replay).isEqualTo(first);
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void frozenContextHashMismatchRejectsBeforeProviderPreparation() {
    db.update(
        "UPDATE managed_policy_preparation_requests SET context_sha256=? WHERE tenant_id=? AND"
            + " id=?",
        "f".repeat(64),
        f.tenant(),
        request);
    assertThat(claim()).isNull();
    assertThat(row().get("state")).isEqualTo("REJECTED");
    assertThat(row().get("reason_code")).isEqualTo("CONTEXT_CHANGED");
    assertThat(row().get("lease_token")).isNull();
  }

  @Test
  void publicationTargetMustStillBelongToTheFrozenSelection() {
    doThrow(DomainException.denied())
        .when(intake.f.publications)
        .requireTarget(f.tenant(), f.actor(), f.publication(), f.device(), f.registration());
    assertThat(claim()).isNull();
    assertThat(row().get("state")).isEqualTo("REJECTED");
  }

  @Test
  void transientStorageFailureDoesNotMasqueradeAsAnAuthorityRejection() {
    doThrow(
            new org.springframework.dao.DataAccessResourceFailureException(
                "TEST_STORAGE_UNAVAILABLE"))
        .when(intake.f.bindings)
        .requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2);
    var before = row();
    assertThatThrownBy(this::claim)
        .isInstanceOf(org.springframework.dao.DataAccessResourceFailureException.class);
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void cancellationAndItsAuditRecordAreAtomic() {
    var before = row();
    doThrow(new IllegalStateException("TEST_AUDIT_UNAVAILABLE"))
        .when(intake.f.audit)
        .record(f.tenant(), f.actor(), "PREPARATION_CANCELLED", request);
    assertThatThrownBy(() -> invoke(() -> journal.cancel(f.tenant(), f.actor(), request, 1)))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("TEST_AUDIT_UNAVAILABLE");
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void aClaimWithAnotherTokenCannotChangeTheRequest() {
    var first = claim();
    var forged =
        new ManagedPreparationRequestJournal.Claim(
            first.tenantId(),
            first.requestId(),
            ManagedExecutionTestData.id(),
            first.generation(),
            first.leaseUntil(),
            first.revision(),
            first.publicationId(),
            first.binding());
    var before = row();
    assertThat(invoke(() -> journal.current(forged))).isFalse();
    assertThat(invoke(() -> journal.failed(forged, true))).isFalse();
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void expiredLeaseCannotRecordEvenATransientFailure() {
    var first = claim();
    db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " created_at=1,next_attempt_at=1,lease_until=2 WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
    var before = row();
    assertThat(invoke(() -> journal.current(first))).isFalse();
    assertThat(invoke(() -> journal.failed(first, true))).isFalse();
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void retryCannotExtendTheOriginalRequestDeadline() {
    var first = claim();
    long deadline = now() + 2000;
    db.update(
        "UPDATE managed_policy_preparation_requests SET expires_at=?,lease_until=? WHERE"
            + " tenant_id=? AND id=?",
        deadline,
        deadline,
        f.tenant(),
        request);
    var bounded =
        new ManagedPreparationRequestJournal.Claim(
            first.tenantId(),
            first.requestId(),
            first.token(),
            first.generation(),
            deadline,
            first.revision(),
            first.publicationId(),
            first.binding());
    assertThat(invoke(() -> journal.failed(bounded, true))).isTrue();
    assertThat(row().get("expires_at")).isEqualTo(deadline);
    assertThat(row().get("state")).isEqualTo("REJECTED");
    assertThat(row().get("reason_code")).isEqualTo("DEADLINE_EXCEEDED");
    assertThat(row().get("active_device_id")).isNull();
  }

  @Test
  void lastAllowedReadFailureIsTerminalImmediately() {
    db.update(
        "UPDATE managed_policy_preparation_requests SET attempts=2 WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
    var first = claim();
    assertThat(invoke(() -> journal.failed(first, true))).isTrue();
    assertThat(row().get("state")).isEqualTo("REJECTED");
    assertThat(row().get("reason_code")).isEqualTo("ATTEMPTS_EXHAUSTED");
    assertThat(row().get("lease_token")).isNull();
  }

  @Test
  void simultaneousClaimsProduceExactlyOneLease() throws Exception {
    var ready = new CountDownLatch(2);
    var start = new CountDownLatch(1);
    var executor = Executors.newFixedThreadPool(2);
    try {
      Callable<ManagedPreparationRequestJournal.Claim> attempt =
          () -> {
            ready.countDown();
            if (!start.await(3, TimeUnit.SECONDS)) throw new AssertionError("START_TIMEOUT");
            return claim();
          };
      var a = executor.submit(attempt);
      var b = executor.submit(attempt);
      assertThat(ready.await(3, TimeUnit.SECONDS)).isTrue();
      start.countDown();
      // Keep placeholder RED visible as an assertion rather than an unrelated Future error.
      var results = new java.util.ArrayList<ManagedPreparationRequestJournal.Claim>();
      for (var future : List.of(a, b)) {
        try {
          results.add(future.get(4, TimeUnit.SECONDS));
        } catch (ExecutionException failure) {
          if (failure.getCause() instanceof AssertionError assertion) throw assertion;
          throw failure;
        }
      }
      assertThat(results.stream().filter(java.util.Objects::nonNull).count()).isEqualTo(1);
      assertThat(((Number) row().get("attempts")).intValue()).isEqualTo(1);
      assertThat(((Number) row().get("generation")).intValue()).isEqualTo(1);
    } finally {
      start.countDown();
      executor.shutdownNow();
      assertThat(executor.awaitTermination(4, TimeUnit.SECONDS)).isTrue();
    }
  }

  @Test
  void requestViewContainsOnlyAdministratorProgressFields() {
    var view = invoke(() -> journal.get(f.tenant(), f.actor(), request));
    assertThat(view.id()).isEqualTo(request);
    assertThat(view.versionId()).isEqualTo(f.version());
    assertThat(view.state()).isEqualTo(ManagedPreparationRequestJournal.State.PENDING);
    assertThat(view.executionTaskId()).isNull();
    assertThat(view.expiresAt()).isGreaterThan(view.createdAt());
    assertThat(view.updatedAt()).isGreaterThanOrEqualTo(view.createdAt());
    assertThat(view.toString())
        .doesNotContain(f.actor(), f.providerDevice(), f.enterprise(), "context_sha256");
  }

  @Test
  void cancellationDoesNotAlterAnAlreadyRejectedRequest() {
    var first = claim();
    invoke(() -> journal.failed(first, false));
    var before = row();
    long revision = ((Number) before.get("revision")).longValue();
    assertThatThrownBy(() -> invoke(() -> journal.cancel(f.tenant(), f.actor(), request, revision)))
        .isInstanceOf(DomainException.class);
    assertThat(row()).isEqualTo(before);
  }

  @ParameterizedTest
  @ValueSource(strings = {"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "not-a-tenant"})
  void noncanonicalTenantCannotReachTheRequestStateMachine(String tenant) {
    var before = row();
    assertThatThrownBy(() -> invoke(() -> journal.claim(tenant, request)))
        .isInstanceOf(DomainException.class);
    assertThat(row()).isEqualTo(before);
  }

  @ParameterizedTest
  @ValueSource(strings = {"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "not-a-request"})
  void noncanonicalRequestCannotReachTheRequestStateMachine(String id) {
    var before = row();
    assertThatThrownBy(() -> invoke(() -> journal.claim(f.tenant(), id)))
        .isInstanceOf(DomainException.class);
    assertThat(row()).isEqualTo(before);
  }
}
