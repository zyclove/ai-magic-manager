package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

import java.util.List;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Real due-request selection SQL. Selection is not a lease or current authorization. */
class ManagedPreparationDueRequestsTest {
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

  List<ManagedPreparationRequestJournal.Reference> due(int limit) {
    try {
      return f.journal.dueRequests(limit);
    } catch (UnsupportedOperationException missing) {
      if ("MANAGED_PREPARATION_SCAN_NOT_IMPLEMENTED".equals(missing.getMessage()))
        throw new AssertionError(missing.getMessage(), missing);
      throw missing;
    }
  }

  ManagedPreparationRequestJournal.Reference reference() {
    return new ManagedPreparationRequestJournal.Reference(f.f.tenant(), f.request);
  }

  ManagedPreparationRequestJournal.Reference add(long next, long expires) {
    var other = f.intake.f.data.fixture();
    String id = ManagedExecutionTestData.id();
    f.db.update(
        "INSERT INTO"
            + " managed_policy_preparation_requests(tenant_id,id,publication_id,policy_version_id,"
            + "subject_id,device_id,registration_id,binding_id,binding_version,actor_id,authority_version,context_sha256,"
            + "state,reason_code,active_device_id,next_attempt_at,expires_at,created_at,updated_at)"
            + " VALUES(?,?,?,?,?,?,?,?,2,?,0,?,'PENDING','QUEUED',?,?,?,1,1)",
        other.tenant(),
        id,
        other.publication(),
        other.version(),
        other.subject(),
        other.device(),
        other.registration(),
        other.binding(),
        other.actor(),
        "a".repeat(64),
        other.device(),
        next,
        expires);
    return new ManagedPreparationRequestJournal.Reference(other.tenant(), id);
  }

  @Test
  void selectionOnlyReturnsMinimalReferencesWithoutChangingRequests() {
    var before = f.row();
    clearInvocations(f.intake.f.bindings);
    assertThat(due(5)).containsExactly(reference());
    assertThat(f.row()).isEqualTo(before);
    verifyNoInteractions(f.intake.f.bindings);
    assertThat(ManagedPreparationRequestJournal.Reference.class.getRecordComponents()).hasSize(2);
  }

  @Test
  void liveLeaseIsExcluded() {
    f.claim();
    assertThat(due(5)).isEmpty();
  }

  @Test
  void expiredLeaseCanBeSelectedForRecovery() {
    f.claim();
    f.db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " created_at=1,next_attempt_at=1,lease_until=2 WHERE tenant_id=?",
        f.f.tenant());
    assertThat(due(5)).containsExactly(reference());
  }

  @Test
  void futureRetryIsExcluded() {
    f.db.update(
        "UPDATE managed_policy_preparation_requests SET next_attempt_at=? WHERE tenant_id=?",
        f.now() + 60000,
        f.f.tenant());
    assertThat(due(5)).isEmpty();
  }

  @Test
  void expiryRetirementPrecedesOrdinaryDueRequestsEvenWithFutureRetry() {
    var expired = add(f.now() + 60000, 2);
    assertThat(due(1)).containsExactly(expired);
  }

  @Test
  void expiredRequestIsSelectedRegardlessOfConnectorAvailability() {
    f.db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " created_at=1,next_attempt_at=9999999999999,expires_at=2 WHERE tenant_id=?",
        f.f.tenant());
    clearInvocations(f.intake.gateway);
    assertThat(due(5)).containsExactly(reference());
    verifyNoInteractions(f.intake.gateway);
  }

  @Test
  void terminalRequestsAreExcluded() {
    f.journal.cancel(f.f.tenant(), f.f.actor(), f.request, 1);
    assertThat(due(5)).isEmpty();
  }

  @Test
  void scanHasABoundedDeterministicBatchAcrossTenants() {
    for (int i = 0; i < 28; i++) add(1, f.now() + 60000);
    var first = due(25);
    assertThat(first).hasSize(25).doesNotHaveDuplicates();
    assertThat(due(25)).containsExactlyElementsOf(first);
    assertThat(due(1)).containsExactly(first.get(0));
  }

  @ParameterizedTest
  @ValueSource(ints = {0, -1, 26, 1000000})
  void invalidScanLimitsAreRejected(int limit) {
    assertThatThrownBy(() -> due(limit)).isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void selectionCannotJoinAnOuterTransaction() {
    assertThatThrownBy(() -> f.intake.tx.executeWithoutResult(status -> due(5)))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Preparation scan requires a separate transaction");
  }
}
