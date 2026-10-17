package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.*;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import java.time.*;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

class GooglePolicyPreparationServiceTest {
  final Instant now = Instant.parse("2026-10-16T12:00:00Z");
  final Clock clock = Clock.fixed(now, ZoneOffset.UTC);
  final ManagedAgentBindingStore bindings = mock(ManagedAgentBindingStore.class);
  final ManagedEnrollmentStore enrollments = mock(ManagedEnrollmentStore.class);
  final ManagedExecutionPublicationAccess publications =
      mock(ManagedExecutionPublicationAccess.class);
  final ManagedAndroidGateway gateway = mock(ManagedAndroidGateway.class);
  final List<String> steps = new ArrayList<>();
  final DataSourceTransactionManager transactions =
      new DataSourceTransactionManager(
          new DriverManagerDataSource("jdbc:h2:mem:preparation-" + UUID.randomUUID(), "sa", ""));
  final ManagedAgentBindingStore.VerifiedBindingContext binding = binding(1);
  final ManagedEnrollmentStore.Intent intent =
      new ManagedEnrollmentStore.Intent(
          "tenant",
          "enrollment",
          "subject",
          "GOOGLE_AMAPI",
          "e1",
          1,
          "base",
          1,
          "enterprises/e1/enrollmentTokens/t1",
          SecretMaterial.hash("nonce"),
          "d1",
          "DEVICE_OWNER",
          "VERIFIED",
          1,
          "actor",
          now.minusSeconds(200).toEpochMilli(),
          now.minusSeconds(190).toEpochMilli(),
          now.plusSeconds(300).toEpochMilli(),
          now.minusSeconds(150).toEpochMilli(),
          now.toEpochMilli());
  final ManagedDesiredPolicy desired = desired("v1");
  ManagedPolicyPreparationService service;

  @BeforeEach
  void setup() {
    when(gateway.providerCode()).thenReturn("GOOGLE_AMAPI");
    when(gateway.available()).thenReturn(true);
    when(gateway.supportsExecutionProfiles()).thenReturn(true);
    when(gateway.supportsCompletePolicyDocuments()).thenReturn(true);
    when(bindings.requireVerifiedContext("tenant", "actor", "binding", 1))
        .thenAnswer(
            call -> {
              insideTransaction();
              steps.add("binding");
              return binding;
            });
    when(enrollments.forProviderStatus("tenant", "enrollment", "actor"))
        .thenAnswer(
            call -> {
              insideTransaction();
              steps.add("enrollment");
              return intent;
            });
    when(publications.requireDesiredTarget(
            "tenant", "actor", "publication", "device", "registration"))
        .thenAnswer(
            call -> {
              insideTransaction();
              steps.add("publication");
              return desired;
            });
    when(gateway.readEnrollmentIdentity("e1", "d1"))
        .thenAnswer(
            call -> {
              outsideTransaction();
              steps.add("identity");
              return identity("nonce");
            });
    when(gateway.readExecutionProfile("e1", "d1"))
        .thenAnswer(
            call -> {
              outsideTransaction();
              steps.add("profile");
              return Optional.of(
                  new ManagedDeviceExecutionProfile(
                      "enterprises/e1/devices/d1",
                      "DEVICE_OWNER",
                      30,
                      "ACTIVE",
                      "ACTIVE",
                      now.minusSeconds(10).toString()));
            });
    service =
        new ManagedPolicyPreparationService(
            bindings,
            enrollments,
            publications,
            gateway,
            new ManagedPolicyDocumentCompilers(List.of(new GoogleManagedPolicyDocumentCompiler())),
            new ManagedDeviceProfileSettings(clock, 600, 120, 15),
            ManagedPreparationTestQualifications.allow(),
            clock,
            transactions,
            "");
  }

  @Test
  void compilesPublishedRulesOnlyAfterRecheckingCurrentContext() {
    var result = prepare();
    assertThat(result)
        .as("published execution preparation must compose current context")
        .isNotNull();
    assertThat(result.binding()).isEqualTo(binding);
    assertThat(result.desired()).isEqualTo(desired);
    assertThat(result.profile().expiresAt()).isEqualTo(now.plusSeconds(120));
    assertThat(googlePolicy(result.document()).getApplications())
        .anySatisfy(
            app -> {
              assertThat(app.getPackageName()).isEqualTo("com.example.lesson");
              assertThat(app.getDisabled()).isTrue();
              assertThat(app.getPermissionGrants())
                  .anySatisfy(
                      grant -> {
                        assertThat(grant.getPermission()).isEqualTo("android.permission.CAMERA");
                        assertThat(grant.getPolicy()).isEqualTo("DENY");
                      });
            });
    assertThat(steps)
        .containsExactly(
            "binding",
            "enrollment",
            "publication",
            "identity",
            "profile",
            "identity",
            "binding",
            "enrollment",
            "publication");
    assertThat(result.toString()).isEqualTo("PreparedManagedPolicy[REDACTED]");
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
  }

  @Test
  void refusesAnOuterTransactionBeforeReadingAnyContext() {
    assertThatThrownBy(() -> new TransactionTemplate(transactions).execute(status -> prepare()))
        .isInstanceOf(IllegalStateException.class);
    verifyNoInteractions(bindings, enrollments, publications, gateway);
  }

  @ParameterizedTest
  @ValueSource(strings = {"unavailable", "provider", "profile", "complete"})
  void unavailableOrDifferentAdapterNeverReadsProviderData(String kind) {
    switch (kind) {
      case "unavailable" -> when(gateway.available()).thenReturn(false);
      case "provider" -> when(gateway.providerCode()).thenReturn("PARTNER");
      case "profile" -> when(gateway.supportsExecutionProfiles()).thenReturn(false);
      case "complete" -> when(gateway.supportsCompletePolicyDocuments()).thenReturn(false);
    }
    rejects("MANAGED_PREPARATION_CONNECTOR_UNAVAILABLE");
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
    verify(gateway, never()).readExecutionProfile(anyString(), anyString());
  }

  @Test
  void revokedAuthorityBeforeCapturePreventsProviderReads() {
    when(bindings.requireVerifiedContext(anyString(), anyString(), anyString(), anyLong()))
        .thenThrow(DomainException.denied());
    assertThatThrownBy(this::prepare).isInstanceOf(DomainException.class);
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
  }

  @Test
  void revokedAuthorityAfterReadCannotReturnPreparedDocument() {
    when(bindings.requireVerifiedContext(anyString(), anyString(), anyString(), anyLong()))
        .thenReturn(binding)
        .thenThrow(DomainException.denied());
    assertThatThrownBy(this::prepare).isInstanceOf(DomainException.class);
    verify(gateway, times(2)).readEnrollmentIdentity("e1", "d1");
  }

  @Test
  void authorityEpochChangeRejectsOtherwiseIdenticalInputs() {
    when(bindings.requireVerifiedContext(anyString(), anyString(), anyString(), anyLong()))
        .thenReturn(binding, binding(2));
    rejects("MANAGED_PREPARATION_CONTEXT_CHANGED");
  }

  @Test
  void publicationChangeRejectsPreparation() {
    when(publications.requireDesiredTarget(
            anyString(), anyString(), anyString(), anyString(), anyString()))
        .thenReturn(desired, desired("v2"));
    rejects("MANAGED_PREPARATION_CONTEXT_CHANGED");
  }

  @Test
  void completeRuleContentChangeIsDetectedEvenIfVersionIsUnchanged() {
    var changed =
        new ManagedDesiredPolicy(
            desired.publication(),
            "device",
            "registration",
            List.of(),
            desired.rules(),
            desired.protectedPackages());
    when(publications.requireDesiredTarget(
            anyString(), anyString(), anyString(), anyString(), anyString()))
        .thenReturn(desired, changed);
    rejects("MANAGED_PREPARATION_CONTEXT_CHANGED");
  }

  @ParameterizedTest
  @ValueSource(strings = {"device", "registration"})
  void publicationMustTargetTheExactCurrentRegistration(String field) {
    var changed =
        new ManagedDesiredPolicy(
            desired.publication(),
            field.equals("device") ? "other" : "device",
            field.equals("registration") ? "other" : "registration",
            desired.applications(),
            desired.rules(),
            desired.protectedPackages());
    when(publications.requireDesiredTarget(
            anyString(), anyString(), anyString(), anyString(), anyString()))
        .thenReturn(changed);
    rejects("MANAGED_PREPARATION_CONTEXT_CHANGED");
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
  }

  @ParameterizedTest
  @ValueSource(strings = {"first", "profile", "last"})
  void providerFailuresAreSanitizedWithoutRetries(String position) {
    var failure = new IllegalStateException("secret-provider-body");
    switch (position) {
      case "first" -> when(gateway.readEnrollmentIdentity("e1", "d1")).thenThrow(failure);
      case "profile" -> when(gateway.readExecutionProfile("e1", "d1")).thenThrow(failure);
      case "last" ->
          when(gateway.readEnrollmentIdentity("e1", "d1"))
              .thenReturn(identity("nonce"))
              .thenThrow(failure);
    }
    rejects("MANAGED_PREPARATION_PROVIDER_UNAVAILABLE");
    verify(gateway, times(position.equals("last") ? 2 : 1)).readEnrollmentIdentity("e1", "d1");
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void invalidFirstEnrollmentSourceStopsFurtherProviderReading() {
    when(gateway.readEnrollmentIdentity("e1", "d1")).thenReturn(identity("foreign-nonce"));
    rejects("EMM_DEVICE_IDENTITY_MISMATCH");
    verify(gateway, never()).readExecutionProfile(anyString(), anyString());
  }

  @Test
  void invalidLastEnrollmentSourceIsRejected() {
    when(gateway.readEnrollmentIdentity("e1", "d1"))
        .thenReturn(identity("nonce"), identity("foreign-nonce"));
    rejects("EMM_DEVICE_IDENTITY_MISMATCH");
  }

  @Test
  void changedProviderIdentityRejectsEvenIndividuallyValidSources() {
    var changed =
        new ManagedAndroidGateway.ManagedEnrollmentIdentity(
            "enterprises/e1/devices/d1",
            "DEVICE_OWNER",
            now.minusSeconds(179).toString(),
            "enterprises/e1/enrollmentTokens/t1",
            "nonce");
    when(gateway.readEnrollmentIdentity("e1", "d1")).thenReturn(identity("nonce"), changed);
    rejects("EMM_DEVICE_IDENTITY_CHANGED");
  }

  @Test
  void missingDeviceProfileIsNotACompiledDocument() {
    when(gateway.readExecutionProfile("e1", "d1")).thenReturn(Optional.empty());
    rejects("MANAGED_DEVICE_PROFILE_MISSING");
  }

  @Test
  void profileReportedBeforeCurrentBindingIsRejected() {
    when(gateway.readExecutionProfile("e1", "d1"))
        .thenReturn(
            Optional.of(
                new ManagedDeviceExecutionProfile(
                    "enterprises/e1/devices/d1",
                    "DEVICE_OWNER",
                    30,
                    "ACTIVE",
                    "ACTIVE",
                    now.minusSeconds(101).toString())));
    rejects("MANAGED_DEVICE_PROFILE_STALE");
  }

  @Test
  void reportCanExpireWhileTheFinalProviderReadRuns() {
    Clock progressing = mock(Clock.class);
    when(progressing.instant()).thenReturn(now, now.plusSeconds(120));
    service =
        new ManagedPolicyPreparationService(
            bindings,
            enrollments,
            publications,
            gateway,
            new ManagedPolicyDocumentCompilers(List.of(new GoogleManagedPolicyDocumentCompiler())),
            new ManagedDeviceProfileSettings(progressing, 600, 120, 15),
            ManagedPreparationTestQualifications.allow(),
            progressing,
            transactions,
            "");
    rejects("MANAGED_DEVICE_PROFILE_STALE");
  }

  @Test
  void newlyProtectedApplicationCannotBeBlockedByAnOlderPublication() {
    service =
        new ManagedPolicyPreparationService(
            bindings,
            enrollments,
            publications,
            gateway,
            new ManagedPolicyDocumentCompilers(List.of(new GoogleManagedPolicyDocumentCompiler())),
            new ManagedDeviceProfileSettings(clock, 600, 120, 15),
            ManagedPreparationTestQualifications.allow(),
            clock,
            transactions,
            " com.example.lesson ");
    Throwable failure = catchThrowable(this::prepare);
    assertThat(failure)
        .as("current protected packages must participate in preparation")
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void expiryDuringCompilationIsRejectedByTheFinalCheck() {
    Clock progressing = mock(Clock.class);
    when(progressing.instant()).thenReturn(now, now.plusSeconds(119), now.plusSeconds(120));
    service =
        new ManagedPolicyPreparationService(
            bindings,
            enrollments,
            publications,
            gateway,
            new ManagedPolicyDocumentCompilers(List.of(new GoogleManagedPolicyDocumentCompiler())),
            new ManagedDeviceProfileSettings(progressing, 600, 120, 15),
            ManagedPreparationTestQualifications.allow(),
            progressing,
            transactions,
            "");
    rejects("MANAGED_DEVICE_PROFILE_STALE");
    verify(progressing, times(3)).instant();
  }

  void rejects(String code) {
    assertThatThrownBy(this::prepare)
        .isInstanceOfSatisfying(
            DomainException.class, error -> assertThat(error.errorCode()).isEqualTo(code))
        .hasNoCause()
        .hasMessageNotContaining("secret-provider-body");
  }

  ManagedPolicyPreparationService.Prepared prepare() {
    return service.prepare("tenant", "actor", "publication", "binding", 1);
  }

  ManagedAgentBindingStore.VerifiedBindingContext binding(long authority) {
    return new ManagedAgentBindingStore.VerifiedBindingContext(
        "tenant",
        "actor",
        authority,
        "subject",
        "device",
        "registration",
        "a".repeat(43),
        "binding",
        1,
        "enrollment",
        1,
        "GOOGLE_AMAPI",
        "e1",
        1,
        "d1",
        "DEVICE_OWNER",
        now.minusSeconds(100).toEpochMilli(),
        "com.aimanager.child",
        "trust-v1",
        Device.Platform.ANDROID,
        now.minusSeconds(120).toEpochMilli());
  }

  ManagedDesiredPolicy desired(String version) {
    return new ManagedDesiredPolicy(
        new ManagedExecutionPublicationAccess.Publication(version, "hash", now.toEpochMilli()),
        "device",
        "registration",
        List.of(
            new ManagedDesiredPolicy.ApplicationIntent(
                "app",
                "com.example.lesson",
                "PRIMARY",
                List.of("a".repeat(64)),
                ManagedAndroidGateway.AppControl.BLOCK_LAUNCH,
                List.of(
                    new ManagedAndroidGateway.RuntimePermissionDecision(
                        "android.permission.CAMERA",
                        ManagedAndroidGateway.PermissionDecision.DENY)),
                List.of("launch", "camera"),
                ManagedPreparationTestQualifications.launchAndCamera())),
        List.of(),
        List.of());
  }

  ManagedAndroidGateway.ManagedEnrollmentIdentity identity(String nonce) {
    return new ManagedAndroidGateway.ManagedEnrollmentIdentity(
        "enterprises/e1/devices/d1",
        "DEVICE_OWNER",
        now.minusSeconds(180).toString(),
        "enterprises/e1/enrollmentTokens/t1",
        nonce);
  }

  static com.google.api.services.androidmanagement.v1.model.Policy googlePolicy(
      ManagedAndroidGateway.PolicyDocument document) {
    return new GoogleCompletePolicyCompiler(document.agentPackage(), Set.of())
        .restore(
            document.documentJson(),
            document.sha256(),
            document.apiLevel(),
            document.managementMode())
        .requestBody();
  }

  void insideTransaction() {
    assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isTrue();
    assertThat(TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())
        .isEqualTo(TransactionDefinition.ISOLATION_READ_COMMITTED);
  }

  void outsideTransaction() {
    assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
  }
}
