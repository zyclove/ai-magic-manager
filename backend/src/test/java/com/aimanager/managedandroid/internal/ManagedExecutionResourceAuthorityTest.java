package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.*;
import com.aimanager.managedandroid.ManagedPolicyResourceEvidence.*;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.http.HttpStatus;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Real persisted journal and preparation join; provider authority is an explicit local test double.
 */
class ManagedExecutionResourceAuthorityTest {
  ManagedExecutionPreparationServiceTest f;
  ManagedAndroidGateway gateway;
  ManagedExecutionResourceAuthorityService service;
  ObjectMapper mapper;
  AtomicReference<Target> requested;
  Function<Target, Optional<ManagedPolicyResourceEvidence>> observer;

  @BeforeEach
  void setup() {
    f = new ManagedExecutionPreparationServiceTest();
    f.setup();
    mapper = new ObjectMapper();
    gateway = mock(ManagedAndroidGateway.class);
    when(gateway.available()).thenReturn(true);
    when(gateway.providerCode()).thenReturn("LOCAL_TEST");
    when(gateway.supportsPolicyResourceAuthority()).thenReturn(true);
    when(gateway.policyResourceAuthorityRevision()).thenReturn("local-authority-v1");
    requested = new AtomicReference<>();
    observer = t -> Optional.of(valid(t));
    when(gateway.readPolicyResourceAuthority(any()))
        .thenAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
              Target target = call.getArgument(0);
              requested.set(target);
              return observer.apply(target);
            });
    service = create(120, 30, 5);
  }

  @AfterEach
  void close() {
    f.close();
  }

  @Test
  void currentTaskDeterminesEveryResourceFieldAndNeverWrites() throws Exception {
    var before = f.f.view();
    long events = f.f.events();
    var result = assertDoesNotThrow(() -> service.verify(f.f.claim));
    var claim = f.f.claim;
    var binding = f.sql.context;
    var expected =
        new Target(
            claim.tenantId(),
            claim.taskId(),
            f.device.publication(),
            f.f.publication().versionId(),
            f.device.device(),
            f.device.registration(),
            f.device.binding(),
            2,
            SecretMaterial.hash(mapper.writeValueAsString(binding)),
            "LOCAL_TEST",
            "local-authority-v1",
            claim.enterpriseId(),
            binding.enterpriseBindingVersion(),
            claim.deviceId(),
            claim.policyId(),
            null,
            claim.documentSha256(),
            claim.generation(),
            Purpose.WRITE_POLICY);
    assertThat(requested.get()).isEqualTo(expected);
    assertThat(result.evidence().target()).isEqualTo(expected);
    assertThat(result.prepared().target().claim()).isEqualTo(claim);
    assertThat(result.expiresAt()).isEqualTo(Math.min(claim.leaseUntil(), f.now.get() + 30000));
    assertThat(f.f.view()).isEqualTo(before);
    assertThat(f.f.events()).isEqualTo(events);
    verify(f.preparation, times(2))
        .prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class));
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
    assertThat(result.toString() + requested.get() + result.evidence())
        .doesNotContain(
            claim.token(),
            claim.policyId(),
            claim.documentJson(),
            "test-evidence",
            "test-namespace");
  }

  @Test
  void assignmentRequiresTheConfirmedExactVersion() {
    assertThat(
            f.sql.journal.beforeWrite(
                f.sql.journal.writePreparationTarget(f.f.claim), f.f.claim.leaseUntil()))
        .isTrue();
    var claim = f.f.claim;
    f.sql.journal.policyWritten(
        claim,
        new ManagedAndroidGateway.PolicyReceipt(
            "enterprises/" + claim.enterpriseId() + "/policies/" + claim.policyId(), 7L));
    f.f.claim = f.sql.journal.claimDue("LOCAL_TEST", 1).get(0);
    var result = assertDoesNotThrow(() -> service.verify(f.f.claim));
    assertThat(result.evidence().target().purpose()).isEqualTo(Purpose.ASSIGN_POLICY);
    assertThat(result.evidence().target().policyVersion()).isEqualTo(7L);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "UNAVAILABLE",
        "UNSUPPORTED",
        "MISSING_REVISION",
        "INVALID_REVISION",
        "WRONG_PROVIDER"
      })
  void rejectsConnectorWhichCannotProveCurrentAuthority(String change) {
    switch (change) {
      case "UNAVAILABLE" -> when(gateway.available()).thenReturn(false);
      case "UNSUPPORTED" -> when(gateway.supportsPolicyResourceAuthority()).thenReturn(false);
      case "MISSING_REVISION" -> when(gateway.policyResourceAuthorityRevision()).thenReturn(null);
      case "INVALID_REVISION" ->
          when(gateway.policyResourceAuthorityRevision()).thenReturn("bad\nrevision");
      case "WRONG_PROVIDER" -> when(gateway.providerCode()).thenReturn("OTHER_PROVIDER");
    }
    rejects("MANAGED_RESOURCE_CONNECTOR_UNAVAILABLE");
    verify(gateway, never()).readPolicyResourceAuthority(any());
  }

  @ParameterizedTest
  @ValueSource(strings = {"UNAVAILABLE", "UNSUPPORTED", "REVISION", "PROVIDER"})
  void neverQueriesAuthorityWhenConnectorChangesDuringInitialPreparation(String change) {
    when(f.preparation.prepare(
            anyString(),
            anyString(),
            anyString(),
            anyString(),
            anyLong(),
            any(ManagedProviderCalls.Budget.class)))
        .thenAnswer(
            call -> {
              switch (change) {
                case "UNAVAILABLE" -> when(gateway.available()).thenReturn(false);
                case "UNSUPPORTED" ->
                    when(gateway.supportsPolicyResourceAuthority()).thenReturn(false);
                case "REVISION" ->
                    when(gateway.policyResourceAuthorityRevision())
                        .thenReturn("local-authority-v2");
                case "PROVIDER" -> when(gateway.providerCode()).thenReturn("OTHER_PROVIDER");
              }
              return f.prepared;
            });
    rejects(
        change.equals("UNAVAILABLE") || change.equals("UNSUPPORTED")
            ? "MANAGED_RESOURCE_CONNECTOR_UNAVAILABLE"
            : "MANAGED_RESOURCE_CONTEXT_CHANGED");
    verify(gateway, never()).readPolicyResourceAuthority(any());
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "tenantId",
        "taskId",
        "publicationId",
        "policyVersionId",
        "deviceId",
        "registrationId",
        "bindingId",
        "bindingVersion",
        "bindingContextSha256",
        "provider",
        "adapterRevision",
        "enterpriseId",
        "enterpriseBindingVersion",
        "providerDeviceId",
        "policyId",
        "policyVersion",
        "documentSha256",
        "generation",
        "purpose"
      })
  void rejectsAnySubstitutedAuthorityTargetField(String field) {
    observer = t -> Optional.of(valid(alter(t, field)));
    rejects("MANAGED_RESOURCE_EVIDENCE_INVALID");
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "ABSENT",
        "NULL_OPTIONAL",
        "NULL_TARGET",
        "NULL_MECHANISM",
        "EMPTY_REFERENCE",
        "LONG_REFERENCE",
        "CONTROL_REFERENCE",
        "EMPTY_NAMESPACE",
        "NULL_OBSERVED",
        "NULL_EXPIRES",
        "EXPIRED",
        "FUTURE",
        "STALE",
        "REVERSED",
        "EXTREME_FUTURE",
        "EXTREME_PAST"
      })
  void rejectsMissingMalformedOrStaleEvidence(String change) {
    observer =
        t -> {
          if (change.equals("ABSENT")) return Optional.empty();
          if (change.equals("NULL_OPTIONAL")) return null;
          var p = valid(t);
          Instant observed = p.observedAt(), expires = p.expiresAt();
          switch (change) {
            case "NULL_OBSERVED" -> observed = null;
            case "NULL_EXPIRES" -> expires = null;
            case "EXPIRED" -> expires = Instant.ofEpochMilli(f.now.get());
            case "FUTURE" -> observed = Instant.ofEpochMilli(f.now.get() + 5001);
            case "STALE" -> observed = Instant.ofEpochMilli(f.now.get() - 120001);
            case "REVERSED" -> expires = observed.minusMillis(1);
            case "EXTREME_FUTURE" -> expires = Instant.MAX;
            case "EXTREME_PAST" -> observed = Instant.MIN;
          }
          return Optional.of(
              new ManagedPolicyResourceEvidence(
                  change.equals("NULL_TARGET") ? null : t,
                  change.equals("NULL_MECHANISM") ? null : p.mechanism(),
                  switch (change) {
                    case "EMPTY_REFERENCE" -> " ";
                    case "LONG_REFERENCE" -> "a".repeat(201);
                    case "CONTROL_REFERENCE" -> "bad\nreference";
                    default -> p.evidenceReference();
                  },
                  change.equals("EMPTY_NAMESPACE") ? "" : p.namespaceReference(),
                  observed,
                  expires));
        };
    rejects("MANAGED_RESOURCE_EVIDENCE_INVALID");
  }

  @Test
  void limitsUseToProviderEvidenceDeadline() {
    observer =
        t -> {
          var p = valid(t);
          return Optional.of(
              new ManagedPolicyResourceEvidence(
                  t,
                  p.mechanism(),
                  p.evidenceReference(),
                  p.namespaceReference(),
                  p.observedAt(),
                  Instant.ofEpochMilli(f.now.get() + 1000)));
        };
    var result = assertDoesNotThrow(() -> service.verify(f.f.claim));
    assertThat(result.expiresAt()).isEqualTo(f.now.get() + 1000);
  }

  @Test
  void limitsUseToReportAgeEvenWithLongProviderLifetime() {
    observer =
        t -> {
          var p = valid(t);
          return Optional.of(
              new ManagedPolicyResourceEvidence(
                  t,
                  p.mechanism(),
                  p.evidenceReference(),
                  p.namespaceReference(),
                  Instant.ofEpochMilli(f.now.get() - 119000),
                  p.expiresAt()));
        };
    var result = assertDoesNotThrow(() -> service.verify(f.f.claim));
    assertThat(result.expiresAt()).isEqualTo(f.now.get() + 1000);
  }

  @Test
  void rejectsEvidenceThatExpiresDuringProviderRead() {
    observer =
        t -> {
          var p = valid(t);
          f.now.addAndGet(60000);
          return Optional.of(p);
        };
    rejects("MANAGED_RESOURCE_EVIDENCE_INVALID");
  }

  @Test
  void sanitizesProviderExceptionsAndDoesNotAttachTheirCause() {
    observer =
        t -> {
          throw new IllegalStateException("SECRET_PROVIDER_BODY");
        };
    assertThatThrownBy(() -> service.verify(f.f.claim))
        .isInstanceOf(DomainException.class)
        .hasMessage("MANAGED_RESOURCE_PROVIDER_UNAVAILABLE")
        .hasNoCause();
  }

  @Test
  void revalidatesApplicationQualificationsAfterAuthorityRead() {
    observer =
        t -> {
          when(f.preparation.prepare(
                  anyString(),
                  anyString(),
                  anyString(),
                  anyString(),
                  anyLong(),
                  any(ManagedProviderCalls.Budget.class)))
              .thenThrow(
                  new DomainException(
                      HttpStatus.UNPROCESSABLE_ENTITY, "TEST_APPLICATION_QUALIFICATION_REVOKED"));
          return Optional.of(valid(t));
        };
    rejects("TEST_APPLICATION_QUALIFICATION_REVOKED");
  }

  @Test
  void rejectsProofThatExpiresDuringFinalPolicyPreparation() {
    observer =
        t -> {
          var p = valid(t);
          var proof =
              new ManagedPolicyResourceEvidence(
                  t,
                  p.mechanism(),
                  p.evidenceReference(),
                  p.namespaceReference(),
                  p.observedAt(),
                  Instant.ofEpochMilli(f.now.get() + 1000));
          when(f.preparation.prepare(
                  anyString(),
                  anyString(),
                  anyString(),
                  anyString(),
                  anyLong(),
                  any(ManagedProviderCalls.Budget.class)))
              .thenAnswer(
                  call -> {
                    f.now.addAndGet(1000);
                    return f.prepared;
                  });
          return Optional.of(proof);
        };
    rejects("MANAGED_RESOURCE_EVIDENCE_INVALID");
  }

  @Test
  void cancellationBeforePreparationPreventsAuthorityRead() {
    cancel();
    rejects("EXECUTION_PREPARATION_STALE");
    verify(gateway, never()).readPolicyResourceAuthority(any());
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "CANCEL",
        "RECLAIM",
        "REVOKE",
        "PUBLICATION_VERSION",
        "PUBLICATION_METADATA",
        "PROVIDER_REVISION",
        "PROVIDER_UNAVAILABLE",
        "PROVIDER_UNSUPPORTED"
      })
  void rechecksTaskAndConnectorAfterProviderRead(String change) {
    var publication = f.f.publication();
    observer =
        t -> {
          switch (change) {
            case "CANCEL" -> cancel();
            case "RECLAIM" -> {
              f.sql.db.update(
                  "UPDATE managed_policy_execution_tasks SET lease_until=created_at-1,"
                      + " next_attempt_at=created_at WHERE id=?",
                  f.f.claim.taskId());
              assertThat(f.sql.journal.claimDue("LOCAL_TEST", 1)).hasSize(1);
            }
            case "REVOKE" ->
                when(f.sql.bindings.requireVerifiedContext(
                        anyString(), anyString(), anyString(), anyLong()))
                    .thenThrow(new DomainException(HttpStatus.FORBIDDEN, "TEST_AUTHORITY_REVOKED"));
            case "PUBLICATION_VERSION", "PUBLICATION_METADATA" ->
                when(f.sql.publications.requireTarget(
                        anyString(), anyString(), anyString(), anyString(), anyString()))
                    .thenReturn(
                        new ManagedExecutionPublicationAccess.Publication(
                            change.equals("PUBLICATION_VERSION")
                                ? UUID.randomUUID().toString()
                                : publication.versionId(),
                            "d".repeat(64),
                            publication.createdAt() + 1));
            case "PROVIDER_REVISION" ->
                when(gateway.policyResourceAuthorityRevision()).thenReturn("local-authority-v2");
            case "PROVIDER_UNAVAILABLE" -> when(gateway.available()).thenReturn(false);
            case "PROVIDER_UNSUPPORTED" ->
                when(gateway.supportsPolicyResourceAuthority()).thenReturn(false);
          }
          return Optional.of(valid(t));
        };
    rejects(
        switch (change) {
          case "CANCEL", "RECLAIM" -> "EXECUTION_PREPARATION_STALE";
          case "REVOKE" -> "TEST_AUTHORITY_REVOKED";
          case "PUBLICATION_VERSION" -> "EXECUTION_CONTEXT_CHANGED";
          case "PUBLICATION_METADATA", "PROVIDER_REVISION" -> "MANAGED_RESOURCE_CONTEXT_CHANGED";
          default -> "MANAGED_RESOURCE_CONNECTOR_UNAVAILABLE";
        });
  }

  @Test
  void rejectsOuterTransactionBeforeAnyPreparationOrProviderRead() {
    assertThatThrownBy(
            () ->
                new TransactionTemplate(f.sql.data.transactions)
                    .execute(status -> service.verify(f.f.claim)))
        .isInstanceOf(IllegalStateException.class);
    verifyNoInteractions(gateway, f.preparation);
  }

  @ParameterizedTest
  @CsvSource({"0,30,5", "601,30,5", "120,0,5", "120,121,5", "120,30,-1", "120,30,31"})
  void rejectsUnboundedFreshnessConfiguration(long age, long reuse, long skew) {
    assertThatThrownBy(() -> create(age, reuse, skew)).isInstanceOf(IllegalArgumentException.class);
  }

  private ManagedExecutionResourceAuthorityService create(long age, long reuse, long skew) {
    return new ManagedExecutionResourceAuthorityService(
        f.sql.journal,
        new ManagedExecutionPreparationService(f.sql.journal, f.preparation, f.clock, f.calls),
        gateway,
        mapper,
        f.clock,
        age,
        reuse,
        skew,
        f.calls);
  }

  private ManagedPolicyResourceEvidence valid(Target target) {
    return new ManagedPolicyResourceEvidence(
        target,
        Mechanism.AUDITED_EXCLUSIVE_NAMESPACE,
        "test-evidence",
        "test-namespace",
        Instant.ofEpochMilli(f.now.get()),
        Instant.ofEpochMilli(f.now.get() + 60000));
  }

  private void rejects(String code) {
    assertThatThrownBy(() -> service.verify(f.f.claim))
        .isInstanceOf(DomainException.class)
        .hasMessage(code);
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  private void cancel() {
    f.sql.journal.cancel(
        f.device.tenant(), f.device.actor(), f.f.claim.taskId(), f.f.view().revision());
  }

  /** Record mutation is test data generation; the service under test is called directly. */
  private static Target alter(Target target, String field) {
    try {
      var parts = Target.class.getRecordComponents();
      var types = new Class<?>[parts.length];
      var values = new Object[parts.length];
      boolean found = false;
      for (int i = 0; i < parts.length; i++) {
        var p = parts[i];
        types[i] = p.getType();
        values[i] = p.getAccessor().invoke(target);
        if (p.getName().equals(field)) {
          found = true;
          if (p.getType() == String.class) values[i] = values[i] + "-changed";
          else if (p.getType() == long.class) values[i] = ((Long) values[i]) + 1;
          else if (p.getType() == Long.class)
            values[i] = values[i] == null ? Long.valueOf(1) : ((Long) values[i]) + 1;
          else values[i] = Purpose.ASSIGN_POLICY;
        }
      }
      assertThat(found).isTrue();
      return Target.class.getDeclaredConstructor(types).newInstance(values);
    } catch (ReflectiveOperationException failure) {
      throw new AssertionError(failure);
    }
  }
}
