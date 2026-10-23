package com.aimanager.retention.internal;

import static org.assertj.core.api.Assertions.*;

import java.util.Objects;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;

/** Pending test proposal: real schema, bounded cleanup and no cross-subject erasure. */
class ErasurePreparationRequestsTest implements AutoCloseable {
  ErasureManagedBindingProcessorTest f;
  JdbcTemplate db;

  @Override
  @AfterEach
  public void close() {
    if (f != null) f.close();
  }

  @BeforeEach
  void setup() {
    f = new ErasureManagedBindingProcessorTest();
    f.setup();
    db = f.db;
  }

  @ParameterizedTest
  @ValueSource(strings = {"CANCELLED", "REJECTED"})
  void terminalRequestsUseTheSharedRowBudgetBeforeBindings(String state) {
    var device = f.fixture.device(f.subject);
    String binding = f.binding(device, "REVOKED");
    for (int i = 0; i < 7; i++) request(binding, state);
    var claim = f.fixture.accept(device);
    assertThatCode(() -> f.processor.process(claim, 3)).doesNotThrowAnyException();
    assertThat(f.count("managed_policy_preparation_requests")).isEqualTo(4);
    assertThat(f.count("managed_agent_bindings")).isEqualTo(1);
    var result = f.finish(claim, 3);
    assertThat(result.complete()).isTrue();
    assertThat(f.count("managed_policy_preparation_requests")).isZero();
    assertThat(result.totalRows()).isEqualTo(1);
    assertThat(f.count("policy_publications")).isEqualTo(7);
  }

  @Test
  void pendingRequestBlocksErasureBeforeAnyDeletion() {
    var device = f.fixture.device(f.subject);
    request(f.binding(device, "REVOKED"), "PENDING");
    var claim = f.fixture.accept(device);
    f.fixture.data.failure(
        "ERASURE_PREPARATION_TERMINATION_REQUIRED", () -> f.processor.process(claim, 25));
    assertThat(f.count("managed_policy_preparation_requests")).isEqualTo(1);
    assertThat(f.count("erasure_recovery_steps")).isZero();
  }

  @Test
  void leasedReadCannotDisappearWhileItsResultIsInFlight() {
    var device = f.fixture.device(f.subject);
    String request = request(f.binding(device, "REVOKED"), "PENDING");
    db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " generation=1,attempts=1,lease_token=?,lease_until=100 WHERE tenant_id=? AND id=?",
        f.id(),
        f.tenant,
        request);
    var claim = f.fixture.accept(device);
    f.fixture.data.failure(
        "ERASURE_PREPARATION_TERMINATION_REQUIRED", () -> f.processor.process(claim, 25));
    assertThat(f.count("managed_policy_preparation_requests")).isEqualTo(1);
  }

  @Test
  void requestSubjectMustAgreeWithBindingEvenWhenForeignKeysAreValid() {
    var device = f.fixture.device(f.subject);
    String request = request(f.binding(device, "REVOKED"), "CANCELLED");
    db.update(
        "UPDATE managed_policy_preparation_requests SET subject_id=? WHERE tenant_id=? AND id=?",
        f.fixture.peer,
        f.tenant,
        request);
    var claim = f.fixture.accept(device);
    f.fixture.data.failure(
        "ERASURE_PREPARATION_SCOPE_CORRUPT", () -> f.processor.process(claim, 25));
    assertThat(f.count("managed_policy_preparation_requests")).isEqualTo(1);
  }

  @Test
  void requestRegistrationMustAgreeWithItsBinding() {
    var device = f.fixture.device(f.subject);
    var another = f.fixture.device(f.subject);
    String request = request(f.binding(device, "REVOKED"), "CANCELLED");
    db.update(
        "UPDATE managed_policy_preparation_requests SET device_id=?,registration_id=? WHERE"
            + " tenant_id=? AND id=?",
        another.id(),
        another.registration(),
        f.tenant,
        request);
    var claim = f.fixture.accept(device, another);
    f.fixture.data.failure(
        "ERASURE_PREPARATION_SCOPE_CORRUPT", () -> f.processor.process(claim, 25));
  }

  @Test
  void otherStudentsRequestsAndBindingsRemain() {
    var device = f.fixture.device(f.subject);
    String owned = request(f.binding(device, "REVOKED"), "CANCELLED");
    String peer = request(f.binding(f.fixture.device(f.fixture.peer), "REVOKED"), "PENDING");
    var claim = f.fixture.accept(device);
    assertThatCode(() -> f.finish(claim, 2)).doesNotThrowAnyException();
    assertThat(
            db.queryForList(
                "SELECT id FROM managed_policy_preparation_requests WHERE tenant_id=?",
                String.class,
                f.tenant))
        .containsExactly(peer)
        .doesNotContain(owned);
  }

  @Test
  void failureAfterRequestDeletionRollsBackRequestAndCheckpoint() {
    var device = f.fixture.device(f.subject);
    request(f.binding(device, "REVOKED"), "CANCELLED");
    var claim = f.fixture.accept(device);
    var faulty =
        new JdbcTemplate(Objects.requireNonNull(db.getDataSource())) {
          @Override
          public int update(String sql, Object... args) {
            int changed = super.update(sql, args);
            if (sql.startsWith("DELETE FROM managed_policy_preparation_requests"))
              throw new IllegalStateException("PREPARATION_DELETE_FAILED");
            return changed;
          }
        };
    var processor =
        new ErasureManagedBindingProcessor(f.fixture.data.jobs, faulty, f.fixture.catalog);
    assertThatThrownBy(() -> processor.process(claim, 1))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("PREPARATION_DELETE_FAILED");
    assertThat(f.count("managed_policy_preparation_requests")).isEqualTo(1);
    assertThat(f.count("erasure_recovery_steps")).isZero();
  }

  @Test
  void admittedReferenceIsDeletedBeforeItsTerminalTaskUsingOneBudget() {
    var device = f.fixture.device(f.subject);
    String request = request(f.binding(device, "REVOKED"), "PENDING");
    linkTask(request, "CANCELLED");
    var claim = f.fixture.accept(device);
    assertThatCode(() -> f.processor.process(claim, 1)).doesNotThrowAnyException();
    assertThat(f.count("managed_policy_preparation_requests")).isZero();
    assertThat(f.count("managed_policy_execution_tasks")).isEqualTo(1);
    assertThat(f.count("managed_agent_bindings")).isEqualTo(1);
    assertThatCode(() -> f.processor.process(claim, 1)).doesNotThrowAnyException();
    assertThat(f.count("managed_policy_execution_tasks")).isZero();
    assertThat(f.count("managed_agent_bindings")).isEqualTo(1);
    assertThat(f.finish(claim, 1).complete()).isTrue();
  }

  @Test
  void admittedReferenceCannotHideAnUncertainProviderWrite() {
    var device = f.fixture.device(f.subject);
    String request = request(f.binding(device, "REVOKED"), "PENDING");
    linkTask(request, "POLICY_WRITE_UNKNOWN");
    var claim = f.fixture.accept(device);
    f.fixture.data.failure(
        "ERASURE_EXECUTION_RECONCILIATION_REQUIRED", () -> f.processor.process(claim, 25));
    assertThat(f.count("managed_policy_preparation_requests")).isEqualTo(1);
  }

  @Test
  void admittedReferenceCannotPointToAnotherDevicesValidTask() {
    var device = f.fixture.device(f.subject);
    var other = f.fixture.device(f.subject);
    String first = request(f.binding(device, "REVOKED"), "CANCELLED");
    String second = request(f.binding(other, "REVOKED"), "PENDING");
    String task = linkTask(second, "CANCELLED");
    db.update(
        "UPDATE managed_policy_preparation_requests SET state='CANCELLED',execution_task_id=NULL"
            + " WHERE tenant_id=? AND id=?",
        f.tenant,
        second);
    db.update(
        "UPDATE managed_policy_preparation_requests SET state='ADMITTED',execution_task_id=? WHERE"
            + " tenant_id=? AND id=?",
        task,
        f.tenant,
        first);
    var claim = f.fixture.accept(device, other);
    f.fixture.data.failure(
        "ERASURE_PREPARATION_SCOPE_CORRUPT", () -> f.processor.process(claim, 25));
    assertThat(f.count("managed_policy_preparation_requests")).isEqualTo(2);
  }

  private String linkTask(String request, String state) {
    String task = f.id();
    db.update(
        "INSERT INTO"
            + " managed_policy_execution_tasks(tenant_id,id,publication_id,policy_version_id,subject_id,device_id,registration_id,binding_id,binding_version,actor_id,authority_version,context_sha256,document_json,document_sha256,provider,enterprise_id,provider_device_id,provider_policy_id,state,active_device_id,next_attempt_at,expires_at,reason_code,created_at,updated_at)"
            + " SELECT"
            + " r.tenant_id,?,r.publication_id,r.policy_version_id,r.subject_id,r.device_id,r.registration_id,r.binding_id,r.binding_version,r.actor_id,r.authority_version,r.context_sha256,'{}',?,b.provider,b.enterprise_id,b.provider_device_id,?,?,CASE"
            + " WHEN ?='CANCELLED' THEN NULL ELSE r.device_id END,1,600001,'QUEUED',1,1 FROM"
            + " managed_policy_preparation_requests r JOIN managed_agent_bindings b ON"
            + " b.tenant_id=r.tenant_id AND b.id=r.binding_id WHERE r.tenant_id=? AND r.id=?",
        task,
        "a".repeat(64),
        "policy-" + task,
        state,
        state,
        f.tenant,
        request);
    db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " state='ADMITTED',execution_task_id=?,active_device_id=NULL WHERE tenant_id=? AND"
            + " id=?",
        task,
        f.tenant,
        request);
    return task;
  }

  private String request(String binding, String state) {
    String draft = f.id(),
        preview = f.id(),
        version = f.id(),
        publication = f.id(),
        request = f.id();
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'fixture','POLICY','[]',1,1)",
        f.tenant,
        draft);
    db.update(
        "INSERT INTO"
            + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at)"
            + " VALUES(?,?,?,0,?,'{}',1,600001)",
        f.tenant,
        preview,
        draft,
        "a".repeat(64));
    db.update(
        "INSERT INTO"
            + " policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at)"
            + " VALUES(?,?,?,0,1,?,?,'ENFORCE','{}',1)",
        f.tenant,
        version,
        draft,
        preview,
        "a".repeat(64));
    db.update(
        "INSERT INTO policy_publications(tenant_id,id,version_id,state,created_at)"
            + " VALUES(?,?,?,'QUEUED',1)",
        f.tenant,
        publication,
        version);
    db.update(
        "INSERT INTO"
            + " managed_policy_preparation_requests(tenant_id,id,publication_id,policy_version_id,subject_id,device_id,registration_id,binding_id,binding_version,actor_id,authority_version,context_sha256,state,reason_code,active_device_id,next_attempt_at,expires_at,created_at,updated_at)"
            + " SELECT"
            + " tenant_id,?,?,?,subject_id,device_id,registration_id,id,version,'fixture',0,?,?,"
            + " 'QUEUED',CASE WHEN ?='PENDING' THEN device_id ELSE NULL END,1,600001,1,1 FROM"
            + " managed_agent_bindings WHERE tenant_id=? AND id=?",
        request,
        publication,
        version,
        "b".repeat(64),
        state,
        state,
        f.tenant,
        binding);
    return request;
  }
}
