package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.shared.DomainException;
import java.lang.reflect.InvocationTargetException;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.http.HttpStatus;
import org.springframework.transaction.support.TransactionTemplate;

/** Real SQL and journal; lower binding authority is the existing explicit test fixture. */
class ManagedExecutionPreparationContextTest {
  ManagedPolicyExecutionJournalTest f;
  ManagedPolicyExecutionJournal.Claim claim;

  @BeforeEach
  void setup() {
    f = new ManagedPolicyExecutionJournalTest();
    f.setup();
    f.journal.enqueue(
        f.f.tenant(),
        f.f.actor(),
        f.f.publication(),
        f.f.binding(),
        2,
        ManagedPolicyExecutionJournalTest.DOCUMENT,
        f.deadline);
    claim = f.journal.claimDue("LOCAL_TEST", 1).get(0);
  }

  @AfterEach
  void close() {
    f.close();
  }

  @Test
  void targetComesFromCurrentStoredTaskWithoutChangingStateOrEvents() {
    var before = view();
    long events = events();
    var target = target(claim);
    assertThat(field(target, "claim")).isEqualTo(claim);
    assertThat(field(target, "binding")).isEqualTo(f.context);
    assertThat(field(target, "publicationId")).isEqualTo(f.f.publication());
    assertThat(field(target, "expiresAt")).isEqualTo(f.deadline);
    assertThat(field(target, "publication")).isEqualTo(publication());
    assertThat(view()).isEqualTo(before);
    assertThat(events()).isEqualTo(events);
    assertThat(target.toString())
        .doesNotContain(claim.token(), claim.documentJson(), claim.policyId());
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "TOKEN",
        "GENERATION",
        "LEASE",
        "ENTERPRISE",
        "DEVICE",
        "POLICY",
        "VERSION",
        "DOCUMENT",
        "DIGEST"
      })
  void rejectsSubstitutedClaimFields(String change) {
    var altered =
        new ManagedPolicyExecutionJournal.Claim(
            claim.tenantId(),
            claim.taskId(),
            change.equals("TOKEN") ? UUID.randomUUID().toString() : claim.token(),
            claim.generation() + (change.equals("GENERATION") ? 1 : 0),
            claim.action(),
            claim.leaseUntil() + (change.equals("LEASE") ? 1 : 0),
            change.equals("ENTERPRISE") ? "other-enterprise" : claim.enterpriseId(),
            change.equals("DEVICE") ? "other-device" : claim.deviceId(),
            change.equals("POLICY") ? "other-policy" : claim.policyId(),
            change.equals("VERSION") ? Long.valueOf(7) : claim.policyVersion(),
            change.equals("DOCUMENT") ? "{}" : claim.documentJson(),
            change.equals("DIGEST") ? "d".repeat(64) : claim.documentSha256());
    assertThatThrownBy(() -> target(altered))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_STALE");
  }

  @Test
  void foreignTenantCannotSelectTask() {
    var other = f.data.fixture();
    var altered =
        new ManagedPolicyExecutionJournal.Claim(
            other.tenant(),
            claim.taskId(),
            claim.token(),
            claim.generation(),
            claim.action(),
            claim.leaseUntil(),
            claim.enterpriseId(),
            claim.deviceId(),
            claim.policyId(),
            claim.policyVersion(),
            claim.documentJson(),
            claim.documentSha256());
    assertThatThrownBy(() -> target(altered)).isInstanceOf(DomainException.class);
  }

  @Test
  void changedLeaseDeadlineCannotPrepare() {
    f.db.update(
        "UPDATE managed_policy_execution_tasks SET lease_until=created_at-1 WHERE id=?",
        claim.taskId());
    assertThatThrownBy(() -> target(claim))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_STALE");
  }

  @Test
  void matchingExpiredLeaseCannotPrepare() {
    long expired =
        f.db.queryForObject(
            "SELECT created_at-1 FROM managed_policy_execution_tasks WHERE id=?",
            Long.class,
            claim.taskId());
    f.db.update(
        "UPDATE managed_policy_execution_tasks SET lease_until=? WHERE id=?",
        expired,
        claim.taskId());
    var matching =
        new ManagedPolicyExecutionJournal.Claim(
            claim.tenantId(),
            claim.taskId(),
            claim.token(),
            claim.generation(),
            claim.action(),
            expired,
            claim.enterpriseId(),
            claim.deviceId(),
            claim.policyId(),
            claim.policyVersion(),
            claim.documentJson(),
            claim.documentSha256());
    assertThatThrownBy(() -> target(matching))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_STALE");
  }

  @Test
  void expiredTaskCannotPrepareWithOtherwiseCurrentLease() {
    long created =
        f.db.queryForObject(
            "SELECT created_at FROM managed_policy_execution_tasks WHERE id=?",
            Long.class,
            claim.taskId());
    f.db.update(
        "UPDATE managed_policy_execution_tasks SET created_at=?, expires_at=? WHERE id=?",
        created - 2000,
        created - 1000,
        claim.taskId());
    assertThatThrownBy(() -> target(claim))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_STALE");
  }

  @Test
  void cancelledTaskCannotPrepare() {
    f.journal.cancel(f.f.tenant(), f.f.actor(), claim.taskId(), view().revision());
    assertThatThrownBy(() -> target(claim))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_STALE");
  }

  @Test
  void uncertainWriteCannotBePreparedAsNewWrite() {
    assertThat(f.journal.beforeWrite(f.journal.writePreparationTarget(claim), claim.leaseUntil()))
        .isTrue();
    assertThatThrownBy(() -> target(claim))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_STALE");
  }

  @Test
  void assignmentUsesSameDurableCandidateAndConfirmedVersion() {
    assertThat(f.journal.beforeWrite(f.journal.writePreparationTarget(claim), claim.leaseUntil()))
        .isTrue();
    f.journal.policyWritten(
        claim,
        new ManagedAndroidGateway.PolicyReceipt(
            "enterprises/" + claim.enterpriseId() + "/policies/" + claim.policyId(), 7L));
    var assignment = f.journal.claimDue("LOCAL_TEST", 1).get(0);
    assertThat(assignment.action()).isEqualTo(ManagedPolicyExecutionJournal.Action.ASSIGN_POLICY);
    assertThat(field(target(assignment), "claim")).isEqualTo(assignment);
  }

  @Test
  void currentAuthorityMustBeCheckedAgain() {
    when(f.bindings.requireVerifiedContext(anyString(), anyString(), anyString(), anyLong()))
        .thenThrow(new DomainException(HttpStatus.FORBIDDEN, "TEST_AUTHORITY_REVOKED"));
    assertThatThrownBy(() -> target(claim))
        .isInstanceOf(DomainException.class)
        .hasMessage("TEST_AUTHORITY_REVOKED");
  }

  @Test
  void changedPublishedVersionStopsPreparation() {
    when(f.publications.requireTarget(
            anyString(), anyString(), anyString(), anyString(), anyString()))
        .thenReturn(
            new ManagedExecutionPublicationAccess.Publication(
                UUID.randomUUID().toString(), "c".repeat(64), 1));
    assertThatThrownBy(() -> target(claim))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_CONTEXT_CHANGED");
  }

  @Test
  void rejectsOuterTransaction() {
    assertThatThrownBy(
            () -> new TransactionTemplate(f.data.transactions).execute(status -> target(claim)))
        .isInstanceOf(IllegalStateException.class);
  }

  Object target(ManagedPolicyExecutionJournal.Claim input) {
    try {
      var method =
          ManagedPolicyExecutionJournal.class.getDeclaredMethod(
              "writePreparationTarget", ManagedPolicyExecutionJournal.Claim.class);
      return method.invoke(f.journal, input);
    } catch (NoSuchMethodException missing) {
      throw new AssertionError(
          "execution journal must provide current durable preparation context", missing);
    } catch (InvocationTargetException failure) {
      if (failure.getCause() instanceof RuntimeException runtime) throw runtime;
      if (failure.getCause() instanceof Error error) throw error;
      throw new AssertionError(failure.getCause());
    } catch (ReflectiveOperationException failure) {
      throw new AssertionError(failure);
    }
  }

  static Object field(Object value, String name) {
    try {
      return value.getClass().getDeclaredMethod(name).invoke(value);
    } catch (ReflectiveOperationException failure) {
      throw new AssertionError(failure);
    }
  }

  ManagedExecutionPublicationAccess.Publication publication() {
    return f.publications.requireTarget(
        f.f.tenant(), f.f.actor(), f.f.publication(), f.f.device(), f.f.registration());
  }

  ManagedPolicyExecutionJournal.View view() {
    return f.journal.get(f.f.tenant(), f.f.actor(), claim.taskId());
  }

  long events() {
    return f.db.queryForObject("SELECT COUNT(*) FROM managed_policy_execution_events", Long.class);
  }
}
