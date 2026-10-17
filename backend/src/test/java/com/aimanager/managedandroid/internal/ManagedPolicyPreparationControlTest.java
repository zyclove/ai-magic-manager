package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.catalog.ApplicationIdentity;
import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.*;
import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.FilterType;
import org.springframework.transaction.PlatformTransactionManager;

/** Exercises the real preparation boundary, not a standalone qualification predicate. */
class ManagedPolicyPreparationControlTest {
  @Configuration(proxyBeanMethods = false)
  @ComponentScan(
      basePackageClasses = ManagedPolicyPreparationService.class,
      useDefaultFilters = false,
      includeFilters =
          @ComponentScan.Filter(
              type = FilterType.REGEX,
              pattern =
                  "com\\.aimanager\\.managedandroid\\.internal\\.ManagedPolicyControlAdmission"))
  static class AdmissionConfiguration {}

  GooglePolicyPreparationServiceTest f;
  ApplicationCatalog catalog;
  ManagedApplicationEvidenceStore evidence;
  AtomicReference<List<ManagedPolicyEvidenceAccess.ApplicationEvidence>> facts;
  ApplicationIdentity identity;
  Clock clock;
  ManagedPolicyDocumentCompiler compiler;

  @BeforeEach
  void setup() {
    f = new GooglePolicyPreparationServiceTest();
    f.setup();
    clock = f.clock;
    compiler = new GoogleManagedPolicyDocumentCompiler();
    catalog = mock(ApplicationCatalog.class);
    evidence = mock(ManagedApplicationEvidenceStore.class);
    identity =
        new ApplicationIdentity(
            "app",
            Device.Platform.ANDROID,
            "com.example.lesson",
            ApplicationDefinition.Profile.PRIMARY,
            List.of("a".repeat(64)),
            "b".repeat(64),
            f.now.minusSeconds(200));
    when(catalog.requireEvidenceIdentity("tenant", "actor", "app")).thenReturn(identity);
    facts = new AtomicReference<>(List.of(fact("VALID")));
    when(evidence.forPolicy(eq(f.binding), anyMap()))
        .thenAnswer(
            call -> {
              f.insideTransaction();
              return facts.get();
            });
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "EMPTY",
        "EXPIRED",
        "WRONG_APP",
        "WRONG_REGISTRATION",
        "WRONG_BINDING",
        "WRONG_DEFINITION",
        "WRONG_SCOPE",
        "NO_CONTROL",
        "NO_LAUNCH",
        "WRONG_PERMISSION"
      })
  void refusesUnqualifiedCurrentOperationBeforeProviderReads(String change) {
    facts.set(change.equals("EMPTY") ? List.of() : List.of(fact(change)));
    withService(
        service ->
            assertThatThrownBy(
                    () -> prepare(service),
                    "preparation must require current exact application control evidence")
                .isInstanceOf(DomainException.class)
                .hasMessage("MANAGED_PREPARATION_APPLICATION_UNVERIFIED"));
    verify(f.gateway, never()).readEnrollmentIdentity(anyString(), anyString());
    verify(f.gateway, never()).readExecutionProfile(anyString(), anyString());
  }

  @Test
  void rechecksControlEvidenceAfterProviderRead() {
    doAnswer(
            call -> {
              f.outsideTransaction();
              facts.set(List.of(fact("NO_LAUNCH")));
              return f.identity("nonce");
            })
        .when(f.gateway)
        .readEnrollmentIdentity("e1", "d1");
    withService(
        service ->
            assertThatThrownBy(
                    () -> prepare(service),
                    "a qualified operation revoked during provider I/O must stop preparation")
                .isInstanceOf(DomainException.class)
                .hasMessage("MANAGED_PREPARATION_APPLICATION_UNVERIFIED"));
    verify(f.gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void qualifiedOperationsAreCheckedTwiceWithoutCallingApplicationProvider() {
    withService(service -> assertThat(prepare(service)).isNotNull());
    assertThat(mockingDetails(evidence).getInvocations())
        .as("qualified operations must be checked before and after provider reads")
        .hasSize(2);
    verify(evidence, times(2)).forPolicy(eq(f.binding), anyMap());
    verify(catalog, times(2)).requireEvidenceIdentity("tenant", "actor", "app");
    verify(f.gateway, never()).readApplicationControlReport(anyString(), anyString(), anyString());
    verify(f.gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
  }

  @ParameterizedTest
  @ValueSource(strings = {"PACKAGE", "SIGNER", "PROFILE", "PLATFORM"})
  void currentApplicationDeclarationMustMatchFrozenPublication(String change) {
    when(catalog.requireEvidenceIdentity("tenant", "actor", "app"))
        .thenReturn(
            new ApplicationIdentity(
                "app",
                change.equals("PLATFORM") ? Device.Platform.ANDROID_TV : Device.Platform.ANDROID,
                change.equals("PACKAGE") ? "com.example.changed" : identity.packageName(),
                change.equals("PROFILE") ? ApplicationDefinition.Profile.WORK : identity.profile(),
                change.equals("SIGNER") ? List.of("d".repeat(64)) : identity.signingDigests(),
                identity.revision(),
                identity.establishedAt()));
    withService(
        service ->
            assertThatThrownBy(
                    () -> prepare(service),
                    "published application identity must match the current catalog")
                .isInstanceOf(DomainException.class)
                .hasMessage("MANAGED_PREPARATION_APPLICATION_UNVERIFIED"));
    verify(f.gateway, never()).readEnrollmentIdentity(anyString(), anyString());
  }

  @Test
  void refreshedEvidenceVersionDuringProviderReadChangesThePreparationSnapshot() {
    var original = fact("VALID");
    var refreshed =
        new ManagedPolicyEvidenceAccess.ApplicationEvidence(
            original.deviceId(),
            original.registrationId(),
            original.applicationId(),
            original.bindingId(),
            original.bindingVersion(),
            original.definitionRevision(),
            2,
            original.state(),
            original.reasonCode(),
            original.profileScope(),
            true,
            original.reportedAt(),
            original.retrievedAt(),
            original.expiresAt(),
            original.controlOperations());
    doAnswer(
            call -> {
              facts.set(List.of(refreshed));
              return f.identity("nonce");
            })
        .when(f.gateway)
        .readEnrollmentIdentity("e1", "d1");
    withService(
        service ->
            assertThatThrownBy(() -> prepare(service))
                .isInstanceOf(DomainException.class)
                .hasMessage("MANAGED_PREPARATION_CONTEXT_CHANGED"));
  }

  private ManagedPolicyPreparationService.Prepared prepare(
      ManagedPolicyPreparationService service) {
    return service.prepare("tenant", "actor", "publication", "binding", 1);
  }

  @Test
  void refusesApplicationEvidenceExpiringDuringCompilationWhileDeviceProfileRemainsValid() {
    var time = new AtomicReference<Instant>(f.now);
    clock = mock(Clock.class);
    when(clock.instant()).thenAnswer(call -> time.get());
    when(clock.millis()).thenAnswer(call -> time.get().toEpochMilli());
    var original = fact("VALID");
    var deadline = f.now.plusSeconds(20);
    facts.set(
        List.of(
            new ManagedPolicyEvidenceAccess.ApplicationEvidence(
                original.deviceId(),
                original.registrationId(),
                original.applicationId(),
                original.bindingId(),
                original.bindingVersion(),
                original.definitionRevision(),
                original.evidenceVersion(),
                original.state(),
                original.reasonCode(),
                original.profileScope(),
                original.systemControlAvailable(),
                original.reportedAt(),
                original.retrievedAt(),
                deadline.toEpochMilli(),
                original.controlOperations())));
    var delegate = compiler;
    compiler = mock(ManagedPolicyDocumentCompiler.class);
    when(compiler.providerCode()).thenReturn(delegate.providerCode());
    when(compiler.adapterRevision()).thenReturn(delegate.adapterRevision());
    when(compiler.compile(any(), anyString(), any(), anySet()))
        .thenAnswer(
            call -> {
              f.insideTransaction();
              var document =
                  delegate.compile(
                      call.getArgument(0),
                      call.getArgument(1),
                      call.getArgument(2),
                      call.getArgument(3));
              time.set(deadline);
              return document;
            });
    withService(
        service ->
            assertThatThrownBy(
                    () -> prepare(service),
                    "the final application-evidence deadline must be enforced after compilation")
                .isInstanceOf(DomainException.class)
                .hasMessage("MANAGED_PREPARATION_APPLICATION_UNVERIFIED"));
    verify(evidence, times(2)).forPolicy(eq(f.binding), anyMap());
    verify(compiler).compile(any(), anyString(), any(), anySet());
    verify(f.gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(f.gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  private ManagedPolicyEvidenceAccess.ApplicationEvidence fact(String change) {
    var launch =
        new ManagedControlOperation(
            ManagedControlOperation.Kind.APP_LAUNCH, ManagedControlOperation.Effect.DENY, null);
    var permission =
        new ManagedControlOperation(
            ManagedControlOperation.Kind.RUNTIME_PERMISSION,
            ManagedControlOperation.Effect.DENY,
            change.equals("WRONG_PERMISSION")
                ? "android.permission.RECORD_AUDIO"
                : "android.permission.CAMERA");
    return new ManagedPolicyEvidenceAccess.ApplicationEvidence(
        "device",
        change.equals("WRONG_REGISTRATION") ? "other-registration" : "registration",
        change.equals("WRONG_APP") ? "other-app" : "app",
        change.equals("WRONG_BINDING") ? "other-binding" : "binding",
        1,
        change.equals("WRONG_DEFINITION") ? "c".repeat(64) : "b".repeat(64),
        1,
        "VERIFIED_IDENTITY",
        "MANAGED_APPLICATION_CONTROL_VERIFIED",
        change.equals("WRONG_SCOPE") ? "UNKNOWN" : "PRIMARY",
        !change.equals("NO_CONTROL"),
        f.now.minusSeconds(10).toEpochMilli(),
        f.now.toEpochMilli(),
        (change.equals("EXPIRED") ? f.now.minusSeconds(1) : f.now.plusSeconds(120)).toEpochMilli(),
        change.equals("NO_LAUNCH") ? List.of(permission) : List.of(launch, permission));
  }

  private void withService(Consumer<ManagedPolicyPreparationService> assertion) {
    new ApplicationContextRunner()
        .withUserConfiguration(AdmissionConfiguration.class)
        .withBean(ManagedAgentBindingStore.class, () -> f.bindings)
        .withBean(ManagedEnrollmentStore.class, () -> f.enrollments)
        .withBean(ManagedExecutionPublicationAccess.class, () -> f.publications)
        .withBean(ManagedAndroidGateway.class, () -> f.gateway)
        .withBean(
            ManagedPolicyDocumentCompilers.class,
            () -> new ManagedPolicyDocumentCompilers(List.of(compiler)))
        .withBean(
            ManagedDeviceProfileSettings.class,
            () -> new ManagedDeviceProfileSettings(clock, 600, 120, 15))
        .withBean(Clock.class, () -> clock)
        .withBean(PlatformTransactionManager.class, () -> f.transactions)
        .withBean(ApplicationCatalog.class, () -> catalog)
        .withBean(ManagedApplicationEvidenceStore.class, () -> evidence)
        .withBean(ManagedPolicyPreparationService.class)
        .run(
            context -> {
              assertThat(context).hasNotFailed();
              assertion.accept(context.getBean(ManagedPolicyPreparationService.class));
            });
  }
}
