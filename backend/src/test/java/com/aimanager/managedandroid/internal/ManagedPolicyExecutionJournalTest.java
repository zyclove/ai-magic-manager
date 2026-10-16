package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.audit.AuditService;
import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.managedandroid.ManagedPolicyWriteException;
import com.aimanager.managedandroid.ManagedPolicyWriteException.Outcome;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.google.api.client.googleapis.MethodOverride;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.util.List;
import java.util.Set;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.GZIPInputStream;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.support.TransactionTemplate;

/** Fresh real schema; no running database, provider credentials or device is used. */
class ManagedPolicyExecutionJournalTest {
  ManagedExecutionTestData data;
  JdbcTemplate db;
  ManagedExecutionTestData.Fixture f;
  ManagedPolicyExecutionJournal journal;
  ManagedAgentBindingStore bindings;
  ManagedExecutionPublicationAccess publications;
  AuditService audit;
  ManagedAgentBindingStore.VerifiedBindingContext context;
  long deadline;
  static final String DOCUMENT =
      "{\"schemaVersion\":1,\"adapterRevision\":\"local-v1\",\"policy\":{\"applications\":[]}}";

  @BeforeEach
  void setup() {
    data = new ManagedExecutionTestData();
    db = data.db;
    f = data.fixture();
    bindings = mock(ManagedAgentBindingStore.class);
    publications = mock(ManagedExecutionPublicationAccess.class);
    context =
        new ManagedAgentBindingStore.VerifiedBindingContext(
            f.tenant(),
            f.actor(),
            0,
            f.subject(),
            f.device(),
            f.registration(),
            "a".repeat(64),
            f.binding(),
            2,
            f.enrollment(),
            1,
            "LOCAL_TEST",
            f.enterprise(),
            1,
            f.providerDevice(),
            "DEVICE_OWNER",
            2,
            "com.aimanager.child",
            "b".repeat(64),
            Device.Platform.ANDROID,
            1);
    when(bindings.requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2))
        .thenAnswer(
            call -> {
              // Simulate the lower authority boundary's device lock, preserving real admission
              // serialization.
              db.queryForList(
                  "SELECT id FROM managed_agent_bindings WHERE tenant_id=? AND id=? FOR UPDATE",
                  f.tenant(),
                  f.binding());
              return context;
            });
    when(publications.requireTarget(
            eq(f.tenant()), eq(f.actor()), anyString(), eq(f.device()), eq(f.registration())))
        .thenAnswer(
            call ->
                new ManagedExecutionPublicationAccess.Publication(
                    db.queryForObject(
                        "SELECT version_id FROM policy_publications WHERE tenant_id=? AND id=?",
                        String.class,
                        f.tenant(),
                        call.getArgument(2)),
                    "c".repeat(64),
                    1));
    audit = spy(new AuditService(db, Clock.systemUTC()));
    journal =
        new ManagedPolicyExecutionJournal(
            db,
            bindings,
            publications,
            new TenantAccess(db),
            audit,
            new ManagedPolicyExecutionSettings(30, 24, 1),
            data.transactions);
    deadline = System.currentTimeMillis() + 600_000L;
  }

  @AfterEach
  void close() {
    data.close();
  }

  @Test
  void freshBaselineIncludesDurableExecutionJournal() {
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND"
                    + " table_name='managed_policy_execution_tasks'",
                Long.class))
        .as("fresh baseline must include durable execution tasks")
        .isEqualTo(1);
  }

  @Test
  void completeCompilerDocumentSurvivesDurableAdmissionAndClaim() {
    var compiler = new GoogleCompletePolicyCompiler("com.aimanager.child", Set.of());
    var compiled =
        compiler.compile(
            30,
            "DEVICE_OWNER",
            List.of(
                new ManagedAndroidGateway.AppRestriction(
                    "com.example.lesson", ManagedAndroidGateway.AppControl.BLOCK_LAUNCH)),
            List.of(
                new GoogleCompletePolicyCompiler.AppPermissions(
                    "com.example.lesson",
                    List.of(
                        new ManagedAndroidGateway.RuntimePermissionDecision(
                            "android.permission.CAMERA",
                            ManagedAndroidGateway.PermissionDecision.DENY)))));
    var task =
        journal.enqueue(
            f.tenant(),
            f.actor(),
            f.publication(),
            f.binding(),
            2,
            compiled.documentJson(),
            deadline);
    var claim = claim();
    assertThat(claim.taskId()).isEqualTo(task.id());
    assertThat(claim.documentJson()).isEqualTo(compiled.documentJson());
    assertThat(claim.documentSha256()).isEqualTo(compiled.sha256());
    assertThat(
            compiler
                .restore(claim.documentJson(), claim.documentSha256(), 30, "DEVICE_OWNER")
                .requestBody())
        .isEqualTo(compiled.requestBody());
  }

  @Test
  void admissionIsImmutableAndIdempotent() {
    var task = enqueue();
    String equivalent =
        "{\"policy\":{\"applications\":[]},\"adapterRevision\":\"local-v1\",\"schemaVersion\":1}";
    assertThat(
            journal.enqueue(
                f.tenant(), f.actor(), f.publication(), f.binding(), 2, equivalent, deadline))
        .isEqualTo(task);
    assertThat(count("managed_policy_execution_tasks")).isEqualTo(1);
    assertThat(count("managed_policy_execution_events")).isEqualTo(1);
    assertThatThrownBy(
            () ->
                journal.enqueue(
                    f.tenant(),
                    f.actor(),
                    f.publication(),
                    f.binding(),
                    2,
                    DOCUMENT.replace("local-v1", "local-v2"),
                    deadline))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(
            () ->
                journal.enqueue(
                    f.tenant(), f.actor(), f.publication(), f.binding(), 2, DOCUMENT, deadline + 1))
        .isInstanceOf(DomainException.class);
    assertThat(count("managed_policy_execution_events")).isEqualTo(1);
  }

  @Test
  void anotherPublicationCannotOccupyAnUnresolvedDevice() {
    enqueue();
    var other = data.publication(f, "ENFORCE");
    assertThatThrownBy(
            () ->
                journal.enqueue(
                    f.tenant(), f.actor(), other.publication(), f.binding(), 2, DOCUMENT, deadline))
        .isInstanceOf(DomainException.class)
        .hasMessageContaining("EXECUTION_DEVICE_BUSY");
    assertThat(count("managed_policy_execution_tasks")).isEqualTo(1);
  }

  @Test
  void parallelClaimersCannotOwnTheSameTask() throws Exception {
    enqueue();
    var pool = Executors.newFixedThreadPool(2);
    var start = new CountDownLatch(1);
    try {
      Callable<List<ManagedPolicyExecutionJournal.Claim>> operation =
          () -> {
            start.await();
            return journal.claimDue("LOCAL_TEST", 25);
          };
      var left = pool.submit(operation);
      var right = pool.submit(operation);
      start.countDown();
      assertThat(left.get(10, TimeUnit.SECONDS).size() + right.get(10, TimeUnit.SECONDS).size())
          .isEqualTo(1);
    } finally {
      pool.shutdownNow();
      assertThat(pool.awaitTermination(10, TimeUnit.SECONDS)).isTrue();
    }
    assertThat(count("managed_policy_execution_events")).isEqualTo(2);
  }

  @Test
  void concurrentAdmissionsProduceOneImmutableTask() throws Exception {
    var pool = Executors.newFixedThreadPool(2);
    var start = new CountDownLatch(1);
    try {
      Callable<ManagedPolicyExecutionJournal.View> operation =
          () -> {
            start.await();
            return enqueue();
          };
      var left = pool.submit(operation);
      var right = pool.submit(operation);
      start.countDown();
      assertThat(left.get(10, TimeUnit.SECONDS)).isEqualTo(right.get(10, TimeUnit.SECONDS));
    } finally {
      pool.shutdownNow();
      assertThat(pool.awaitTermination(10, TimeUnit.SECONDS)).isTrue();
    }
    assertThat(count("managed_policy_execution_tasks")).isEqualTo(1);
    assertThat(count("managed_policy_execution_events")).isEqualTo(1);
  }

  @Test
  void competingPublicationsCannotBothOccupyTheDevice() throws Exception {
    var other = data.publication(f, "ENFORCE");
    var pool = Executors.newFixedThreadPool(2);
    var start = new CountDownLatch(1);
    try {
      var operations = new java.util.ArrayList<Future<String>>();
      for (String publication : List.of(f.publication(), other.publication()))
        operations.add(
            pool.submit(
                () -> {
                  start.await();
                  try {
                    journal.enqueue(
                        f.tenant(), f.actor(), publication, f.binding(), 2, DOCUMENT, deadline);
                    return "ADMITTED";
                  } catch (DomainException rejected) {
                    return rejected.getMessage();
                  }
                }));
      start.countDown();
      assertThat(
              List.of(
                  operations.get(0).get(10, TimeUnit.SECONDS),
                  operations.get(1).get(10, TimeUnit.SECONDS)))
          .containsExactlyInAnyOrder("ADMITTED", "EXECUTION_DEVICE_BUSY");
    } finally {
      pool.shutdownNow();
      assertThat(pool.awaitTermination(10, TimeUnit.SECONDS)).isTrue();
    }
    assertThat(count("managed_policy_execution_tasks")).isEqualTo(1);
    assertThat(count("managed_policy_execution_events")).isEqualTo(1);
  }

  @Test
  void historyLimitRefusesThe101stTaskWithoutDeletingPriorEvidence() {
    for (int i = 0; i < 100; i++) {
      var source = i == 0 ? f : data.publication(f, "ENFORCE");
      var task =
          journal.enqueue(
              f.tenant(), f.actor(), source.publication(), f.binding(), 2, DOCUMENT, deadline);
      journal.cancel(f.tenant(), f.actor(), task.id());
    }
    var source = data.publication(f, "ENFORCE");
    assertThatThrownBy(
            () ->
                journal.enqueue(
                    f.tenant(),
                    f.actor(),
                    source.publication(),
                    f.binding(),
                    2,
                    DOCUMENT,
                    deadline))
        .isInstanceOf(DomainException.class)
        .hasMessageContaining("EXECUTION_BINDING_HISTORY_LIMIT");
    assertThat(count("managed_policy_execution_tasks")).isEqualTo(100);
    assertThat(count("managed_policy_execution_events")).isEqualTo(200);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "active_device_id=NULL",
        "state='READY_TO_ASSIGN',provider_version=NULL",
        "lease_token='token'",
        "lease_until=100",
        "action='READ_DEVICE'",
        "lease_token='token',lease_until=100,action=NULL"
      })
  void databaseRejectsPartialLeaseMissingSlotAndRequiredVersion(String assignment) {
    var task = enqueue();
    assertThatThrownBy(
            () ->
                db.update(
                    "UPDATE managed_policy_execution_tasks SET " + assignment + " WHERE id=?",
                    task.id()))
        .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    assertThat(view(task)).isEqualTo(task);
  }

  @ParameterizedTest
  @ValueSource(strings = {"authority", "enrollment", "trust"})
  void changedReturnedContextPreventsDispatch(String changed) {
    var task = enqueue();
    var lease = claim();
    var c = context;
    context =
        new ManagedAgentBindingStore.VerifiedBindingContext(
            c.tenantId(),
            c.actorId(),
            changed.equals("authority") ? c.authorityVersion() + 1 : c.authorityVersion(),
            c.subjectId(),
            c.deviceId(),
            c.registrationId(),
            c.keyThumbprint(),
            c.bindingId(),
            c.bindingVersion(),
            c.enrollmentId(),
            changed.equals("enrollment") ? c.enrollmentVersion() + 1 : c.enrollmentVersion(),
            c.provider(),
            c.enterpriseId(),
            c.enterpriseBindingVersion(),
            c.providerDeviceId(),
            c.managementMode(),
            c.bindingVerifiedAt(),
            c.agentPackageName(),
            changed.equals("trust") ? "d".repeat(64) : c.agentTrustRevision(),
            c.platform(),
            c.registeredAt());
    assertThatThrownBy(() -> journal.beforeWrite(lease))
        .isInstanceOf(DomainException.class)
        .hasMessageContaining("EXECUTION_CONTEXT_CHANGED");
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
    assertThat(journal.failed(lease)).isTrue();
  }

  @ParameterizedTest
  @ValueSource(booleans = {false, true})
  void cancellationAfterAssignmentRejectsLateDeviceAndAssignmentEvidence(boolean accepted) {
    var task = enqueue();
    var write = claim();
    journal.beforeWrite(write);
    journal.policyWritten(write, receipt(write));
    var assignment = claim();
    journal.beforeWrite(assignment);
    ManagedPolicyExecutionJournal.Claim read;
    if (accepted) {
      journal.assignmentAccepted(
          assignment,
          new ManagedAndroidGateway.AssignmentReceipt(device(assignment), policy(assignment)));
      read = claim();
    } else {
      expire(assignment);
      read = claim();
    }
    journal.cancel(f.tenant(), f.actor(), task.id());
    assertThat(
            journal.assignmentAccepted(
                assignment,
                new ManagedAndroidGateway.AssignmentReceipt(
                    device(assignment), policy(assignment))))
        .isFalse();
    assertThat(journal.deviceObserved(read, applied(read, 7L))).isFalse();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
    assertThat(
            db.queryForObject(
                "SELECT active_device_id FROM managed_policy_execution_tasks WHERE id=?",
                String.class,
                task.id()))
        .isEqualTo(f.device());
  }

  @Test
  void publicationAndAdmissionRollBackInOneReadCommittedTransaction() {
    long before = count("policy_publications");
    var outer = new TransactionTemplate(data.transactions);
    outer.setIsolationLevel(
        org.springframework.transaction.TransactionDefinition.ISOLATION_READ_COMMITTED);
    assertThatThrownBy(
            () ->
                outer.execute(
                    status -> {
                      var source = data.publication(f, "ENFORCE");
                      journal.enqueue(
                          f.tenant(),
                          f.actor(),
                          source.publication(),
                          f.binding(),
                          2,
                          DOCUMENT,
                          deadline);
                      throw new IllegalStateException("fixture publication rollback");
                    }))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("fixture publication rollback");
    assertThat(count("policy_publications")).isEqualTo(before);
    assertThat(count("managed_policy_execution_tasks")).isZero();
    assertThat(count("managed_policy_execution_events")).isZero();
  }

  @Test
  void restartAfterWriteIntentCanOnlyReadAndLateSuccessCannotWin() {
    var task = enqueue();
    var original = claim();
    assertThat(journal.beforeWrite(original)).isTrue();
    assertThat(journal.beforeWrite(original)).isFalse();
    expire(original);
    var replacement = claim();
    assertThat(replacement.action()).isEqualTo(ManagedPolicyExecutionJournal.Action.READ_POLICY);
    assertThat(replacement.generation()).isGreaterThan(original.generation());
    assertThat(journal.policyWritten(original, receipt(original))).isFalse();
    assertThat(
            journal.policyObserved(
                replacement,
                new ManagedAndroidGateway.ApplicationPolicyInspection(
                    policy(replacement), 7L, ManagedAndroidGateway.ApplicationPolicyState.MATCHED)))
        .isTrue();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
    assertThat(journal.claimDue("LOCAL_TEST", 25)).isEmpty();
  }

  @ParameterizedTest
  @EnumSource(ManagedAndroidGateway.CompletePolicyState.class)
  void completeObservationRequiresReviewWithoutInventingAWriteReceipt(
      ManagedAndroidGateway.CompletePolicyState state) {
    var task = enqueue();
    var read = uncertainPolicyRead();
    var before = view(task);
    long events = count("managed_policy_execution_events");
    Long version = state == ManagedAndroidGateway.CompletePolicyState.NOT_FOUND ? null : 7L;

    assertThat(journal.completePolicyObserved(read, completeObservation(read, state, version)))
        .as("complete policy observation must join durable recovery")
        .isTrue();

    var after = view(task);
    assertThat(after.state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
    assertThat(after.reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.RECONCILIATION_REQUIRES_REVIEW);
    assertThat(after.revision()).isEqualTo(before.revision() + 1);
    assertThat(count("managed_policy_execution_events")).isEqualTo(events + 1);
    var row =
        db.queryForMap(
            "SELECT provider_version,active_device_id,lease_token,lease_until,action"
                + " FROM managed_policy_execution_tasks WHERE id=?",
            task.id());
    assertThat(row.get("provider_version")).isNull();
    assertThat(row.get("active_device_id")).isEqualTo(f.device());
    assertThat(row.get("lease_token")).isNull();
    assertThat(row.get("lease_until")).isNull();
    assertThat(row.get("action")).isNull();
    assertThat(journal.claimDue("LOCAL_TEST", 25)).isEmpty();

    assertThat(journal.completePolicyObserved(read, completeObservation(read, state, version)))
        .isFalse();
    assertThat(view(task)).isEqualTo(after);
    assertThat(count("managed_policy_execution_events")).isEqualTo(events + 1);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "null",
        "state",
        "enterprise",
        "policy",
        "missingVersion",
        "zeroVersion",
        "negativeVersion",
        "notFoundVersion",
        "mismatchMissingVersion",
        "versionMismatchMissingVersion"
      })
  void malformedCompleteObservationRollsBackWithoutChangingLease(String scenario) {
    var task = enqueue();
    var read = uncertainPolicyRead();
    var before =
        db.queryForMap("SELECT * FROM managed_policy_execution_tasks WHERE id=?", task.id());
    long events = count("managed_policy_execution_events");
    var matched = ManagedAndroidGateway.CompletePolicyState.MATCHED;
    var observation =
        switch (scenario) {
          case "null" -> null;
          case "state" -> completeObservation(read, null, 7L);
          case "enterprise" ->
              new ManagedAndroidGateway.CompletePolicyInspection(
                  "enterprises/other/policies/" + read.policyId(), 7L, matched);
          case "policy" ->
              new ManagedAndroidGateway.CompletePolicyInspection(
                  "enterprises/" + read.enterpriseId() + "/policies/other", 7L, matched);
          case "missingVersion" -> completeObservation(read, matched, null);
          case "zeroVersion" -> completeObservation(read, matched, 0L);
          case "negativeVersion" -> completeObservation(read, matched, -1L);
          case "notFoundVersion" ->
              completeObservation(read, ManagedAndroidGateway.CompletePolicyState.NOT_FOUND, 7L);
          case "mismatchMissingVersion" ->
              completeObservation(
                  read, ManagedAndroidGateway.CompletePolicyState.CONTENT_MISMATCH, null);
          case "versionMismatchMissingVersion" ->
              completeObservation(
                  read, ManagedAndroidGateway.CompletePolicyState.VERSION_MISMATCH, null);
          default -> throw new AssertionError("Unknown test case");
        };
    assertThatThrownBy(() -> journal.completePolicyObserved(read, observation))
        .isInstanceOf(IllegalArgumentException.class);
    assertThat(db.queryForMap("SELECT * FROM managed_policy_execution_tasks WHERE id=?", task.id()))
        .isEqualTo(before);
    assertThat(count("managed_policy_execution_events")).isEqualTo(events);
  }

  @Test
  void supersededCompleteObservationCannotOverrideCurrentLease() {
    var task = enqueue();
    var old = uncertainPolicyRead();
    expire(old);
    var current = claim();
    var before = view(task);
    long events = count("managed_policy_execution_events");
    assertThat(
            journal.completePolicyObserved(
                old,
                completeObservation(old, ManagedAndroidGateway.CompletePolicyState.MATCHED, 7L)))
        .isFalse();
    assertThat(view(task)).isEqualTo(before);
    assertThat(count("managed_policy_execution_events")).isEqualTo(events);
    assertThat(
            journal.completePolicyObserved(
                current,
                completeObservation(
                    current, ManagedAndroidGateway.CompletePolicyState.MATCHED, 7L)))
        .isTrue();
  }

  @Test
  void expiredCompleteObservationCannotChangeTheTask() {
    var task = enqueue();
    var read = uncertainPolicyRead();
    expire(read);
    var before = view(task);
    long events = count("managed_policy_execution_events");
    assertThat(
            journal.completePolicyObserved(
                read,
                completeObservation(read, ManagedAndroidGateway.CompletePolicyState.MATCHED, 7L)))
        .isFalse();
    assertThat(view(task)).isEqualTo(before);
    assertThat(count("managed_policy_execution_events")).isEqualTo(events);
  }

  @Test
  void writeClaimCannotSubmitCompleteObservation() {
    var task = enqueue();
    var write = claim();
    assertThat(journal.beforeWrite(write)).isTrue();
    var before = view(task);
    long events = count("managed_policy_execution_events");
    assertThat(
            journal.completePolicyObserved(
                write,
                completeObservation(write, ManagedAndroidGateway.CompletePolicyState.MATCHED, 7L)))
        .isFalse();
    assertThat(view(task)).isEqualTo(before);
    assertThat(count("managed_policy_execution_events")).isEqualTo(events);
  }

  @Test
  void completeObservationCannotOverrideCancellation() {
    var task = enqueue();
    var read = uncertainPolicyRead();
    journal.cancel(f.tenant(), f.actor(), task.id());
    var cancelled = view(task);
    long events = count("managed_policy_execution_events");
    assertThat(
            journal.completePolicyObserved(
                read,
                completeObservation(read, ManagedAndroidGateway.CompletePolicyState.MATCHED, 7L)))
        .isFalse();
    assertThat(view(task)).isEqualTo(cancelled);
    assertThat(count("managed_policy_execution_events")).isEqualTo(events);
  }

  @Test
  void completeObservationRejectsOuterTransaction() {
    enqueue();
    var read = uncertainPolicyRead();
    var outer = new TransactionTemplate(data.transactions);
    assertThatThrownBy(
            () ->
                outer.execute(
                    status ->
                        journal.completePolicyObserved(
                            read,
                            completeObservation(
                                read, ManagedAndroidGateway.CompletePolicyState.MATCHED, 7L))))
        .isInstanceOf(IllegalStateException.class);
  }

  @Test
  void completeObservationCannotSelectAnotherTenantsTask() {
    var task = enqueue();
    var read = uncertainPolicyRead();
    var foreign = data.fixture();
    var forged =
        new ManagedPolicyExecutionJournal.Claim(
            foreign.tenant(),
            read.taskId(),
            read.token(),
            read.generation(),
            read.action(),
            read.leaseUntil(),
            read.enterpriseId(),
            read.deviceId(),
            read.policyId(),
            read.policyVersion(),
            read.documentJson(),
            read.documentSha256());
    var before = view(task);
    long events = count("managed_policy_execution_events");
    assertThatThrownBy(
            () ->
                journal.completePolicyObserved(
                    forged,
                    completeObservation(
                        read, ManagedAndroidGateway.CompletePolicyState.MATCHED, 7L)))
        .isInstanceOf(DomainException.class);
    assertThat(view(task)).isEqualTo(before);
    assertThat(count("managed_policy_execution_events")).isEqualTo(events);
  }

  private ManagedPolicyExecutionJournal.Claim uncertainPolicyRead() {
    var write = claim();
    assertThat(journal.beforeWrite(write)).isTrue();
    expire(write);
    var read = claim();
    assertThat(read.action()).isEqualTo(ManagedPolicyExecutionJournal.Action.READ_POLICY);
    return read;
  }

  /**
   * Real generated SDK and loopback HTTP; provider ownership and authority remain local fixtures.
   */
  @ParameterizedTest
  @ValueSource(booleans = {false, true})
  void lostCompleteWriteResponseIsReadBackWithoutRepeatingOrAssigning(boolean changePermission)
      throws Exception {
    var compiler = new GoogleCompletePolicyCompiler("com.aimanager.child", Set.of());
    var compiled =
        compiler.compile(
            30,
            "DEVICE_OWNER",
            List.of(
                new ManagedAndroidGateway.AppRestriction(
                    "com.example.lesson", ManagedAndroidGateway.AppControl.BLOCK_LAUNCH)),
            List.of(
                new GoogleCompletePolicyCompiler.AppPermissions(
                    "com.example.lesson",
                    List.of(
                        new ManagedAndroidGateway.RuntimePermissionDecision(
                            "android.permission.CAMERA",
                            ManagedAndroidGateway.PermissionDecision.DENY)))));
    var task =
        journal.enqueue(
            f.tenant(),
            f.actor(),
            f.publication(),
            f.binding(),
            2,
            compiled.documentJson(),
            deadline);
    var write = claim();
    var json = new ObjectMapper();
    var expectedBody = json.readTree(compiled.documentJson()).path("policy");
    var saved = new AtomicReference<ObjectNode>();
    var writes = new AtomicInteger();
    var reads = new AtomicInteger();
    var unexpected = new AtomicInteger();
    var writeMethod = new AtomicReference<String>();
    var writeOverride = new AtomicReference<String>();
    var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext(
        "/",
        exchange -> {
          try {
            int status;
            String body;
            if (!exchange.getRequestURI().getPath().equals("/v1/" + policy(write))) {
              unexpected.incrementAndGet();
              status = 400;
              body = "{}";
            } else if ("GET".equals(exchange.getRequestMethod())) {
              reads.incrementAndGet();
              status = saved.get() == null ? 404 : 200;
              body = saved.get() == null ? "{}" : json.writeValueAsString(saved.get());
            } else if ("PATCH".equals(exchange.getRequestMethod())
                || ("POST".equals(exchange.getRequestMethod())
                    && "PATCH"
                        .equals(exchange.getRequestHeaders().getFirst(MethodOverride.HEADER)))) {
              writes.incrementAndGet();
              // NetHttpTransport tunnels unsupported PATCH through the SDK's method override.
              writeMethod.set(exchange.getRequestMethod());
              writeOverride.set(exchange.getRequestHeaders().getFirst(MethodOverride.HEADER));
              var input = exchange.getRequestBody();
              if ("gzip"
                  .equalsIgnoreCase(exchange.getRequestHeaders().getFirst("Content-Encoding")))
                input = new GZIPInputStream(input);
              var received = (ObjectNode) json.readTree(input);
              if (!expectedBody.equals(received)) unexpected.incrementAndGet();
              received.put("name", policy(write)).put("version", "7");
              if (changePermission) {
                for (var application : received.path("applications")) {
                  if ("com.example.lesson".equals(application.path("packageName").asText())) {
                    ((ObjectNode) application.path("permissionGrants").get(0))
                        .put("policy", "PROMPT");
                  }
                }
              }
              saved.set(received);
              // The simulated provider persisted the write but did not return a success receipt.
              status = 503;
              body = "{}";
            } else {
              unexpected.incrementAndGet();
              status = 405;
              body = "{}";
            }
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            exchange.getResponseBody().write(bytes);
          } finally {
            exchange.close();
          }
        });
    server.start();
    try {
      var client =
          new AndroidManagement.Builder(
                  new NetHttpTransport(), GsonFactory.getDefaultInstance(), null)
              .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
              .setApplicationName("complete-recovery-local-contract")
              .build();
      var gateway = new GoogleManagedAndroidGateway(client);
      var document =
          new ManagedAndroidGateway.PolicyDocument(
              write.documentJson(),
              write.documentSha256(),
              "com.aimanager.child",
              30,
              "DEVICE_OWNER");
      assertThat(journal.beforeWrite(write)).isTrue();
      assertThatThrownBy(
              () -> gateway.writePolicyCandidate(write.enterpriseId(), write.policyId(), document))
          .isInstanceOfSatisfying(
              ManagedPolicyWriteException.class,
              failure -> assertThat(failure.outcome()).isEqualTo(Outcome.OUTCOME_UNKNOWN));
      assertThat(writes.get()).as("simulated provider persisted exactly one write").isEqualTo(1);
      assertThat(saved.get()).as("simulated provider saved the complete policy").isNotNull();
      assertThat(unexpected.get()).as("SDK request matches the local provider contract").isZero();
      assertThat(writeMethod.get()).isEqualTo("POST");
      assertThat(writeOverride.get()).isEqualTo("PATCH");
      assertThat(journal.failed(write)).isTrue();
      due(task.id());
      var read = claim();
      assertThat(read.action()).isEqualTo(ManagedPolicyExecutionJournal.Action.READ_POLICY);
      var observation =
          gateway.inspectCompletePolicy(
              read.enterpriseId(), read.policyId(), document, read.policyVersion());
      assertThat(observation.state())
          .isEqualTo(
              changePermission
                  ? ManagedAndroidGateway.CompletePolicyState.CONTENT_MISMATCH
                  : ManagedAndroidGateway.CompletePolicyState.MATCHED);
      assertThat(journal.completePolicyObserved(read, observation)).isTrue();
      assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
      assertThat(journal.claimDue("LOCAL_TEST", 25)).isEmpty();
      assertThat(writes.get()).isEqualTo(1);
      assertThat(reads.get()).isEqualTo(2);
      assertThat(unexpected.get()).isZero();
    } finally {
      server.stop(0);
    }
  }

  private ManagedAndroidGateway.CompletePolicyInspection completeObservation(
      ManagedPolicyExecutionJournal.Claim claim,
      ManagedAndroidGateway.CompletePolicyState state,
      Long version) {
    return new ManagedAndroidGateway.CompletePolicyInspection(policy(claim), version, state);
  }

  @Test
  void crashBeforeDispatchCanBeClaimedWithoutInventingAnExternalWrite() {
    enqueue();
    var old = claim();
    expire(old);
    var current = claim();
    assertThat(current.action()).isEqualTo(ManagedPolicyExecutionJournal.Action.WRITE_POLICY);
    assertThat(journal.beforeWrite(old)).isFalse();
    assertThat(journal.beforeWrite(current)).isTrue();
  }

  @Test
  void normalLifecycleRequiresPolicyAssignmentAndIndependentDeviceEvidence() {
    var task = enqueue();
    var write = claim();
    assertThat(journal.policyWritten(write, receipt(write))).isFalse();
    assertThat(journal.beforeWrite(write)).isTrue();
    assertThat(journal.policyWritten(write, receipt(write))).isTrue();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_ASSIGN);
    var assign = claim();
    assertThat(assign.action()).isEqualTo(ManagedPolicyExecutionJournal.Action.ASSIGN_POLICY);
    assertThat(journal.beforeWrite(assign)).isTrue();
    assertThat(
            journal.assignmentAccepted(
                assign,
                new ManagedAndroidGateway.AssignmentReceipt(device(assign), policy(assign))))
        .isTrue();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
    var poll = claim();
    assertThat(journal.deviceObserved(poll, applied(poll, 7L))).isTrue();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.APPLIED);
    assertThat(
            db.queryForObject(
                "SELECT active_device_id FROM managed_policy_execution_tasks WHERE id=?",
                String.class,
                task.id()))
        .isNull();
    assertThatThrownBy(() -> journal.cancel(f.tenant(), f.actor(), task.id()))
        .isInstanceOf(DomainException.class)
        .hasMessageContaining("EXECUTION_ALREADY_APPLIED_USE_NEW_POLICY");
  }

  @ParameterizedTest
  @ValueSource(longs = {6, 8})
  void anotherAppliedVersionDoesNotProveThisTask(long appliedVersion) {
    var task = enqueue();
    var poll = waiting();
    assertThat(journal.deviceObserved(poll, applied(poll, appliedVersion))).isTrue();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
  }

  @Test
  void noncomplianceAndMissingOwnerEvidenceNeverBecomeApplied() {
    var task = enqueue();
    var poll = waiting();
    assertThat(
            journal.deviceObserved(
                poll,
                new ManagedAndroidGateway.ManagedDeviceState(
                    device(poll),
                    "DEVICE_OWNER",
                    policy(poll),
                    policy(poll),
                    7L,
                    ManagedAndroidGateway.ApplyState.NON_COMPLIANT,
                    List.of("APP_NOT_INSTALLED"),
                    null)))
        .isTrue();
    assertThat(view(task).reason())
        .isEqualTo(ManagedPolicyExecutionJournal.Reason.DEVICE_NON_COMPLIANT);
    due(task.id());
    poll = claim();
    assertThat(
            journal.deviceObserved(
                poll,
                new ManagedAndroidGateway.ManagedDeviceState(
                    device(poll),
                    null,
                    policy(poll),
                    policy(poll),
                    7L,
                    ManagedAndroidGateway.ApplyState.APPLIED,
                    List.of(),
                    null)))
        .isTrue();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
  }

  @Test
  void uncertainAssignmentIsReadWithoutSendingAgain() {
    var task = enqueue();
    var write = claim();
    journal.beforeWrite(write);
    journal.policyWritten(write, receipt(write));
    var assign = claim();
    journal.beforeWrite(assign);
    expire(assign);
    var poll = claim();
    assertThat(poll.action()).isEqualTo(ManagedPolicyExecutionJournal.Action.READ_DEVICE);
    assertThat(
            journal.assignmentAccepted(
                assign,
                new ManagedAndroidGateway.AssignmentReceipt(device(assign), policy(assign))))
        .isFalse();
    journal.deviceObserved(
        poll,
        new ManagedAndroidGateway.ManagedDeviceState(
            device(poll),
            "DEVICE_OWNER",
            "other",
            null,
            null,
            ManagedAndroidGateway.ApplyState.PENDING,
            List.of(),
            null));
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
  }

  @Test
  void cancellationBeforeWritePreventsDispatchAndReleasesSlot() {
    var task = enqueue();
    var claim = claim();
    var cancelled = journal.cancel(f.tenant(), f.actor(), task.id());
    assertThat(cancelled.state()).isEqualTo(ManagedPolicyExecutionJournal.State.CANCELLED);
    assertThat(journal.beforeWrite(claim)).isFalse();
    assertThat(journal.cancel(f.tenant(), f.actor(), task.id())).isEqualTo(cancelled);
    var other = data.publication(f, "ENFORCE");
    assertThat(
            journal
                .enqueue(
                    f.tenant(), f.actor(), other.publication(), f.binding(), 2, DOCUMENT, deadline)
                .state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
  }

  @Test
  void cancellationAfterDispatchIsNotReportedAsRestoration() {
    var task = enqueue();
    var write = claim();
    journal.beforeWrite(write);
    assertThat(journal.cancel(f.tenant(), f.actor(), task.id()).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
    assertThat(journal.policyWritten(write, receipt(write))).isFalse();
    assertThat(
            db.queryForObject(
                "SELECT active_device_id FROM managed_policy_execution_tasks WHERE id=?",
                String.class,
                task.id()))
        .isEqualTo(f.device());
  }

  @Test
  void changedAuthorityContextPreventsNetworkIntent() {
    var task = enqueue();
    var claim = claim();
    when(bindings.requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2))
        .thenThrow(DomainException.denied());
    assertThatThrownBy(() -> journal.beforeWrite(claim)).isInstanceOf(DomainException.class);
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
    assertThat(journal.failed(claim)).isTrue();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.CANCELLED);
  }

  @Test
  void retriesPreserveUnknownWriteAndUseBoundedBackoff() {
    var task = enqueue();
    var write = claim();
    journal.beforeWrite(write);
    journal.failed(write);
    assertThat(view(task).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.POLICY_WRITE_UNKNOWN);
    assertThat(journal.claimDue("LOCAL_TEST", 25)).isEmpty();
    due(task.id());
    var poll = claim();
    assertThat(poll.action()).isEqualTo(ManagedPolicyExecutionJournal.Action.READ_POLICY);
    journal.failed(poll);
    assertThat(view(task).reason()).isEqualTo(ManagedPolicyExecutionJournal.Reason.READ_FAILED);
    db.update(
        "UPDATE managed_policy_execution_tasks SET attempts=24,next_attempt_at=created_at WHERE"
            + " id=?",
        task.id());
    assertThat(journal.claimDue("LOCAL_TEST", 25)).isEmpty();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
  }

  @Test
  void untouchedDeadlineCanCancelButUnknownWriteDeadlineKeepsReviewSlot() {
    var task = enqueue();
    deadlinePassed(task.id());
    assertThat(journal.claimDue("LOCAL_TEST", 25)).isEmpty();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.CANCELLED);
    var next = data.publication(f, "ENFORCE");
    task =
        journal.enqueue(
            f.tenant(), f.actor(), next.publication(), f.binding(), 2, DOCUMENT, deadline);
    var write = claim();
    journal.beforeWrite(write);
    deadlinePassed(task.id());
    assertThat(journal.claimDue("LOCAL_TEST", 25)).isEmpty();
    assertThat(view(task).state()).isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
  }

  @Test
  void auditFailureRollsBackTaskAndHistory() {
    doThrow(new IllegalStateException("fixture audit unavailable"))
        .when(audit)
        .record(anyString(), anyString(), anyString(), anyString());
    assertThatThrownBy(this::enqueue).isInstanceOf(IllegalStateException.class);
    assertThat(count("managed_policy_execution_tasks")).isZero();
    assertThat(count("managed_policy_execution_events")).isZero();
  }

  @Test
  void authorityAndTenantIsolationProtectReadAndCancellation() {
    var task = enqueue();
    var foreign = data.fixture();
    assertThatThrownBy(() -> journal.get(foreign.tenant(), foreign.actor(), task.id()))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(() -> journal.cancel(f.tenant(), foreign.actor(), task.id()))
        .isInstanceOf(DomainException.class);
    db.update("UPDATE tenant_members SET role='CHILD' WHERE tenant_id=?", f.tenant());
    assertThatThrownBy(() -> journal.get(f.tenant(), f.actor(), task.id()))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(() -> journal.cancel(f.tenant(), f.actor(), task.id()))
        .isInstanceOf(DomainException.class);
  }

  @Test
  void workerCheckpointCannotShareAnOuterTransaction() {
    var outer = new TransactionTemplate(data.transactions);
    assertThatThrownBy(() -> outer.execute(s -> journal.claimDue("LOCAL_TEST", 1)))
        .isInstanceOf(IllegalStateException.class);
  }

  @ParameterizedTest
  @ValueSource(strings = {"null", "[]", "{}", "{\"schemaVersion\":1,\"schemaVersion\":1}", "{} {}"})
  void invalidDocumentNeverCreatesTasks(String input) {
    assertThatThrownBy(
            () ->
                journal.enqueue(
                    f.tenant(), f.actor(), f.publication(), f.binding(), 2, input, deadline))
        .isInstanceOf(DomainException.class);
    assertThat(count("managed_policy_execution_tasks")).isZero();
  }

  private ManagedPolicyExecutionJournal.View enqueue() {
    return journal.enqueue(
        f.tenant(), f.actor(), f.publication(), f.binding(), 2, DOCUMENT, deadline);
  }

  private ManagedPolicyExecutionJournal.Claim claim() {
    var claims = journal.claimDue("LOCAL_TEST", 25);
    assertThat(claims).hasSize(1);
    return claims.get(0);
  }

  private ManagedPolicyExecutionJournal.View view(ManagedPolicyExecutionJournal.View task) {
    return journal.get(f.tenant(), f.actor(), task.id());
  }

  private long count(String table) {
    return db.queryForObject("SELECT COUNT(*) FROM " + table, Long.class);
  }

  private void deadlinePassed(String id) {
    long now = System.currentTimeMillis();
    db.update(
        "UPDATE managed_policy_execution_tasks SET"
            + " created_at=?,expires_at=?,next_attempt_at=?,lease_until=CASE WHEN lease_token IS"
            + " NULL THEN NULL ELSE ? END WHERE id=?",
        now - 10_000,
        now - 1000,
        now - 10_000,
        now - 1000,
        id);
  }

  private void due(String id) {
    db.update(
        "UPDATE managed_policy_execution_tasks SET next_attempt_at=created_at WHERE id=?", id);
  }

  private void expire(ManagedPolicyExecutionJournal.Claim c) {
    db.update(
        "UPDATE managed_policy_execution_tasks SET"
            + " lease_until=created_at-1,next_attempt_at=created_at WHERE id=?",
        c.taskId());
  }

  private String policy(ManagedPolicyExecutionJournal.Claim c) {
    return "enterprises/" + c.enterpriseId() + "/policies/" + c.policyId();
  }

  private String device(ManagedPolicyExecutionJournal.Claim c) {
    return "enterprises/" + c.enterpriseId() + "/devices/" + c.deviceId();
  }

  private ManagedAndroidGateway.PolicyReceipt receipt(ManagedPolicyExecutionJournal.Claim c) {
    return new ManagedAndroidGateway.PolicyReceipt(policy(c), 7L);
  }

  private ManagedAndroidGateway.ManagedDeviceState applied(
      ManagedPolicyExecutionJournal.Claim c, Long version) {
    return new ManagedAndroidGateway.ManagedDeviceState(
        device(c),
        "DEVICE_OWNER",
        policy(c),
        policy(c),
        version,
        ManagedAndroidGateway.ApplyState.APPLIED,
        List.of(),
        null);
  }

  private ManagedPolicyExecutionJournal.Claim waiting() {
    var write = claim();
    journal.beforeWrite(write);
    journal.policyWritten(write, receipt(write));
    var assign = claim();
    journal.beforeWrite(assign);
    journal.assignmentAccepted(
        assign, new ManagedAndroidGateway.AssignmentReceipt(device(assign), policy(assign)));
    return claim();
  }
}
