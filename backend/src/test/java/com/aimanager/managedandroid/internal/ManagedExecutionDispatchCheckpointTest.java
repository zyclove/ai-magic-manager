package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedExecutionPublicationAccess.Publication;
import com.aimanager.shared.DomainException;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.transaction.support.TransactionTemplate;

/** Real SQL locks and database time; these checkpoints never invoke provider transport. */
class ManagedExecutionDispatchCheckpointTest {
  ManagedExecutionPreparationContextTest f;
  ManagedPolicyExecutionJournal journal;
  ManagedPolicyExecutionJournal.WritePreparationTarget target;

  @BeforeEach
  void setup() {
    f = new ManagedExecutionPreparationContextTest();
    f.setup();
    journal = f.f.journal;
    target = journal.writePreparationTarget(f.claim);
  }

  @AfterEach
  void close() {
    f.close();
  }

  @Test
  void commitsUnknownAndReturnsSameAuthoritativeTarget() {
    assertThat(checkpoint(target, f.claim.leaseUntil())).isTrue();
    assertThat(f.view().state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
    assertThat(assertDoesNotThrow(() -> journal.dispatchedTarget(f.claim))).isEqualTo(target);
    assertThat(checkpoint(target, f.claim.leaseUntil())).isFalse();
  }

  @ParameterizedTest
  @ValueSource(longs = {0, -1})
  void expiredEvidenceCannotCommit(long deadline) {
    assertThat(checkpoint(target, deadline)).isFalse();
    assertThat(f.view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
  }

  @ParameterizedTest
  @ValueSource(strings = {"PUBLICATION", "DEADLINE", "PREVIEW", "CREATED"})
  void refusesSubstitutedPreparationFacts(String change) {
    var p = target.publication();
    var changed =
        new ManagedPolicyExecutionJournal.WritePreparationTarget(
            target.claim(),
            change.equals("PUBLICATION") ? "other" : target.publicationId(),
            target.expiresAt() + (change.equals("DEADLINE") ? 1 : 0),
            target.binding(),
            new Publication(
                p.versionId(),
                change.equals("PREVIEW") ? "other" : p.previewHash(),
                p.createdAt() + (change.equals("CREATED") ? 1 : 0)));
    assertThat(checkpoint(changed, f.claim.leaseUntil())).isFalse();
    assertThat(f.view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
  }

  @Test
  void currentPublicationMetadataIsRecheckedUnderCheckpointLocks() {
    var p = target.publication();
    when(f.f.publications.requireTarget(
            anyString(), anyString(), anyString(), anyString(), anyString()))
        .thenReturn(new Publication(p.versionId(), "changed-preview", p.createdAt()));
    assertThat(checkpoint(target, f.claim.leaseUntil())).isFalse();
    assertThat(f.view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
  }

  @Test
  void cancelledTaskCannotCommitPreviousPreparation() {
    journal.cancel(f.f.f.tenant(), f.f.f.actor(), f.claim.taskId(), f.view().revision());
    assertThat(checkpoint(target, f.claim.leaseUntil())).isFalse();
  }

  @Test
  void reclaimedLeaseCannotCommitPreviousPreparation() {
    f.f.db.update(
        "UPDATE managed_policy_execution_tasks SET"
            + " lease_until=created_at-1,next_attempt_at=created_at WHERE id=?",
        f.claim.taskId());
    var fresh = journal.claimDue("LOCAL_TEST", 1).get(0);
    var before = f.view();
    assertThat(checkpoint(target, f.claim.leaseUntil())).isFalse();
    assertThat(f.view()).isEqualTo(before);
    assertThat(fresh.generation()).isGreaterThan(f.claim.generation());
  }

  @Test
  void dispatchedTargetDoesNotAcceptReadyState() {
    assertThatThrownBy(() -> journal.dispatchedTarget(f.claim)).isInstanceOf(DomainException.class);
  }

  @Test
  void dispatchedTargetDoesNotAcceptCancellation() {
    assertThat(checkpoint(target, f.claim.leaseUntil())).isTrue();
    journal.cancel(f.f.f.tenant(), f.f.f.actor(), f.claim.taskId(), f.view().revision());
    assertThatThrownBy(() -> journal.dispatchedTarget(f.claim)).isInstanceOf(DomainException.class);
  }

  @Test
  void strictCheckpointRejectsOuterTransaction() {
    assertThatThrownBy(
            () ->
                new TransactionTemplate(f.f.data.transactions)
                    .execute(status -> journal.beforeWrite(target, f.claim.leaseUntil())))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("transaction");
    assertThat(f.view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
  }

  private boolean checkpoint(
      ManagedPolicyExecutionJournal.WritePreparationTarget current, long deadline) {
    return assertDoesNotThrow(() -> journal.beforeWrite(current, deadline));
  }

  @Test
  void auditFailureRollsBackCheckpointAndEvent() {
    var before = f.view();
    long events = f.events();
    doThrow(new IllegalStateException("fixture checkpoint audit failed"))
        .when(f.f.audit)
        .record(anyString(), anyString(), eq("MANAGED_EXECUTION_WRITE_DISPATCHED"), anyString());
    assertThatThrownBy(() -> journal.beforeWrite(target, f.claim.leaseUntil()))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("fixture checkpoint audit failed");
    assertThat(f.view()).isEqualTo(before);
    assertThat(f.events()).isEqualTo(events);
  }
}
