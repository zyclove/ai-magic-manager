package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import java.util.List;
import java.util.Map;
import java.util.concurrent.*;
import java.util.function.Supplier;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Real SQL selection and terminal convergence; no provider I/O or manual resolution is simulated.
 */
class ManagedExecutionConsumerJournalTest {
  ManagedPolicyExecutionJournalTest f;
  ManagedPolicyExecutionJournal journal;
  ManagedPolicyExecutionJournal.View task;

  @BeforeEach
  void setup() {
    f = new ManagedPolicyExecutionJournalTest();
    f.setup();
    journal = f.journal;
    task =
        journal.enqueue(
            f.f.tenant(),
            f.f.actor(),
            f.f.publication(),
            f.f.binding(),
            2,
            ManagedPolicyExecutionJournalTest.DOCUMENT,
            f.deadline);
    clearInvocations(f.bindings, f.publications, f.audit);
  }

  @AfterEach
  void close() {
    f.close();
  }

  @ParameterizedTest
  @ValueSource(strings = {"READY_TO_WRITE", "READY_TO_ASSIGN"})
  void writeSelectionClaimsOnlyTheIntendedWriteAction(String state) {
    state(state);
    var claims = writes();
    assertThat(claims).hasSize(1);
    assertThat(claims.get(0).taskId()).isEqualTo(task.id());
    assertThat(claims.get(0).action().name())
        .isEqualTo(state.equals("READY_TO_WRITE") ? "WRITE_POLICY" : "ASSIGN_POLICY");
    assertThat(writes()).isEmpty();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "POLICY_WRITE_UNKNOWN",
        "ASSIGNMENT_UNKNOWN",
        "WAITING_DEVICE",
        "APPLIED",
        "NEEDS_REVIEW",
        "CANCELLED"
      })
  void writeSelectionDoesNotConsumeObservationOrTerminalAttempts(String state) {
    state(state);
    var before = row();
    assertThat(writes()).isEmpty();
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void writeSelectionHonorsFutureRetryAndProviderScope() {
    f.db.update(
        "UPDATE managed_policy_execution_tasks SET next_attempt_at=? WHERE id=?",
        f.deadline - 1,
        task.id());
    assertThat(writes()).isEmpty();
    assertThat(invoke(() -> journal.claimWriteActions("OTHER_PROVIDER", 1))).isEmpty();
    assertThat(row().get("attempts")).isEqualTo(0);
  }

  @Test
  void concurrentConsumersCannotClaimTheSameWriteTwice() throws Exception {
    var pool = Executors.newFixedThreadPool(2);
    var gate = new CountDownLatch(1);
    try {
      Callable<Integer> action =
          () -> {
            gate.await();
            return writes().size();
          };
      var first = pool.submit(action);
      var second = pool.submit(action);
      gate.countDown();
      assertThat(first.get(10, TimeUnit.SECONDS) + second.get(10, TimeUnit.SECONDS)).isEqualTo(1);
    } catch (ExecutionException failure) {
      if (failure.getCause() instanceof AssertionError assertion) throw assertion;
      throw failure;
    } finally {
      pool.shutdownNow();
      assertThat(pool.awaitTermination(5, TimeUnit.SECONDS)).isTrue();
    }
  }

  @ParameterizedTest
  @CsvSource({
    "READY_TO_WRITE,CANCELLED",
    "READY_TO_ASSIGN,CANCELLED",
    "POLICY_WRITE_UNKNOWN,NEEDS_REVIEW",
    "ASSIGNMENT_UNKNOWN,NEEDS_REVIEW",
    "WAITING_DEVICE,NEEDS_REVIEW"
  })
  void expiryConvergesWithoutAnOnlineProviderOrReadyRetry(String state, String expected) {
    state(state);
    f.db.update(
        "UPDATE managed_policy_execution_tasks SET"
            + " created_at=1,expires_at=2,next_attempt_at=?,updated_at=1 WHERE id=?",
        f.deadline,
        task.id());
    assertThat(settle(5)).isEqualTo(1);
    assertThat(view().state().name()).isEqualTo(expected);
    assertThat(view().reason()).isEqualTo(ManagedPolicyExecutionJournal.Reason.DEADLINE_EXCEEDED);
    assertThat(settle(5)).isZero();
    verifyNoInteractions(f.bindings, f.publications);
  }

  @Test
  void exhaustedReadyTaskCancelsButTheLastLiveLeaseIsNotRetired() {
    var claim = journal.claimDue("LOCAL_TEST", 1).get(0);
    f.db.update("UPDATE managed_policy_execution_tasks SET attempts=24 WHERE id=?", task.id());
    assertThat(settle(5)).isZero();
    assertThat(row().get("lease_token")).isEqualTo(claim.token());
    f.db.update("UPDATE managed_policy_execution_tasks SET lease_until=1 WHERE id=?", task.id());
    assertThat(settle(5)).isEqualTo(1);
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.CANCELLED);
    assertThat(view().reason()).isEqualTo(ManagedPolicyExecutionJournal.Reason.ATTEMPTS_EXHAUSTED);
  }

  @Test
  void unknownPolicyWithoutALiveLeaseRequiresReviewAndNeverInventsAReceipt() {
    state("POLICY_WRITE_UNKNOWN");
    f.db.update(
        "UPDATE managed_policy_execution_tasks SET next_attempt_at=? WHERE id=?",
        f.deadline - 1,
        task.id());
    var before = row();
    long events = events();
    assertThat(settle(5)).isEqualTo(1);
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
    assertThat(view().reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.WRITE_OUTCOME_UNKNOWN);
    assertThat(row().get("provider_version")).isNull();
    assertThat(row().get("document_json")).isEqualTo(before.get("document_json"));
    assertThat(row().get("provider_policy_id")).isEqualTo(before.get("provider_policy_id"));
    assertThat(row().get("active_device_id")).isEqualTo(f.f.device());
    assertThat(events()).isEqualTo(events + 1);
    assertThat(settle(5)).isZero();
    assertThat(events()).isEqualTo(events + 1);
    verify(f.audit)
        .record(
            f.f.tenant(),
            "system:managed-execution",
            "MANAGED_EXECUTION_WRITE_OUTCOME_UNKNOWN",
            task.id());
    verifyNoInteractions(f.bindings, f.publications);
  }

  @Test
  void liveUnknownWriteCannotBeMovedToReviewUntilItsLeaseEnds() {
    var claim = journal.claimDue("LOCAL_TEST", 1).get(0);
    assertThat(journal.beforeWrite(journal.writePreparationTarget(claim), claim.leaseUntil()))
        .isTrue();
    var before = row();
    assertThat(settle(5)).isZero();
    assertThat(row()).isEqualTo(before);
    f.db.update("UPDATE managed_policy_execution_tasks SET lease_until=1 WHERE id=?", task.id());
    assertThat(settle(5)).isEqualTo(1);
    assertThat(journal.failed(claim)).isFalse();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "READY_TO_WRITE",
        "READY_TO_ASSIGN",
        "ASSIGNMENT_UNKNOWN",
        "WAITING_DEVICE",
        "APPLIED",
        "NEEDS_REVIEW",
        "CANCELLED"
      })
  void unexpiredNonexhaustedTasksArePreserved(String state) {
    state(state);
    var before = row();
    assertThat(settle(5)).isZero();
    assertThat(row()).isEqualTo(before);
  }

  @Test
  void auditFailureRollsBackStateVersionAndEvent() {
    state("POLICY_WRITE_UNKNOWN");
    var before = row();
    long events = events();
    doThrow(new IllegalStateException("test audit unavailable"))
        .when(f.audit)
        .record(
            anyString(), anyString(), eq("MANAGED_EXECUTION_WRITE_OUTCOME_UNKNOWN"), anyString());
    assertThatThrownBy(() -> settle(5))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("test audit unavailable");
    assertThat(row()).isEqualTo(before);
    assertThat(events()).isEqualTo(events);
  }

  @Test
  void settlementIsBoundedAndCanRetireAnOldProvider() {
    state("POLICY_WRITE_UNKNOWN");
    f.db.update(
        "UPDATE managed_policy_execution_tasks SET provider='OLD_PROVIDER' WHERE id=?", task.id());
    var helper = new ManagedExecutionRecoveryJobTest();
    helper.data = f.data;
    for (int i = 0; i < 3; i++) {
      var other = f.data.fixture();
      var otherJournal = helper.journalFor(other);
      var task =
          otherJournal.enqueue(
              other.tenant(),
              other.actor(),
              other.publication(),
              other.binding(),
              2,
              ManagedPolicyExecutionJournalTest.DOCUMENT,
              f.deadline);
      f.db.update(
          "UPDATE managed_policy_execution_tasks SET state='POLICY_WRITE_UNKNOWN' WHERE id=?",
          task.id());
    }
    assertThat(settle(2)).isEqualTo(2);
    assertThat(settle(2)).isEqualTo(2);
    assertThat(settle(2)).isZero();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
  }

  @ParameterizedTest
  @ValueSource(ints = {0, -1, 26, 1000000})
  void bothSelectionsRejectInvalidBounds(int limit) {
    assertThatThrownBy(() -> invoke(() -> journal.claimWriteActions("LOCAL_TEST", limit)))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> settle(limit)).isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void outerTransactionsCannotContainConsumerCheckpoints() {
    var tx = new TransactionTemplate(f.data.transactions);
    assertThatThrownBy(() -> tx.execute(s -> writes()))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Execution worker checkpoints require separate short transactions");
    assertThatThrownBy(() -> tx.execute(s -> settle(1)))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Execution worker checkpoints require separate short transactions");
  }

  private <T> T invoke(Supplier<T> action) {
    try {
      return action.get();
    } catch (UnsupportedOperationException missing) {
      throw new AssertionError(missing.getMessage(), missing);
    }
  }

  private List<ManagedPolicyExecutionJournal.Claim> writes() {
    return invoke(() -> journal.claimWriteActions("LOCAL_TEST", 1));
  }

  private int settle(int limit) {
    return invoke(() -> journal.settleUnrunnableTasks(limit));
  }

  private ManagedPolicyExecutionJournal.View view() {
    return journal.get(f.f.tenant(), f.f.actor(), task.id());
  }

  private Map<String, Object> row() {
    return f.db.queryForMap(
        "SELECT * FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=?",
        f.f.tenant(),
        task.id());
  }

  private long events() {
    return f.db.queryForObject(
        "SELECT COUNT(*) FROM managed_policy_execution_events WHERE tenant_id=? AND task_id=?",
        Long.class,
        f.f.tenant(),
        task.id());
  }

  private void state(String state) {
    Long version =
        List.of("READY_TO_ASSIGN", "ASSIGNMENT_UNKNOWN", "WAITING_DEVICE", "APPLIED")
                .contains(state)
            ? 7L
            : null;
    f.db.update(
        "UPDATE managed_policy_execution_tasks SET state=?,active_device_id=?,provider_version=?"
            + " WHERE id=?",
        state,
        state.equals("APPLIED") || state.equals("CANCELLED") ? null : f.f.device(),
        version,
        task.id());
  }
}
