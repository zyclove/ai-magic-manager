package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.managedandroid.ManagedPreparationRequested;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Real request SQL, authority locks, audit and outer rollback; lower EMM qualification is explicit.
 */
class ManagedPreparationAdmissionTest {
  ManagedPolicyExecutionJournalTest f;
  ManagedPreparationAdmission admission;
  ManagedAndroidGateway gateway;
  ManagedPolicyDocumentCompilers compilers;
  TransactionTemplate tx;
  final ObjectMapper json = new ObjectMapper();
  List<Object> events;
  List<ManagedExecutionPublicationAccess.Target> targets;
  Map<String, ManagedAgentBindingStore.VerifiedBindingContext> contexts;
  ApplicationEventPublisher publisher;

  @BeforeEach
  void setup() {
    f = new ManagedPolicyExecutionJournalTest();
    f.setup();
    tx = new TransactionTemplate(f.data.transactions);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    events = new ArrayList<>();
    publisher = events::add;
    targets =
        new ArrayList<>(
            List.of(
                new ManagedExecutionPublicationAccess.Target(f.f.device(), f.f.registration())));
    contexts = new HashMap<>(Map.of(f.f.binding(), f.context));
    doAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isTrue();
              String binding = call.getArgument(2);
              var context = contexts.get(binding);
              if (context == null
                  || !context.tenantId().equals(call.getArgument(0))
                  || !context.actorId().equals(call.getArgument(1))
                  || context.bindingVersion() != (long) call.getArgument(3))
                throw DomainException.denied();
              f.db.queryForList(
                  "SELECT id FROM managed_agent_bindings WHERE tenant_id=? AND id=? FOR UPDATE",
                  f.f.tenant(),
                  binding);
              return context;
            })
        .when(f.bindings)
        .requireVerifiedContext(anyString(), anyString(), anyString(), anyLong());
    doAnswer(
            call ->
                new ManagedExecutionPublicationAccess.Targets(
                    new ManagedExecutionPublicationAccess.Publication(
                        f.f.version(), "c".repeat(64), 1),
                    targets))
        .when(f.publications)
        .requireTargets(f.f.tenant(), f.f.actor(), f.f.publication());
    gateway = mock(ManagedAndroidGateway.class);
    when(gateway.providerCode()).thenReturn("LOCAL_TEST");
    when(gateway.available()).thenReturn(true);
    when(gateway.supportsExecutionProfiles()).thenReturn(true);
    when(gateway.supportsCompletePolicyDocuments()).thenReturn(true);
    when(gateway.supportsPolicyResourceAuthority()).thenReturn(true);
    when(gateway.policyResourceAuthorityRevision()).thenReturn("local-authority-v1");
    compilers = mock(ManagedPolicyDocumentCompilers.class);
    when(compilers.supports("LOCAL_TEST")).thenReturn(true);
    when(compilers.revision("LOCAL_TEST")).thenReturn("local-compiler-v1");
    admission = service(true);
  }

  @AfterEach
  void close() {
    f.close();
  }

  ManagedPreparationAdmission service(boolean enabled) {
    return new ManagedPreparationAdmission(
        f.db,
        f.bindings,
        f.publications,
        new TenantAccess(f.db),
        f.audit,
        publisher,
        gateway,
        compilers,
        json,
        enabled,
        900);
  }

  void invoke(String tenant, String actor, String publication) {
    try {
      admission.accept(tenant, actor, publication);
    } catch (UnsupportedOperationException missing) {
      if ("MANAGED_PREPARATION_ADMISSION_NOT_IMPLEMENTED".equals(missing.getMessage()))
        throw new AssertionError("MANAGED_PREPARATION_ADMISSION_NOT_IMPLEMENTED", missing);
      throw missing;
    }
  }

  void accept() {
    tx.executeWithoutResult(s -> invoke(f.f.tenant(), f.f.actor(), f.f.publication()));
  }

  @Test
  void persistsCompleteServerBoundRequestWithoutAnExecutionDocumentOrRemoteWrite()
      throws Exception {
    long before = now();
    accept();
    var row = rows().get(0);
    assertThat(rows()).hasSize(1);
    assertThat(row.get("publication_id")).isEqualTo(f.f.publication());
    assertThat(row.get("policy_version_id")).isEqualTo(f.f.version());
    assertThat(row.get("subject_id")).isEqualTo(f.f.subject());
    assertThat(row.get("device_id")).isEqualTo(f.f.device());
    assertThat(row.get("registration_id")).isEqualTo(f.f.registration());
    assertThat(row.get("binding_id")).isEqualTo(f.f.binding());
    assertThat(((Number) row.get("binding_version")).longValue()).isEqualTo(2);
    assertThat(row.get("actor_id")).isEqualTo(f.f.actor());
    assertThat(((Number) row.get("authority_version")).longValue()).isZero();
    assertThat(row.get("context_sha256"))
        .isEqualTo(SecretMaterial.hash(json.writeValueAsString(f.context)));
    assertThat(row.get("state")).isEqualTo("PENDING");
    assertThat(row.get("active_device_id")).isEqualTo(f.f.device());
    assertThat(row.get("execution_task_id")).isNull();
    assertThat(row.get("lease_token")).isNull();
    assertThat(row.get("lease_until")).isNull();
    long created = ((Number) row.get("created_at")).longValue();
    assertThat(created).isBetween(before, now());
    assertThat(((Number) row.get("expires_at")).longValue()).isEqualTo(created + 900_000L);
    assertThat(((Number) row.get("next_attempt_at")).longValue()).isEqualTo(created);
    assertThat(events)
        .containsExactly(new ManagedPreparationRequested(f.f.tenant(), (String) row.get("id")));
    assertThat(
            f.db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='PREPARATION_ACCEPTED'",
                Long.class,
                f.f.tenant()))
        .isEqualTo(1);
    assertThat(
            f.db.queryForObject("SELECT COUNT(*) FROM managed_policy_execution_tasks", Long.class))
        .isZero();
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
    verify(gateway, never()).readExecutionProfile(anyString(), anyString());
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void acceptsAllFrozenDevicesAndPublishesOnlyReferenceEvents() {
    secondDevice();
    accept();
    assertThat(rows()).hasSize(2);
    assertThat(events)
        .hasSize(2)
        .allSatisfy(e -> assertThat(e).isInstanceOf(ManagedPreparationRequested.class));
    assertThat(rows())
        .extracting(r -> r.get("device_id"))
        .containsExactlyInAnyOrderElementsOf(
            targets.stream().map(ManagedExecutionPublicationAccess.Target::deviceId).toList());
  }

  @Test
  void replayDoesNotExtendDeadlineOrDuplicateWakeups() {
    accept();
    var before = rows();
    accept();
    assertThat(rows()).isEqualTo(before);
    assertThat(events).hasSize(1);
  }

  @Test
  void outerFailureRollsBackRequestsAndAudit() {
    assertThatThrownBy(
            () ->
                tx.executeWithoutResult(
                    s -> {
                      invoke(f.f.tenant(), f.f.actor(), f.f.publication());
                      assertThat(rows()).hasSize(1);
                      throw new IllegalStateException("OUTER_ROLLBACK");
                    }))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("OUTER_ROLLBACK");
    assertThat(rows()).isEmpty();
    assertThat(audits()).isZero();
  }

  @Test
  void failureWhileRecordingSecondWakeupRollsBackTheEntireBatch() {
    secondDevice();
    publisher =
        event -> {
          events.add(event);
          if (events.size() == 2) throw new IllegalStateException("EVENT_REGISTRY_FAILED");
        };
    admission = service(true);
    assertThatThrownBy(this::accept)
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("EVENT_REGISTRY_FAILED");
    assertThat(rows()).isEmpty();
    assertThat(audits()).isZero();
  }

  @Test
  void auditFailureRollsBackIntake() {
    doThrow(new IllegalStateException("AUDIT_FAILED"))
        .when(f.audit)
        .record(anyString(), anyString(), eq("PREPARATION_ACCEPTED"), anyString());
    assertThatThrownBy(this::accept)
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("AUDIT_FAILED");
    assertThat(rows()).isEmpty();
  }

  @ParameterizedTest
  @ValueSource(strings = {"CHILD", "GUARDIAN", "AUDITOR", "TEACHER"})
  void deniesRolesWithoutManagedWriteAuthority(String role) {
    f.db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.f.tenant());
    assertThatThrownBy(this::accept).isInstanceOf(DomainException.class);
    assertThat(rows()).isEmpty();
    verifyNoInteractions(gateway);
  }

  @Test
  void revokedMembershipCannotCreateRequests() {
    f.db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.f.tenant());
    assertThatThrownBy(this::accept).isInstanceOf(DomainException.class);
    assertThat(rows()).isEmpty();
  }

  @Test
  void foreignTenantCannotSelectThesePublishedDevices() {
    var other = f.data.fixture();
    assertThatThrownBy(
            () ->
                tx.executeWithoutResult(
                    s -> invoke(other.tenant(), f.f.actor(), f.f.publication())))
        .isInstanceOf(DomainException.class);
    assertThat(rows()).isEmpty();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "DISABLED",
        "OFFLINE",
        "NO_PROFILE",
        "NO_DOCUMENTS",
        "NO_AUTHORITY",
        "NO_COMPILER",
        "NO_AUTHORITY_REVISION"
      })
  void incompleteConnectorCannotAdmitARequest(String missing) {
    switch (missing) {
      case "DISABLED" -> admission = service(false);
      case "OFFLINE" -> when(gateway.available()).thenReturn(false);
      case "NO_PROFILE" -> when(gateway.supportsExecutionProfiles()).thenReturn(false);
      case "NO_DOCUMENTS" -> when(gateway.supportsCompletePolicyDocuments()).thenReturn(false);
      case "NO_AUTHORITY" -> when(gateway.supportsPolicyResourceAuthority()).thenReturn(false);
      case "NO_COMPILER" -> when(compilers.supports("LOCAL_TEST")).thenReturn(false);
      case "NO_AUTHORITY_REVISION" ->
          when(gateway.policyResourceAuthorityRevision()).thenReturn(null);
      default -> throw new AssertionError(missing);
    }
    assertThatThrownBy(this::accept)
        .isInstanceOf(DomainException.class)
        .hasMessage("MANAGED_PREPARATION_ADMISSION_UNAVAILABLE");
    assertThat(rows()).isEmpty();
  }

  @Test
  void mandatoryTransactionAlsoAppliesToDirectCallers() {
    assertThatThrownBy(() -> invoke(f.f.tenant(), f.f.actor(), f.f.publication()))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Preparation admission requires READ_COMMITTED");
  }

  @Test
  void anotherIsolationLevelCannotBorrowThePublishBoundary() {
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
    assertThatThrownBy(this::accept)
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Preparation admission requires READ_COMMITTED");
  }

  @Test
  void missingBindingRejectsTheEntireTargetSet() {
    targets.add(
        new ManagedExecutionPublicationAccess.Target(
            ManagedExecutionTestData.id(), ManagedExecutionTestData.id()));
    assertThatThrownBy(this::accept).isInstanceOf(DomainException.class);
    assertThat(rows()).isEmpty();
    assertThat(audits()).isZero();
  }

  @Test
  void changedRegistrationCannotBorrowAnotherActiveBinding() {
    targets.set(
        0,
        new ManagedExecutionPublicationAccess.Target(f.f.device(), ManagedExecutionTestData.id()));
    assertThatThrownBy(this::accept).isInstanceOf(DomainException.class);
    assertThat(rows()).isEmpty();
  }

  @Test
  void anExistingExecutionBlocksPreparationIntake() {
    f.journal.enqueue(
        f.f.tenant(),
        f.f.actor(),
        f.f.publication(),
        f.f.binding(),
        2,
        ManagedPolicyExecutionJournalTest.DOCUMENT,
        f.deadline);
    assertThatThrownBy(this::accept)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_DEVICE_BUSY");
    assertThat(rows()).isEmpty();
  }

  @Test
  void pendingPreparationCannotBeBypassedThroughOldExecutionIntake() {
    accept();
    assertThatThrownBy(
            () ->
                f.journal.enqueue(
                    f.f.tenant(),
                    f.f.actor(),
                    f.f.publication(),
                    f.f.binding(),
                    2,
                    ManagedPolicyExecutionJournalTest.DOCUMENT,
                    f.deadline))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_DEVICE_BUSY");
    assertThat(
            f.db.queryForObject("SELECT COUNT(*) FROM managed_policy_execution_tasks", Long.class))
        .isZero();
  }

  @Test
  void oldExecutionIntakeCannotIgnoreAnIndependentlyStoredPendingRequest() throws Exception {
    long now = now();
    f.db.update(
        "INSERT INTO"
            + " managed_policy_preparation_requests(tenant_id,id,publication_id,policy_version_id,subject_id,device_id,registration_id,"
            + "binding_id,binding_version,actor_id,authority_version,context_sha256,state,reason_code,active_device_id,next_attempt_at,expires_at,created_at,updated_at)"
            + " VALUES(?,?,?,?,?,?,?,?,2,?,0,?,'PENDING','QUEUED',?,?,?,?,?)",
        f.f.tenant(),
        ManagedExecutionTestData.id(),
        f.f.publication(),
        f.f.version(),
        f.f.subject(),
        f.f.device(),
        f.f.registration(),
        f.f.binding(),
        f.f.actor(),
        SecretMaterial.hash(json.writeValueAsString(f.context)),
        f.f.device(),
        now,
        now + 900_000L,
        now,
        now);
    assertThatThrownBy(
            () ->
                f.journal.enqueue(
                    f.f.tenant(),
                    f.f.actor(),
                    f.f.publication(),
                    f.f.binding(),
                    2,
                    ManagedPolicyExecutionJournalTest.DOCUMENT,
                    f.deadline))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_DEVICE_BUSY");
  }

  @Test
  void replayCannotChangeTheFrozenRequestContext() {
    accept();
    f.db.update(
        "UPDATE managed_policy_preparation_requests SET context_sha256=? WHERE tenant_id=?",
        "d".repeat(64),
        f.f.tenant());
    assertThatThrownBy(this::accept)
        .isInstanceOf(DomainException.class)
        .hasMessage("PREPARATION_REQUEST_REUSED");
    assertThat(events).hasSize(1);
  }

  @Test
  void secondDeviceFailureDoesNotLeaveFirstDeviceQueued() {
    secondDevice();
    var last =
        targets.stream()
            .sorted(
                java.util.Comparator.comparing(ManagedExecutionPublicationAccess.Target::deviceId))
            .toList()
            .get(1);
    String binding =
        contexts.values().stream()
            .filter(c -> c.deviceId().equals(last.deviceId()))
            .findFirst()
            .orElseThrow()
            .bindingId();
    doThrow(new DomainException(HttpStatus.CONFLICT, "BINDING_REVOKED"))
        .when(f.bindings)
        .requireVerifiedContext(f.f.tenant(), f.f.actor(), binding, 2);
    assertThatThrownBy(this::accept)
        .isInstanceOf(DomainException.class)
        .hasMessage("BINDING_REVOKED");
    assertThat(rows()).isEmpty();
    assertThat(audits()).isZero();
  }

  long now() {
    return f.db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
  }

  long audits() {
    return f.db.queryForObject(
        "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='PREPARATION_ACCEPTED'",
        Long.class,
        f.f.tenant());
  }

  List<Map<String, Object>> rows() {
    return f.db.queryForList(
        "SELECT * FROM managed_policy_preparation_requests WHERE tenant_id=? ORDER BY id",
        f.f.tenant());
  }

  void secondDevice() {
    String device = ManagedExecutionTestData.id(),
        registration = ManagedExecutionTestData.id(),
        enrollment = ManagedExecutionTestData.id(),
        binding = ManagedExecutionTestData.id(),
        providerDevice = "device-" + ManagedExecutionTestData.id();
    cloneRow("devices", f.f.device(), Map.of("id", device, "registration_id", registration));
    cloneRow(
        "managed_enrollment_intents",
        f.f.enrollment(),
        Map.of(
            "id",
            enrollment,
            "provider_device_id",
            providerDevice,
            "nonce_hash",
            SecretMaterial.hash(enrollment)));
    cloneRow(
        "managed_agent_bindings",
        f.f.binding(),
        Map.of(
            "id",
            binding,
            "device_id",
            device,
            "registration_id",
            registration,
            "enrollment_id",
            enrollment,
            "provider_device_id",
            providerDevice,
            "request_key",
            ManagedExecutionTestData.id(),
            "active_device_id",
            device,
            "active_enrollment_id",
            enrollment));
    var original = f.context;
    contexts.put(
        binding,
        new ManagedAgentBindingStore.VerifiedBindingContext(
            original.tenantId(),
            original.actorId(),
            original.authorityVersion(),
            original.subjectId(),
            device,
            registration,
            original.keyThumbprint(),
            binding,
            original.bindingVersion(),
            enrollment,
            original.enrollmentVersion(),
            original.provider(),
            original.enterpriseId(),
            original.enterpriseBindingVersion(),
            providerDevice,
            original.managementMode(),
            original.bindingVerifiedAt(),
            original.agentPackageName(),
            original.agentTrustRevision(),
            original.platform(),
            original.registeredAt()));
    targets.add(new ManagedExecutionPublicationAccess.Target(device, registration));
  }

  void cloneRow(String table, String id, Map<String, Object> changes) {
    assertThat(List.of("devices", "managed_enrollment_intents", "managed_agent_bindings"))
        .contains(table);
    var row =
        new java.util.TreeMap<>(
            f.db.queryForMap(
                "SELECT * FROM " + table + " WHERE tenant_id=? AND id=?", f.f.tenant(), id));
    assertThat(row.keySet()).containsAll(changes.keySet());
    row.putAll(changes);
    String columns = String.join(",", row.keySet());
    String marks = String.join(",", java.util.Collections.nCopies(row.size(), "?"));
    f.db.update(
        "INSERT INTO " + table + "(" + columns + ") VALUES(" + marks + ")", row.values().toArray());
  }
}
