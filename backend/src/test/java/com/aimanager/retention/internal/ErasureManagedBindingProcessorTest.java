package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;

class ErasureManagedBindingProcessorTest {
  ErasureObservationProcessorTest fixture;
  JdbcTemplate db;
  ErasureManagedBindingProcessor processor;
  String tenant, subject;
  final Set<String> testTenants = new LinkedHashSet<>();

  String id() {
    return UUID.randomUUID().toString();
  }

  @BeforeEach
  void setup() {
    fixture = new ErasureObservationProcessorTest();
    fixture.setup();
    db = fixture.db;
    tenant = fixture.tenant;
    subject = fixture.subject;
    testTenants.clear();
    testTenants.add(tenant);
    enterprise(tenant);
    processor = new ErasureManagedBindingProcessor(fixture.data.jobs, db, fixture.catalog);
  }

  void enterprise(String owner) {
    db.update(
        "INSERT INTO"
            + " managed_enterprise_bindings(tenant_id,provider,enterprise_id,contract_reference,"
            + "state,version,requested_by,created_at,updated_at)"
            + " VALUES(?,'LOCAL',?,'fixture','ACTIVE',1,'fixture',1,1)",
        owner,
        "enterprises/" + owner);
  }

  String intent(String owner, String person) {
    String intent = id();
    db.update(
        "INSERT INTO managed_enrollment_intents(tenant_id,id,subject_id,provider,enterprise_id,"
            + "binding_version,policy_id,nonce_hash,provider_device_id,state,version,requested_by,created_at,expires_at,updated_at)"
            + " VALUES(?,?,?,'LOCAL',?,1,'policies/fixture',?,?,'VERIFIED',1,'fixture',1,600001,1)",
        owner,
        intent,
        person,
        "enterprises/" + owner,
        id().replace("-", "").repeat(2),
        "devices/" + id());
    db.update(
        "INSERT INTO"
            + " managed_enrollment_intent_events(tenant_id,intent_id,version,id,action,actor_id,correlation_id,occurred_at)"
            + " VALUES(?,?,1,?,'VERIFIED','fixture',?,1)",
        owner,
        intent,
        id(),
        id());
    return intent;
  }

  String binding(ErasureObservationProcessorTest.Device device, String state) {
    return binding(tenant, device, device.subject(), intent(tenant, device.subject()), state);
  }

  String binding(
      String owner,
      ErasureObservationProcessorTest.Device device,
      String person,
      String enrollment,
      String state) {
    String binding = id();
    db.update(
        "INSERT INTO managed_agent_bindings(tenant_id,id,subject_id,enrollment_id,device_id,"
            + "registration_id,key_thumbprint,provider,enterprise_id,enterprise_binding_version,"
            + "provider_device_id,package_name,request_key,requested_by,state,version,created_at,"
            + "expires_at,updated_at,proof_sha256,proof_id)"
            + " VALUES(?,?,?,?,?,?,?,'LOCAL',?,1,?,'com.aimanager.child',?,'fixture',?,1,1,600001,1,?,?)",
        owner,
        binding,
        person,
        enrollment,
        device.id(),
        device.registration(),
        "b".repeat(64),
        "enterprises/" + owner,
        "devices/" + id(),
        id(),
        state,
        "a".repeat(64),
        id());
    return binding;
  }

  long count(String table) {
    if (table.equals("erasure_recovery_steps"))
      return db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_steps", Long.class);
    return db.queryForObject(
        "SELECT COUNT(*) FROM " + table + " WHERE " + tenantFilter(),
        Long.class,
        testTenants.toArray());
  }

  String tenantFilter() {
    return "tenant_id IN (" + String.join(",", Collections.nCopies(testTenants.size(), "?")) + ")";
  }

  ErasureManagedBindingProcessor.Result finish(ErasureRecoveryJobs.Claim claim, int limit) {
    for (int n = 0; n < 50; n++) {
      var result = processor.process(claim, limit);
      assertTrue(result.deletedRows() <= limit);
      if (result.complete()) return result;
    }
    throw new AssertionError("Processor did not finish bounded batches");
  }

  @Test
  void boundedCleanupKeepsOtherStudentsTenantsProviderRecordsAndAudit() {
    var target = fixture.device(subject);
    for (int n = 0; n < 27; n++) binding(target, n % 2 == 0 ? "REVOKED" : "EXPIRED");
    String peerBinding = binding(fixture.device(fixture.peer), "VERIFIED");
    String otherTenant = id(), otherSubject = id();
    testTenants.add(otherTenant);
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'other','FAMILY','UTC',1)",
        otherTenant);
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'other','AGE_7_12',1)",
        otherTenant,
        otherSubject);
    enterprise(otherTenant);
    var other = new ErasureObservationProcessorTest.Device(id(), id(), otherSubject);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'other','ANDROID','14','ACTIVE','{}',?,1)",
        otherTenant,
        other.id(),
        otherSubject,
        other.registration(),
        "c".repeat(64));
    String otherBinding =
        binding(otherTenant, other, otherSubject, intent(otherTenant, otherSubject), "VERIFIED");
    var claim = fixture.accept(target);
    var first = processor.process(claim, 25);
    assertEquals("DATA", first.phase());
    assertEquals(25, first.deletedRows());
    var result = finish(claim, 25);
    assertEquals(27, result.totalRows());
    assertEquals(2, result.batches());
    assertEquals(
        Set.of(peerBinding, otherBinding),
        new HashSet<>(
            db.queryForList(
                "SELECT id FROM managed_agent_bindings WHERE " + tenantFilter(),
                String.class,
                testTenants.toArray())));
    assertEquals(29, count("managed_enrollment_intents"));
    assertEquals(29, count("managed_enrollment_intent_events"));
    assertEquals(3, count("devices"));
    assertEquals(
        "CLAIMED", fixture.data.jobs.find(claim.job().entry().request().requestId()).state());
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, fixture.data.ledger.workState());
    assertEquals(result.batches(), processor.process(claim, 25).batches());
  }

  @Test
  void bindingCleanupCascadesOnlyItsApplicationEvidenceAndKeepsSharedCatalog() {
    var target = fixture.device(subject);
    String owned = binding(target, "REVOKED");
    String peer = binding(fixture.device(fixture.peer), "VERIFIED");
    applicationEvidence(owned);
    applicationEvidence(peer);
    var result = finish(fixture.accept(target), 25);
    assertEquals(1, result.totalRows());
    assertEquals(
        List.of(peer),
        db.queryForList(
            "SELECT binding_id FROM managed_application_evidence WHERE tenant_id=?",
            String.class,
            tenant));
    assertEquals(2, count("application_definitions"));
  }

  @Test
  void unexpectedlyOversizedEvidenceSetStopsBeforeUnboundedCascade() {
    var target = fixture.device(subject);
    String owned = binding(target, "REVOKED");
    for (int n = 0; n < 201; n++) applicationEvidence(owned);
    fixture.data.failure(
        "ERASURE_APPLICATION_EVIDENCE_LIMIT_EXCEEDED",
        () -> processor.process(fixture.accept(target), 25));
    assertEquals(201, count("managed_application_evidence"));
    assertEquals(1, count("managed_agent_bindings"));
    assertEquals(0, count("erasure_recovery_steps"));
  }

  private void applicationEvidence(String binding) {
    String app = id();
    db.update(
        "INSERT INTO application_definitions(tenant_id,id,identity_hash,definition_json)"
            + " VALUES(?,?,?,'{}')",
        tenant,
        app,
        com.aimanager.shared.SecretMaterial.hash(app));
    db.update(
        "INSERT INTO"
            + " managed_application_evidence(tenant_id,binding_id,application_id,id,context_revision,state,reason_code,version,attempt_expires_at,next_attempt_at,created_at,updated_at)"
            + " VALUES(?,?,?,?,?,'WAITING_REPORT','MANAGED_APPLICATION_REPORT_MISSING',1,0,0,1,1)",
        tenant,
        binding,
        app,
        id(),
        "a".repeat(64));
  }

  @Test
  void executionHistoryUsesTheSharedBatchBudgetBeforeBindingErasure() {
    var target = fixture.device(subject);
    String owned = binding(target, "REVOKED");
    for (int i = 0; i < 27; i++) executionTask(owned, "CANCELLED");
    var claim = fixture.accept(target);
    var first = processor.process(claim, 5);
    assertEquals(5, first.deletedExecutionTasks());
    assertEquals(0, first.deletedRows());
    assertEquals("DATA", first.phase());
    assertEquals(22, count("managed_policy_execution_tasks"));
    assertEquals(1, count("managed_agent_bindings"));
    var done = finish(claim, 5);
    assertEquals(1, done.totalRows());
    assertEquals(0, count("managed_policy_execution_tasks"));
    assertEquals(0, count("managed_policy_execution_events"));
    assertEquals(27, count("policy_publications"));
  }

  @ParameterizedTest
  @ValueSource(strings = {"READY_TO_WRITE", "POLICY_WRITE_UNKNOWN", "NEEDS_REVIEW"})
  void unresolvedExecutionCannotDisappearWithBindingErasure(String state) {
    var target = fixture.device(subject);
    executionTask(binding(target, "REVOKED"), state);
    fixture.data.failure(
        "ERASURE_EXECUTION_RECONCILIATION_REQUIRED",
        () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("managed_policy_execution_tasks"));
    assertEquals(1, count("managed_agent_bindings"));
    assertEquals(0, count("erasure_recovery_steps"));
  }

  @Test
  void oversizedExecutionEventsStopBeforeCascade() {
    var target = fixture.device(subject);
    String task = executionTask(binding(target, "REVOKED"), "CANCELLED");
    for (int revision = 2; revision <= 101; revision++)
      db.update(
          "INSERT INTO"
              + " managed_policy_execution_events(tenant_id,task_id,revision,generation,state,reason_code,occurred_at)"
              + " VALUES(?,?,?,0,'CANCELLED','CANCELLED_BEFORE_ASSIGNMENT',1)",
          tenant,
          task,
          revision);
    fixture.data.failure(
        "ERASURE_EXECUTION_HISTORY_LIMIT_EXCEEDED",
        () -> processor.process(fixture.accept(target), 25));
    assertEquals(101, count("managed_policy_execution_events"));
    assertEquals(1, count("managed_policy_execution_tasks"));
  }

  @Test
  void terminalTaskWithResidualLeaseCannotBeErased() {
    var target = fixture.device(subject);
    String task = executionTask(binding(target, "REVOKED"), "CANCELLED");
    db.update(
        "UPDATE managed_policy_execution_tasks SET"
            + " lease_token=?,lease_until=100,action='READ_DEVICE' WHERE id=?",
        id(),
        task);
    fixture.data.failure(
        "ERASURE_EXECUTION_RECONCILIATION_REQUIRED",
        () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("managed_policy_execution_tasks"));
  }

  @Test
  void taskOwnedByAnotherSubjectCannotCascadeThroughBinding() {
    var target = fixture.device(subject);
    String task = executionTask(binding(target, "REVOKED"), "CANCELLED");
    db.update(
        "UPDATE managed_policy_execution_tasks SET subject_id=? WHERE id=?", fixture.peer, task);
    fixture.data.failure(
        "ERASURE_EXECUTION_SCOPE_CORRUPT", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("managed_policy_execution_tasks"));
    assertEquals(1, count("managed_agent_bindings"));
  }

  private String executionTask(String binding, String state) {
    String draft = id(), preview = id(), version = id(), publication = id(), task = id();
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'fixture','POLICY','[]',1,1)",
        tenant,
        draft);
    db.update(
        "INSERT INTO"
            + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at)"
            + " VALUES(?,?,?,0,?,'{}',1,600001)",
        tenant,
        preview,
        draft,
        "a".repeat(64));
    db.update(
        "INSERT INTO"
            + " policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at)"
            + " VALUES(?,?,?,0,1,?,?,'ENFORCE','{}',1)",
        tenant,
        version,
        draft,
        preview,
        "a".repeat(64));
    db.update(
        "INSERT INTO policy_publications(tenant_id,id,version_id,state,created_at)"
            + " VALUES(?,?,?,'QUEUED',1)",
        tenant,
        publication,
        version);
    db.update(
        "INSERT INTO"
            + " managed_policy_execution_tasks(tenant_id,id,publication_id,policy_version_id,subject_id,device_id,registration_id,"
            + "binding_id,binding_version,actor_id,authority_version,context_sha256,document_json,document_sha256,provider,enterprise_id,"
            + "provider_device_id,provider_policy_id,state,active_device_id,next_attempt_at,expires_at,reason_code,created_at,updated_at)"
            + " SELECT"
            + " tenant_id,?,?,?,subject_id,device_id,registration_id,id,version,'fixture',0,?,'{}',?,provider,enterprise_id,provider_device_id,?,?,CASE"
            + " WHEN ?='CANCELLED' THEN NULL ELSE device_id END,1,600001,'QUEUED',1,1 FROM"
            + " managed_agent_bindings WHERE tenant_id=? AND id=?",
        task,
        publication,
        version,
        "a".repeat(64),
        "b".repeat(64),
        "policy-" + task,
        state,
        state,
        tenant,
        binding);
    db.update(
        "INSERT INTO"
            + " managed_policy_execution_events(tenant_id,task_id,revision,generation,state,reason_code,occurred_at)"
            + " VALUES(?,?,1,0,?,'QUEUED',1)",
        tenant,
        task,
        state);
    return task;
  }

  @ParameterizedTest
  @ValueSource(strings = {"PENDING", "VERIFIED"})
  void activeAssociationBlocksEveryDeletion(String state) {
    var target = fixture.device(subject);
    binding(target, "REVOKED");
    binding(target, state);
    fixture.data.failure(
        "ERASURE_MANAGED_BINDING_EXIT_REQUIRED",
        () -> processor.process(fixture.accept(target), 25));
    assertEquals(2, count("managed_agent_bindings"));
    assertEquals(0, count("erasure_recovery_steps"));
  }

  @ParameterizedTest
  @ValueSource(strings = {"nonce", "active_device_id", "active_enrollment_id", "version"})
  void residualChallengeOrActiveSlotIsNotSilentlyErased(String column) {
    var target = fixture.device(subject);
    String binding = binding(target, "EXPIRED");
    db.update(
        "UPDATE managed_agent_bindings SET " + column + "=? WHERE id=?",
        column.equals("version") ? 0 : id(),
        binding);
    fixture.data.failure(
        "ERASURE_MANAGED_BINDING_STATE_CORRUPT",
        () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("managed_agent_bindings"));
    assertEquals(0, count("erasure_recovery_steps"));
  }

  @ParameterizedTest
  @ValueSource(strings = {"device", "scope", "credential"})
  void deviceExitIsRequiredBeforeLocalAssociationErasure(String source) {
    var target = fixture.device(subject);
    binding(target, "REVOKED");
    switch (source) {
      case "device" ->
          db.update(
              "UPDATE devices SET state='ACTIVE' WHERE tenant_id=? AND id=?", tenant, target.id());
      case "scope" ->
          db.update(
              "INSERT INTO device_credential_scopes(tenant_id,device_id,registration_id,active)"
                  + " VALUES(?,?,?,true)",
              tenant,
              target.id(),
              target.registration());
      case "credential" ->
          db.update(
              "INSERT INTO"
                  + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
                  + " VALUES(?,?,?,?,?,true,1,?)",
              id(),
              tenant,
              target.id(),
              target.registration(),
              "f".repeat(64),
              System.currentTimeMillis() + 600000);
      default -> fail("Unknown fixture");
    }
    fixture.data.failure(
        "ERASURE_DEVICE_EXIT_REQUIRED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("managed_agent_bindings"));
  }

  @Test
  void wrongRegistrationCannotEraseCurrentAssociation() {
    var current = fixture.device(subject);
    binding(current, "REVOKED");
    var old = new ErasureObservationProcessorTest.Device(current.id(), id(), subject);
    fixture.data.failure("ERASURE_SCOPE_CHANGED", () -> processor.process(fixture.accept(old), 25));
    assertEquals(1, count("managed_agent_bindings"));
  }

  @Test
  void bindingStudentMustMatchTheCapturedDeviceScope() {
    var target = fixture.device(subject);
    binding(tenant, target, fixture.peer, intent(tenant, fixture.peer), "REVOKED");
    fixture.data.failure(
        "ERASURE_SCOPE_CHANGED", () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("managed_agent_bindings"));
  }

  @Test
  void enrollmentStudentMismatchIsRejectedEvenWhenForeignKeysAreValid() {
    var target = fixture.device(subject);
    binding(tenant, target, subject, intent(tenant, fixture.peer), "REVOKED");
    fixture.data.failure(
        "ERASURE_MANAGED_BINDING_SCOPE_CORRUPT",
        () -> processor.process(fixture.accept(target), 25));
    assertEquals(1, count("managed_agent_bindings"));
  }

  @Test
  void emptyRegistrationScopeNeverMatchesOtherStudents() {
    binding(fixture.device(fixture.peer), "VERIFIED");
    assertEquals(0, finish(fixture.accept(), 25).totalRows());
    assertEquals(1, count("managed_agent_bindings"));
  }

  @Test
  void completedStepRequiresRecheckIfDataReappears() {
    var target = fixture.device(subject);
    binding(target, "REVOKED");
    var claim = fixture.accept(target);
    assertTrue(finish(claim, 25).complete());
    binding(target, "REVOKED");
    fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    assertEquals(1, count("managed_agent_bindings"));
  }

  @Test
  void expiredWorkerCannotEraseAndCurrentWorkerCanResume() {
    var target = fixture.device(subject);
    binding(target, "REVOKED");
    var old = fixture.accept(target);
    db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
    var current = fixture.data.jobs.claim(id(), 300);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> processor.process(old, 25));
    assertEquals(1, count("managed_agent_bindings"));
    assertEquals(1, finish(current, 25).totalRows());
  }

  @Test
  void storageFailureAfterDeletionRollsBackBothRowsAndCheckpoint() {
    var target = fixture.device(subject);
    binding(target, "REVOKED");
    var claim = fixture.accept(target);
    var faulty =
        new JdbcTemplate(Objects.requireNonNull(db.getDataSource())) {
          @Override
          public int update(String sql, Object... args) {
            int result = super.update(sql, args);
            if (sql.startsWith("DELETE FROM managed_agent_bindings"))
              throw new IllegalStateException("Injected after deletion");
            return result;
          }
        };
    var failing = new ErasureManagedBindingProcessor(fixture.data.jobs, faulty, fixture.catalog);
    assertThrows(IllegalStateException.class, () -> failing.process(claim, 25));
    assertEquals(1, count("managed_agent_bindings"));
    assertEquals(0, count("erasure_recovery_steps"));
    assertEquals(1, finish(claim, 25).totalRows());
  }

  @Test
  void concurrentBatchesDoNotDoubleDeleteOrDoubleCount() throws Exception {
    var target = fixture.device(subject);
    for (int n = 0; n < 7; n++) binding(target, "REVOKED");
    var claim = fixture.accept(target);
    var pool = Executors.newFixedThreadPool(2);
    try {
      var first = pool.submit(() -> processor.process(claim, 3));
      var second = pool.submit(() -> processor.process(claim, 3));
      assertEquals(
          6,
          first.get(20, TimeUnit.SECONDS).deletedRows()
              + second.get(20, TimeUnit.SECONDS).deletedRows());
    } finally {
      pool.shutdownNow();
      assertTrue(pool.awaitTermination(20, TimeUnit.SECONDS));
    }
    assertEquals(7, finish(claim, 3).totalRows());
    assertEquals(0, count("managed_agent_bindings"));
  }

  @Test
  void leaseLossAfterDeletionRollsBackAnExistingCheckpoint() {
    var target = fixture.device(subject);
    for (int n = 0; n < 3; n++) binding(target, "REVOKED");
    var claim = fixture.accept(target);
    assertEquals(1, processor.process(claim, 1).totalRows());
    var faulty =
        new JdbcTemplate(Objects.requireNonNull(db.getDataSource())) {
          @Override
          public int update(String sql, Object... args) {
            int result = super.update(sql, args);
            if (sql.startsWith("DELETE FROM managed_agent_bindings"))
              super.update(
                  "UPDATE erasure_recovery_jobs SET lease_until=1 WHERE request_id=?",
                  claim.job().entry().request().requestId());
            return result;
          }
        };
    var failing = new ErasureManagedBindingProcessor(fixture.data.jobs, faulty, fixture.catalog);
    fixture.data.failure("ERASURE_RECOVERY_LEASE_LOST", () -> failing.process(claim, 25));
    assertEquals(2, count("managed_agent_bindings"));
    assertEquals(
        1L,
        db.queryForObject(
            "SELECT rows_processed FROM erasure_recovery_steps WHERE request_id=? AND"
                + " step_code='MANAGED_AGENT_BINDINGS'",
            Long.class,
            claim.job().entry().request().requestId()));
    assertEquals(3, finish(claim, 25).totalRows());
  }

  @ParameterizedTest
  @ValueSource(strings = {"version", "phase", "cursor", "overflow"})
  void incompatibleOrCorruptCheckpointCannotAdvance(String mutation) {
    var target = fixture.device(subject);
    binding(target, "REVOKED");
    binding(target, "REVOKED");
    var claim = fixture.accept(target);
    processor.process(claim, 1);
    String assignment =
        switch (mutation) {
          case "version" -> "handler_version=2";
          case "phase" -> "phase='VERIFY'";
          case "cursor" -> "phase='VERIFY',cursor_id='11111111-1111-4111-8111-111111111111'";
          case "overflow" -> "rows_processed=9223372036854775807";
          default -> throw new AssertionError("Unknown fixture");
        };
    db.update(
        "UPDATE erasure_recovery_steps SET "
            + assignment
            + " WHERE request_id=? AND step_code='MANAGED_AGENT_BINDINGS'",
        claim.job().entry().request().requestId());
    fixture.data.failure(
        mutation.equals("version") ? "ERASURE_STEP_VERSION_UNSUPPORTED" : "ERASURE_STEP_CORRUPT",
        () -> processor.process(claim, 25));
    assertEquals(1, count("managed_agent_bindings"));
  }

  @Test
  void batchLimitsAreEnforcedBeforeClaimAccess() {
    assertThrows(IllegalArgumentException.class, () -> processor.process(null, 0));
    assertThrows(IllegalArgumentException.class, () -> processor.process(null, 26));
  }
}
