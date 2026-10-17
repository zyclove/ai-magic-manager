package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedAndroidGateway.*;
import com.aimanager.shared.DomainException;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.http.HttpStatus;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Real journal/preparation/authority; remote operations are explicit local test doubles. */
class ManagedExecutionDispatchTest {
  ManagedExecutionResourceAuthorityTest f;
  ManagedExecutionDispatchService service;
  ManagedAndroidGateway gateway;
  ManagedPolicyExecutionJournal journal;

  @BeforeEach
  void setup() {
    f = new ManagedExecutionResourceAuthorityTest();
    f.setup();
    gateway = f.gateway;
    journal = f.f.sql.journal;
    when(gateway.supportsCompletePolicyDocuments()).thenReturn(true);
    doAnswer(
            call -> {
              outsideTransaction();
              assertThat(view().state())
                  .isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
              assertThat(call.getArgument(2, PolicyDocument.class))
                  .isEqualTo(f.f.prepared.document());
              return new PolicyReceipt(policy(), 7L);
            })
        .when(gateway)
        .writePolicyCandidate(anyString(), anyString(), any());
    doAnswer(
            call -> {
              outsideTransaction();
              assertThat(call.getArgument(2, PolicyDocument.class))
                  .isEqualTo(f.f.prepared.document());
              assertThat(call.getArgument(3, Long.class)).isEqualTo(7L);
              return new CompletePolicyInspection(policy(), 7L, CompletePolicyState.MATCHED);
            })
        .when(gateway)
        .inspectCompletePolicy(anyString(), anyString(), any(), anyLong());
    doAnswer(
            call -> {
              outsideTransaction();
              assertThat(view().state())
                  .isEqualTo(ManagedPolicyExecutionJournal.State.ASSIGNMENT_UNKNOWN);
              return new AssignmentReceipt(device(), policy());
            })
        .when(gateway)
        .assignPolicy(anyString(), anyString(), anyString());
    service = new ManagedExecutionDispatchService(journal, f.service, gateway, f.f.clock);
  }

  @AfterEach
  void close() {
    f.close();
  }

  @Test
  void writesThenInspectsExactVersionWithoutAssigning() {
    assertThat(execute()).isTrue();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_ASSIGN);
    var ordered = inOrder(gateway);
    ordered
        .verify(gateway)
        .writePolicyCandidate(claim().enterpriseId(), claim().policyId(), f.f.prepared.document());
    ordered
        .verify(gateway)
        .inspectCompletePolicy(
            claim().enterpriseId(), claim().policyId(), f.f.prepared.document(), 7L);
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void assignsOnlyAfterExactReadAndFreshPreparation() {
    readyToAssign();
    clearInvocations(f.f.preparation);
    assertThat(execute()).isTrue();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
    verify(f.f.preparation, times(4))
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong());
    var ordered = inOrder(gateway);
    ordered
        .verify(gateway)
        .inspectCompletePolicy(
            claim().enterpriseId(), claim().policyId(), f.f.prepared.document(), 7L);
    ordered
        .verify(gateway)
        .assignPolicy(claim().enterpriseId(), claim().deviceId(), claim().policyId());
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @ParameterizedTest
  @ValueSource(strings = {"WRITE", "ASSIGN"})
  void repeatsDoNotDispatchAgain(String action) {
    if (action.equals("ASSIGN")) readyToAssign();
    assertThat(execute()).isTrue();
    var before = view();
    assertThat(execute()).isFalse();
    assertThat(view()).isEqualTo(before);
    verify(gateway, times(action.equals("WRITE") ? 1 : 0))
        .writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, times(action.equals("ASSIGN") ? 1 : 0))
        .assignPolicy(anyString(), anyString(), anyString());
  }

  @ParameterizedTest
  @ValueSource(strings = {"UNAVAILABLE", "UNSUPPORTED", "AUTHORITY", "CANCELLED", "EXPIRED"})
  void invalidPreflightNeverWrites(String change) {
    switch (change) {
      case "UNAVAILABLE" -> when(gateway.available()).thenReturn(false);
      case "UNSUPPORTED" -> when(gateway.supportsCompletePolicyDocuments()).thenReturn(false);
      case "AUTHORITY" -> when(gateway.supportsPolicyResourceAuthority()).thenReturn(false);
      case "CANCELLED" -> cancel();
      case "EXPIRED" -> f.f.now.set(claim().leaseUntil());
    }
    assertThat(execute()).isFalse();
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @ParameterizedTest
  @ValueSource(strings = {"THROW", "NULL", "NAME", "VERSION", "ZERO"})
  void invalidWriteReceiptRemainsUnknownWithoutRetry(String change) {
    doAnswer(
            call -> {
              if (change.equals("THROW"))
                throw new IllegalStateException("secret provider response");
              return change.equals("NULL")
                  ? null
                  : new PolicyReceipt(
                      change.equals("NAME") ? "other" : policy(),
                      change.equals("VERSION")
                          ? null
                          : change.equals("ZERO") ? Long.valueOf(0) : Long.valueOf(7));
            })
        .when(gateway)
        .writePolicyCandidate(anyString(), anyString(), any());
    assertThat(execute()).isFalse();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
    verify(gateway, times(1)).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).inspectCompletePolicy(anyString(), anyString(), any(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @ParameterizedTest
  @ValueSource(strings = {"THROW", "NULL", "NAME", "VERSION", "CONTENT", "MISSING", "STATE"})
  void writeInspectionMustConfirmExactContentAndVersion(String change) {
    invalidInspection(change);
    assertThat(execute()).isFalse();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @ParameterizedTest
  @ValueSource(strings = {"THROW", "NULL", "NAME", "VERSION", "CONTENT", "MISSING", "STATE"})
  void assignmentInspectionMustConfirmExactContentAndVersion(String change) {
    readyToAssign();
    invalidInspection(change);
    assertThat(execute()).isFalse();
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @ParameterizedTest
  @ValueSource(strings = {"THROW", "NULL", "DEVICE", "POLICY"})
  void uncertainAssignmentIsNotAppliedOrRetried(String change) {
    readyToAssign();
    doAnswer(
            call -> {
              if (change.equals("THROW"))
                throw new IllegalStateException("secret provider response");
              return change.equals("NULL")
                  ? null
                  : new AssignmentReceipt(
                      change.equals("DEVICE") ? "other" : device(),
                      change.equals("POLICY") ? "other" : policy());
            })
        .when(gateway)
        .assignPolicy(anyString(), anyString(), anyString());
    assertThat(execute()).isFalse();
    assertThat(view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.ASSIGNMENT_UNKNOWN);
    verify(gateway, times(1)).assignPolicy(anyString(), anyString(), anyString());
  }

  @ParameterizedTest
  @ValueSource(
      strings = {"CANCEL", "REVOKE", "REVISION", "PROVIDER", "EXPIRE", "RECLAIM", "QUALIFICATION"})
  void changesDuringAssignmentInspectionPreventAssignment(String change) {
    readyToAssign();
    doAnswer(
            call -> {
              change(change);
              return new CompletePolicyInspection(policy(), 7L, CompletePolicyState.MATCHED);
            })
        .when(gateway)
        .inspectCompletePolicy(anyString(), anyString(), any(), anyLong());
    assertThat(execute()).isFalse();
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @ParameterizedTest
  @ValueSource(strings = {"CANCEL", "REVOKE", "REVISION", "PROVIDER", "EXPIRE", "RECLAIM"})
  void changesDuringWriteCannotAdvanceToAssignment(String change) {
    doAnswer(
            call -> {
              change(change);
              return new PolicyReceipt(policy(), 7L);
            })
        .when(gateway)
        .writePolicyCandidate(anyString(), anyString(), any());
    assertThat(execute()).isFalse();
    assertThat(view().state()).isNotEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_ASSIGN);
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void rejectsOuterTransactionBeforeAnyGatewayCall() {
    clearInvocations(gateway);
    assertThatThrownBy(
            () ->
                new TransactionTemplate(f.f.sql.data.transactions)
                    .execute(status -> service.execute(claim())))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Dispatch requires separate short transactions");
    verifyNoInteractions(gateway);
  }

  private void change(String change) {
    switch (change) {
      case "CANCEL" -> cancel();
      case "REVOKE" ->
          when(f.f.sql.bindings.requireVerifiedContext(
                  anyString(), anyString(), anyString(), anyLong()))
              .thenThrow(new DomainException(HttpStatus.FORBIDDEN, "TEST_REVOKED"));
      case "REVISION" ->
          when(gateway.policyResourceAuthorityRevision()).thenReturn("local-authority-v2");
      case "PROVIDER" -> when(gateway.providerCode()).thenReturn("OTHER_PROVIDER");
      case "EXPIRE" -> f.f.now.set(claim().leaseUntil());
      case "RECLAIM" -> {
        f.f.sql.db.update(
            "UPDATE managed_policy_execution_tasks SET"
                + " lease_until=created_at-1,next_attempt_at=created_at WHERE id=?",
            claim().taskId());
        journal.claimDue("LOCAL_TEST", 1);
      }
      case "QUALIFICATION" ->
          when(f.f.preparation.prepare(
                  anyString(), anyString(), anyString(), anyString(), anyLong()))
              .thenThrow(new DomainException(HttpStatus.CONFLICT, "TEST_QUALIFICATION_REVOKED"));
    }
  }

  @ParameterizedTest
  @CsvSource({
    "WRITE,CANCEL",
    "WRITE,REVISION",
    "WRITE,EXPIRE",
    "WRITE,RECLAIM",
    "WRITE,REVOKE",
    "ASSIGN,CANCEL",
    "ASSIGN,REVISION",
    "ASSIGN,EXPIRE",
    "ASSIGN,RECLAIM",
    "ASSIGN,REVOKE"
  })
  void changesAfterCommittedCheckpointPreventExternalWrite(String action, String change) {
    if (action.equals("ASSIGN")) readyToAssign();
    var observedJournal = spy(journal);
    doAnswer(
            call -> {
              boolean committed = (boolean) call.callRealMethod();
              if (committed) change(change);
              return committed;
            })
        .when(observedJournal)
        .beforeWrite(any(ManagedPolicyExecutionJournal.WritePreparationTarget.class), anyLong());
    service = new ManagedExecutionDispatchService(observedJournal, f.service, gateway, f.f.clock);
    assertThat(execute()).isFalse();
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  private void invalidInspection(String change) {
    doAnswer(
            call -> {
              if (change.equals("THROW"))
                throw new IllegalStateException("secret provider response");
              return change.equals("NULL")
                  ? null
                  : new CompletePolicyInspection(
                      change.equals("NAME") ? "other" : policy(),
                      change.equals("VERSION") ? Long.valueOf(8) : Long.valueOf(7),
                      switch (change) {
                        case "CONTENT" -> CompletePolicyState.CONTENT_MISMATCH;
                        case "MISSING" -> CompletePolicyState.NOT_FOUND;
                        case "STATE" -> null;
                        default -> CompletePolicyState.MATCHED;
                      });
            })
        .when(gateway)
        .inspectCompletePolicy(anyString(), anyString(), any(), anyLong());
  }

  private boolean execute() {
    return assertDoesNotThrow(() -> service.execute(claim()));
  }

  private ManagedPolicyExecutionJournal.Claim claim() {
    return f.f.f.claim;
  }

  private ManagedPolicyExecutionJournal.View view() {
    return f.f.f.view();
  }

  private String policy() {
    return "enterprises/" + claim().enterpriseId() + "/policies/" + claim().policyId();
  }

  private String device() {
    return "enterprises/" + claim().enterpriseId() + "/devices/" + claim().deviceId();
  }

  private void cancel() {
    journal.cancel(claim().tenantId(), f.f.device.actor(), claim().taskId(), view().revision());
  }

  private void outsideTransaction() {
    assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
  }

  private void readyToAssign() {
    assertThat(journal.beforeWrite(journal.writePreparationTarget(claim()), claim().leaseUntil()))
        .isTrue();
    assertThat(journal.policyWritten(claim(), new PolicyReceipt(policy(), 7L))).isTrue();
    f.f.f.claim = journal.claimDue("LOCAL_TEST", 1).get(0);
  }
}
