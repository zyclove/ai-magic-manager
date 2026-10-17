package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.*;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import java.lang.reflect.InvocationTargetException;
import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.http.HttpStatus;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Real persisted journal and joining service; the already-tested preparer is an explicit stub. */
class ManagedExecutionPreparationServiceTest {
  ManagedExecutionPreparationContextTest f;
  ManagedPolicyExecutionJournalTest sql;
  ManagedExecutionTestData.Fixture device;
  ManagedPolicyPreparationService preparation;
  ManagedPolicyPreparationService.Prepared prepared;
  Clock clock;
  AtomicLong now;

  @BeforeEach
  void setup() {
    f = new ManagedExecutionPreparationContextTest();
    f.setup();
    sql = f.f;
    device = sql.f;
    now = new AtomicLong(System.currentTimeMillis());
    clock = mock(Clock.class);
    when(clock.millis()).thenAnswer(call -> now.get());
    when(clock.instant()).thenAnswer(call -> Instant.ofEpochMilli(now.get()));
    preparation = mock(ManagedPolicyPreparationService.class);
    prepared = prepared("VALID");
    when(preparation.prepare(anyString(), anyString(), anyString(), anyString(), anyLong()))
        .thenAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
              return prepared;
            });
  }

  @AfterEach
  void close() {
    f.close();
  }

  @Test
  void joinsOnlyCurrentStoredContextAndExactDocumentWithoutDispatching() {
    var before = f.view();
    long events = f.events();
    var result = prepare();
    assertThat(ManagedExecutionPreparationContextTest.field(result, "preparation"))
        .isEqualTo(prepared);
    var target = ManagedExecutionPreparationContextTest.field(result, "target");
    assertThat(ManagedExecutionPreparationContextTest.field(target, "claim")).isEqualTo(f.claim);
    assertThat(ManagedExecutionPreparationContextTest.field(result, "expiresAt"))
        .isEqualTo(f.claim.leaseUntil());
    verify(preparation)
        .prepare(device.tenant(), device.actor(), device.publication(), device.binding(), 2);
    assertThat(f.view()).isEqualTo(before);
    assertThat(f.events()).isEqualTo(events);
    assertThat(result.toString())
        .doesNotContain(f.claim.token(), f.claim.documentJson(), f.claim.policyId());
  }

  @ParameterizedTest
  @ValueSource(strings = {"DOCUMENT", "DIGEST", "PUBLICATION", "VERSION", "DEVICE", "REGISTRATION"})
  void refusesPreparationWhichDoesNotMatchFrozenTask(String change) {
    prepared = prepared(change);
    assertThatThrownBy(this::prepare)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_CHANGED");
    assertThat(f.view().state()).isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
  }

  @Test
  void rejectsCancelledTaskBeforeCallingPreparer() {
    sql.journal.cancel(device.tenant(), device.actor(), f.claim.taskId(), f.view().revision());
    assertThatThrownBy(this::prepare)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_STALE");
    verifyNoInteractions(preparation);
  }

  @Test
  void rejectsCancellationDuringPreparation() {
    doAnswer(
            call -> {
              sql.journal.cancel(
                  device.tenant(), device.actor(), f.claim.taskId(), f.view().revision());
              return prepared;
            })
        .when(preparation)
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong());
    assertThatThrownBy(this::prepare)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_STALE");
  }

  @Test
  void rejectsAuthorityRevokedDuringPreparation() {
    doAnswer(
            call -> {
              when(sql.bindings.requireVerifiedContext(
                      anyString(), anyString(), anyString(), anyLong()))
                  .thenThrow(new DomainException(HttpStatus.FORBIDDEN, "TEST_AUTHORITY_REVOKED"));
              return prepared;
            })
        .when(preparation)
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong());
    assertThatThrownBy(this::prepare)
        .isInstanceOf(DomainException.class)
        .hasMessage("TEST_AUTHORITY_REVOKED");
  }

  @Test
  void applicationEvidenceExpiryIsTheMinimumDeadline() {
    long cutoff = now.get() + 1000;
    prepared =
        new ManagedPolicyPreparationService.Prepared(
            prepared.publicationId(),
            prepared.binding(),
            prepared.desired(),
            prepared.profile(),
            prepared.document(),
            new ManagedPolicyControlAdmission.Checked(List.of(), List.of(), cutoff));
    assertThat(ManagedExecutionPreparationContextTest.field(prepare(), "expiresAt"))
        .isEqualTo(cutoff);
  }

  @Test
  void rejectsLeaseReclaimedDuringPreparation() {
    var reclaimed =
        new java.util.concurrent.atomic.AtomicReference<ManagedPolicyExecutionJournal.Claim>();
    var afterClaim =
        new java.util.concurrent.atomic.AtomicReference<ManagedPolicyExecutionJournal.View>();
    var eventCount = new AtomicLong();
    doAnswer(
            call -> {
              sql.db.update(
                  "UPDATE managed_policy_execution_tasks SET lease_until=created_at-1,"
                      + " next_attempt_at=created_at WHERE id=?",
                  f.claim.taskId());
              reclaimed.set(sql.journal.claimDue("LOCAL_TEST", 1).get(0));
              afterClaim.set(f.view());
              eventCount.set(f.events());
              return prepared;
            })
        .when(preparation)
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong());
    assertThatThrownBy(this::prepare)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_STALE");
    assertThat(reclaimed.get().generation()).isGreaterThan(f.claim.generation());
    assertThat(reclaimed.get().token()).isNotEqualTo(f.claim.token());
    assertThat(f.view()).isEqualTo(afterClaim.get());
    assertThat(f.events()).isEqualTo(eventCount.get());
  }

  @Test
  void rejectsBindingChangedDuringPreparation() {
    var before = f.view();
    long events = f.events();
    doAnswer(
            call -> {
              var c = sql.context;
              sql.context =
                  new ManagedAgentBindingStore.VerifiedBindingContext(
                      c.tenantId(),
                      c.actorId(),
                      c.authorityVersion() + 1,
                      c.subjectId(),
                      c.deviceId(),
                      c.registrationId(),
                      c.keyThumbprint(),
                      c.bindingId(),
                      c.bindingVersion(),
                      c.enrollmentId(),
                      c.enrollmentVersion(),
                      c.provider(),
                      c.enterpriseId(),
                      c.enterpriseBindingVersion(),
                      c.providerDeviceId(),
                      c.managementMode(),
                      c.bindingVerifiedAt(),
                      c.agentPackageName(),
                      c.agentTrustRevision(),
                      c.platform(),
                      c.registeredAt());
              return prepared;
            })
        .when(preparation)
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong());
    assertThatThrownBy(this::prepare)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_CONTEXT_CHANGED");
    assertThat(f.view()).isEqualTo(before);
    assertThat(f.events()).isEqualTo(events);
  }

  @Test
  void rejectsPublishedVersionChangedDuringPreparation() {
    rejectPublicationChangeDuringPreparation(true);
  }

  @Test
  void rejectsPublishedMetadataChangedDuringPreparation() {
    rejectPublicationChangeDuringPreparation(false);
  }

  private void rejectPublicationChangeDuringPreparation(boolean versionChanged) {
    var before = f.view();
    long events = f.events();
    var original = f.publication();
    var changed =
        new ManagedExecutionPublicationAccess.Publication(
            versionChanged ? UUID.randomUUID().toString() : original.versionId(),
            "d".repeat(64),
            original.createdAt() + 1);
    doAnswer(
            call -> {
              when(sql.publications.requireTarget(
                      anyString(), anyString(), anyString(), anyString(), anyString()))
                  .thenReturn(changed);
              return prepared;
            })
        .when(preparation)
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong());
    assertThatThrownBy(this::prepare)
        .isInstanceOf(DomainException.class)
        .hasMessage(versionChanged ? "EXECUTION_CONTEXT_CHANGED" : "EXECUTION_PREPARATION_CHANGED");
    assertThat(f.view()).isEqualTo(before);
    assertThat(f.events()).isEqualTo(events);
  }

  @Test
  void refusesResultAtExactEvidenceDeadline() {
    long cutoff = now.get() + 1000;
    prepared =
        new ManagedPolicyPreparationService.Prepared(
            prepared.publicationId(),
            prepared.binding(),
            prepared.desired(),
            prepared.profile(),
            prepared.document(),
            new ManagedPolicyControlAdmission.Checked(List.of(), List.of(), cutoff));
    doAnswer(
            call -> {
              now.set(cutoff);
              return prepared;
            })
        .when(preparation)
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong());
    assertThatThrownBy(this::prepare)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PREPARATION_EXPIRED");
  }

  @Test
  void propagatesPreparationRejectionWithoutAdvancingTask() {
    var before = f.view();
    doThrow(
            new DomainException(
                HttpStatus.UNPROCESSABLE_ENTITY, "MANAGED_PREPARATION_APPLICATION_UNVERIFIED"))
        .when(preparation)
        .prepare(anyString(), anyString(), anyString(), anyString(), anyLong());
    assertThatThrownBy(this::prepare)
        .isInstanceOf(DomainException.class)
        .hasMessage("MANAGED_PREPARATION_APPLICATION_UNVERIFIED");
    assertThat(f.view()).isEqualTo(before);
  }

  @Test
  void joiningServiceCannotRunInOuterTransaction() {
    assertThatThrownBy(
            () -> new TransactionTemplate(sql.data.transactions).execute(status -> prepare()))
        .isInstanceOf(IllegalStateException.class);
    verifyNoInteractions(preparation);
  }

  private ManagedPolicyPreparationService.Prepared prepared(String change) {
    var p = f.publication();
    var desired =
        new ManagedDesiredPolicy(
            change.equals("VERSION")
                ? new ManagedExecutionPublicationAccess.Publication(
                    UUID.randomUUID().toString(), p.previewHash(), p.createdAt())
                : p,
            change.equals("DEVICE") ? UUID.randomUUID().toString() : device.device(),
            change.equals("REGISTRATION") ? UUID.randomUUID().toString() : device.registration(),
            List.of(),
            List.of(),
            List.of());
    String document = change.equals("DOCUMENT") ? "{}" : f.claim.documentJson();
    var profile =
        new ManagedDeviceExecutionVerifier.Verified(
            "enterprises/" + f.claim.enterpriseId() + "/devices/" + f.claim.deviceId(),
            "DEVICE_OWNER",
            30,
            Instant.ofEpochMilli(now.get() - 1000),
            Instant.ofEpochMilli(now.get()),
            Instant.ofEpochMilli(now.get() + 60000));
    return new ManagedPolicyPreparationService.Prepared(
        change.equals("PUBLICATION") ? UUID.randomUUID().toString() : device.publication(),
        sql.context,
        desired,
        profile,
        new ManagedAndroidGateway.PolicyDocument(
            document,
            change.equals("DIGEST") ? "d".repeat(64) : SecretMaterial.hash(document),
            sql.context.agentPackageName(),
            30,
            "DEVICE_OWNER"),
        new ManagedPolicyControlAdmission.Checked(List.of(), List.of(), Long.MAX_VALUE));
  }

  private Object prepare() {
    try {
      var type =
          Class.forName("com.aimanager.managedandroid.internal.ManagedExecutionPreparationService");
      var constructor =
          type.getDeclaredConstructor(
              ManagedPolicyExecutionJournal.class,
              ManagedPolicyPreparationService.class,
              Clock.class);
      var service = constructor.newInstance(sql.journal, preparation, clock);
      return type.getDeclaredMethod("prepare", ManagedPolicyExecutionJournal.Claim.class)
          .invoke(service, f.claim);
    } catch (ClassNotFoundException missing) {
      throw new AssertionError(
          "execution preparation must join the current durable task and prepared policy", missing);
    } catch (InvocationTargetException failure) {
      if (failure.getCause() instanceof RuntimeException runtime) throw runtime;
      if (failure.getCause() instanceof Error error) throw error;
      throw new AssertionError(failure.getCause());
    } catch (ReflectiveOperationException failure) {
      throw new AssertionError(failure);
    }
  }
}
