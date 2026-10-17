package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.*;
import com.aimanager.shared.DomainException;
import java.time.*;
import java.util.*;
import org.junit.jupiter.api.Test;

class ManagedApplicationControlEvaluatorTest {
  final Instant now = Instant.parse("2026-10-17T04:00:00Z");
  final Clock clock = Clock.fixed(now, ZoneOffset.UTC);
  final ManagedAndroidGateway gateway = mock(ManagedAndroidGateway.class);
  final ManagedPolicyDocumentCompiler compiler = mock(ManagedPolicyDocumentCompiler.class);
  final ManagedControlOperation operation =
      new ManagedControlOperation(
          ManagedControlOperation.Kind.APP_LAUNCH, ManagedControlOperation.Effect.DENY, null);

  @Test
  void reviewedPrimaryControlCanBeAdmitted() throws Exception {
    var evaluator = evaluator();
    var checked = verify(evaluator, report("reviewed-model"));
    assertThat(checked.operations()).containsExactly(operation);
    assertThat(checked.expiresAt()).isEqualTo(now.plusSeconds(10));
  }

  @Test
  void aDifferentModelCannotBorrowAReviewedDevicesControls() throws Exception {
    var evaluator = evaluator();
    assertThatThrownBy(() -> verify(evaluator, report("unreviewed-model")))
        .isInstanceOfSatisfying(
            DomainException.class,
            e -> assertThat(e.errorCode()).isEqualTo("MANAGED_CONTROL_QUALIFICATION_REQUIRED"));
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(strings = {"WORK", "SECONDARY", "UNKNOWN", ""})
  void unprovenUserSpaceCannotBorrowPrimaryUserControl(String scope) {
    var evaluator = evaluator();
    var r = report("reviewed-model");
    var changed =
        new ManagedApplicationControlReport(
            r.identity(), r.device(), scope, r.manufacturer(), r.model(), r.osBuild());
    assertThatThrownBy(() -> verify(evaluator, changed)).isInstanceOf(DomainException.class);
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {"manufacturer", "build", "api", "mode", "device", "state", "reportTime"})
  void factsMustMatchTheExactReviewedDevice(String field) {
    var evaluator = evaluator();
    var r = report("reviewed-model");
    var d = r.device();
    var changedDevice =
        new ManagedDeviceExecutionProfile(
            field.equals("device") ? "enterprises/e1/devices/other" : d.deviceName(),
            field.equals("mode") ? "PROFILE_OWNER" : d.managementMode(),
            field.equals("api") ? 31 : d.apiLevel(),
            field.equals("state") ? "DISABLED" : d.state(),
            d.appliedState(),
            field.equals("reportTime")
                ? now.minusSeconds(11).toString()
                : d.lastStatusReportTime());
    var changed =
        new ManagedApplicationControlReport(
            r.identity(),
            changedDevice,
            r.profileScope(),
            field.equals("manufacturer") ? "another-maker" : r.manufacturer(),
            r.model(),
            field.equals("build") ? "another-build" : r.osBuild());
    assertThatThrownBy(() -> verify(evaluator, changed)).isInstanceOf(DomainException.class);
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {"provider", "revision", "available", "support"})
  void changedConnectorCannotUseExistingQualification(String field) {
    var evaluator = evaluator();
    switch (field) {
      case "provider" -> when(gateway.providerCode()).thenReturn("OTHER_PARTNER");
      case "revision" ->
          when(gateway.applicationControlReportRevision()).thenReturn("control-report-v2");
      case "available" -> when(gateway.available()).thenReturn(false);
      case "support" -> when(gateway.supportsApplicationControlReports()).thenReturn(false);
    }
    assertThatThrownBy(() -> verify(evaluator, report("reviewed-model")))
        .isInstanceOf(DomainException.class);
  }

  @Test
  void storedControlIsBoundedStrictAndCannotExtendEvidenceLifetime() {
    var evaluator = evaluator();
    var report = report("reviewed-model");
    var identity = identity(report);
    var checked = verify(evaluator, report);
    String stored = evaluator.store(report, now, checked);
    assertThat(evaluator.restore(gateway, identity, stored)).isEqualTo(checked);
    assertThatThrownBy(() -> evaluator.restore(gateway, identity, stored + " {}"))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(
            () ->
                evaluator.restore(
                    gateway,
                    identity,
                    stored.replace(
                        "\"schemaVersion\":1", "\"schemaVersion\":1,\"schemaVersion\":1")))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(
            () ->
                evaluator.restore(
                    gateway,
                    identity,
                    stored.replace(
                        Long.toString(checked.expiresAt().toEpochMilli()),
                        Long.toString(now.plusSeconds(11).toEpochMilli()))))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(() -> evaluator.restore(gateway, identity, " ".repeat(16385)))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(() -> checked.operations().clear())
        .isInstanceOf(UnsupportedOperationException.class);
  }

  @Test
  void emptyQualificationCatalogCannotAuthorizeAnyModel() {
    var evaluator = evaluator(List.of());
    assertThatThrownBy(() -> verify(evaluator, report("reviewed-model")))
        .isInstanceOfSatisfying(
            DomainException.class,
            e -> assertThat(e.errorCode()).isEqualTo("MANAGED_CONTROL_QUALIFICATION_REQUIRED"));
  }

  @Test
  void duplicateHardwareQualificationsFailConfiguration() {
    var q = qualification();
    assertThatThrownBy(() -> evaluator(List.of(q, q))).isInstanceOf(IllegalArgumentException.class);
    var other =
        new ManagedControlQualification(
            "other-id",
            q.revision(),
            q.provider(),
            q.reportAdapterRevision(),
            q.compilerRevision(),
            q.manufacturer(),
            q.model(),
            q.osBuild(),
            q.apiLevel(),
            q.managementMode(),
            q.validFrom(),
            q.validUntil(),
            q.acceptanceReference(),
            q.operations());
    assertThatThrownBy(() -> evaluator(List.of(q, other)))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {
        "empty",
        "duplicate",
        "runtimeAllow",
        "permissionWildcard",
        "launchPermission",
        "launchDefault"
      })
  void invalidOrBroadOperationsCannotEnterTheCatalog(String variation) {
    var q = qualification();
    List<ManagedControlOperation> ops =
        switch (variation) {
          case "empty" -> List.of();
          case "duplicate" -> List.of(operation, operation);
          case "runtimeAllow" ->
              List.of(
                  new ManagedControlOperation(
                      ManagedControlOperation.Kind.RUNTIME_PERMISSION,
                      ManagedControlOperation.Effect.ALLOW,
                      "android.permission.CAMERA"));
          case "permissionWildcard" ->
              List.of(
                  new ManagedControlOperation(
                      ManagedControlOperation.Kind.RUNTIME_PERMISSION,
                      ManagedControlOperation.Effect.DENY,
                      "android.permission.*"));
          case "launchPermission" ->
              List.of(
                  new ManagedControlOperation(
                      ManagedControlOperation.Kind.APP_LAUNCH,
                      ManagedControlOperation.Effect.DENY,
                      "android.permission.CAMERA"));
          default ->
              List.of(
                  new ManagedControlOperation(
                      ManagedControlOperation.Kind.APP_LAUNCH,
                      ManagedControlOperation.Effect.DEFAULT,
                      null));
        };
    var invalid =
        new ManagedControlQualification(
            q.id(),
            q.revision(),
            q.provider(),
            q.reportAdapterRevision(),
            q.compilerRevision(),
            q.manufacturer(),
            q.model(),
            q.osBuild(),
            q.apiLevel(),
            q.managementMode(),
            q.validFrom(),
            q.validUntil(),
            q.acceptanceReference(),
            ops);
    assertThatThrownBy(() -> evaluator(List.of(invalid)))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(strings = {"future", "expired"})
  void qualificationTimeWindowIsEnforcedAtItsExactBoundary(String variation) {
    var q = qualification();
    var bounded =
        new ManagedControlQualification(
            q.id(),
            q.revision(),
            q.provider(),
            q.reportAdapterRevision(),
            q.compilerRevision(),
            q.manufacturer(),
            q.model(),
            q.osBuild(),
            q.apiLevel(),
            q.managementMode(),
            variation.equals("future") ? now.plusSeconds(1) : q.validFrom(),
            variation.equals("expired") ? now : q.validUntil(),
            q.acceptanceReference(),
            q.operations());
    var evaluator = evaluator(List.of(bounded));
    assertThatThrownBy(() -> verify(evaluator, report("reviewed-model")))
        .isInstanceOfSatisfying(
            DomainException.class,
            e -> assertThat(e.errorCode()).isEqualTo("MANAGED_CONTROL_QUALIFICATION_EXPIRED"));
  }

  @Test
  void compilerSemanticsCannotChangeInsideAnExistingRegistry() {
    var evaluator = evaluator();
    when(compiler.adapterRevision()).thenReturn("different-policy-v2");
    assertThatThrownBy(() -> verify(evaluator, report("reviewed-model")))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void qualificationRevisionChangesTheContextFingerprint() {
    var evaluator = evaluator();
    String original = evaluator.revision(gateway);
    var q = qualification();
    var changed =
        new ManagedControlQualification(
            q.id(),
            "review-v2",
            q.provider(),
            q.reportAdapterRevision(),
            q.compilerRevision(),
            q.manufacturer(),
            q.model(),
            q.osBuild(),
            q.apiLevel(),
            q.managementMode(),
            q.validFrom(),
            q.validUntil(),
            q.acceptanceReference(),
            q.operations());
    assertThat(evaluator(List.of(changed)).revision(gateway)).isNotEqualTo(original);
    when(gateway.supportsApplicationControlReports()).thenReturn(false);
    assertThat(evaluator.revision(gateway)).isEqualTo("identity-only-v1");
  }

  ManagedApplicationControlEvaluator evaluator() {
    return evaluator(List.of(qualification()));
  }

  ManagedApplicationControlEvaluator evaluator(List<ManagedControlQualification> qualifications) {
    when(gateway.available()).thenReturn(true);
    when(gateway.providerCode()).thenReturn("LOCAL_PARTNER");
    when(gateway.supportsApplicationControlReports()).thenReturn(true);
    when(gateway.applicationControlReportRevision()).thenReturn("control-report-v1");
    when(compiler.providerCode()).thenReturn("LOCAL_PARTNER");
    when(compiler.adapterRevision()).thenReturn("local-policy-v1");
    return new ManagedApplicationControlEvaluator(
        qualifications,
        new ManagedPolicyDocumentCompilers(List.of(compiler)),
        new ManagedDeviceProfileSettings(clock, 600, 120, 15),
        clock);
  }

  ManagedControlQualification qualification() {
    return new ManagedControlQualification(
        "local-acceptance",
        "review-v1",
        "LOCAL_PARTNER",
        "control-report-v1",
        "local-policy-v1",
        "fixture-maker",
        "reviewed-model",
        "reviewed-build",
        30,
        "DEVICE_OWNER",
        now.minusSeconds(60),
        now.plusSeconds(10),
        "fixture-acceptance-only",
        List.of(operation));
  }

  ManagedApplicationControlReport report(String model) {
    return new ManagedApplicationControlReport(
        new ManagedApplicationReport(
            "enterprises/e1/devices/d1",
            "DEVICE_OWNER",
            "org.example.Reader",
            "INSTALLED",
            List.of("a".repeat(64)),
            now.minusSeconds(10).toString()),
        new ManagedDeviceExecutionProfile(
            "enterprises/e1/devices/d1",
            "DEVICE_OWNER",
            30,
            "ACTIVE",
            "ACTIVE",
            now.minusSeconds(10).toString()),
        "PRIMARY",
        "fixture-maker",
        model,
        "reviewed-build");
  }

  ManagedApplicationControlEvaluator.Checked verify(
      ManagedApplicationControlEvaluator evaluator, ManagedApplicationControlReport report) {
    return evaluator.verify(gateway, identity(report), report, now);
  }

  ManagedApplicationIdentityVerifier.Verified identity(ManagedApplicationControlReport report) {
    var scope =
        new ManagedApplicationIdentityVerifier.Scope(
            "tenant",
            "device",
            "registration",
            "k".repeat(43),
            "binding",
            2,
            "LOCAL_PARTNER",
            "enterprises/e1/devices/d1",
            1,
            "identity-report-v1");
    var context =
        new ManagedApplicationIdentityVerifier.Context(
            scope,
            "application",
            "b".repeat(64),
            "org.example.Reader",
            Set.of("a".repeat(64)),
            "DEVICE_OWNER",
            now.minusSeconds(50),
            true);
    return new ManagedApplicationIdentityVerifier(
            clock, Duration.ofSeconds(600), Duration.ofSeconds(120), Duration.ofSeconds(15))
        .verify(context, context, report.identity(), now);
  }
}
