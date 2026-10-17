package com.aimanager.policy.internal;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.*;
import com.aimanager.managedandroid.*;
import com.aimanager.managedandroid.ManagedPolicyEvidenceAccess.ApplicationEvidence;
import com.aimanager.policy.PolicyRule;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class ReviewedApplicationRuleTest {
  final RuleCompiler compiler = new RuleCompiler("");
  final ManagedControlOperation launch =
      new ManagedControlOperation(
          ManagedControlOperation.Kind.APP_LAUNCH, ManagedControlOperation.Effect.DENY, null);
  final PolicyRule rule =
      new PolicyRule(
          "reader",
          PolicyRule.Kind.APP_LAUNCH,
          PolicyRule.Effect.DENY,
          true,
          "app",
          null,
          null,
          null,
          null);
  final ApplicationDefinition app =
      new ApplicationDefinition(
          "app",
          "Reader",
          Device.Platform.ANDROID,
          "org.example.Reader",
          ApplicationDefinition.Profile.PRIMARY,
          List.of("a".repeat(64)),
          "ADMIN_DECLARED");

  @Test
  void reviewedOperationDoesNotDependOnAnUntrustedAgentClaim() {
    var result =
        compiler
            .compile(
                List.of(rule),
                Map.of("app", app),
                target(),
                List.of(fact("valid", List.of(launch))))
            .get(0);
    assertThat(result.status()).isEqualTo("SUPPORTED_PENDING");
    assertThat(result.reasonCode()).isEqualTo("AWAITING_EXECUTION");
    assertThat(result.effectiveEffect()).isNull();
  }

  @Test
  void controlScopeCannotExpandToAnotherOperation() {
    var install =
        new ManagedControlOperation(
            ManagedControlOperation.Kind.APP_INSTALL, ManagedControlOperation.Effect.DENY, null);
    var result =
        compiler
            .compile(
                List.of(rule),
                Map.of("app", app),
                target(),
                List.of(fact("valid", List.of(install))))
            .get(0);
    assertThat(result.status()).isEqualTo("UNVERIFIED");
    assertThat(result.reasonCode()).isEqualTo("APPLICATION_CONTROL_OPERATION_NOT_VERIFIED");
    assertThat(result.effectiveEffect()).isNull();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "device",
        "registration",
        "application",
        "state",
        "profile",
        "flag",
        "binding",
        "version",
        "revision",
        "expires",
        "empty",
        "duplicate"
      })
  void mismatchedOrIncompleteFactsCannotAuthorizeAControl(String variant) {
    var fact = fact(variant, variant.equals("empty") ? List.of() : List.of(launch));
    var facts = variant.equals("duplicate") ? List.of(fact, fact) : List.of(fact);
    var result = compiler.compile(List.of(rule), Map.of("app", app), target(), facts).get(0);
    assertThat(result.status()).isNotEqualTo("SUPPORTED_PENDING");
    assertThat(result.effectiveEffect()).isNull();
  }

  @Test
  void cameraDenyDoesNotApproveMicrophoneOrAutomaticGrants() {
    var camera =
        new ManagedControlOperation(
            ManagedControlOperation.Kind.RUNTIME_PERMISSION,
            ManagedControlOperation.Effect.DENY,
            "android.permission.CAMERA");
    for (String permission :
        List.of("android.permission.CAMERA", "android.permission.RECORD_AUDIO")) {
      var deny =
          new PolicyRule(
              "permission",
              PolicyRule.Kind.RUNTIME_PERMISSION,
              PolicyRule.Effect.DENY,
              true,
              "app",
              null,
              null,
              permission,
              null);
      var result =
          compiler
              .compile(
                  List.of(deny),
                  Map.of("app", app),
                  target(),
                  List.of(fact("valid", List.of(camera))))
              .get(0);
      assertThat(result.status())
          .isEqualTo(permission.endsWith("CAMERA") ? "SUPPORTED_PENDING" : "UNVERIFIED");
      assertThat(result.effectiveEffect()).isNull();
    }
    var grant =
        new PolicyRule(
            "permission",
            PolicyRule.Kind.RUNTIME_PERMISSION,
            PolicyRule.Effect.GRANT,
            true,
            "app",
            null,
            null,
            "android.permission.CAMERA",
            null);
    var result =
        compiler
            .compile(
                List.of(grant),
                Map.of("app", app),
                target(),
                List.of(fact("valid", List.of(camera))))
            .get(0);
    assertThat(result.reasonCode()).isEqualTo("AUTO_GRANT_NOT_AVAILABLE");
  }

  @Test
  void revokedDeviceStillWinsOverQualifiedControl() {
    var d = target().device();
    var revoked =
        new Device(
            d.id(),
            d.subjectId(),
            d.registrationId(),
            d.displayName(),
            d.platform(),
            d.osVersion(),
            Device.State.REVOKED,
            d.managementMode(),
            d.controlLevel(),
            d.lastHeartbeatAt(),
            d.observationStatus(),
            d.keyThumbprint(),
            2L);
    var result =
        compiler
            .compile(
                List.of(rule),
                Map.of("app", app),
                new FleetPolicyAccess.Target(revoked, List.of()),
                List.of(fact("valid", List.of(launch))))
            .get(0);
    assertThat(result.status()).isEqualTo("UNAVAILABLE");
    assertThat(result.reasonCode()).isEqualTo("DEVICE_NOT_ACTIVE");
  }

  ApplicationEvidence fact(String variant, List<ManagedControlOperation> operations) {
    return new ApplicationEvidence(
        variant.equals("device") ? "other-device" : "device",
        variant.equals("registration") ? "other-registration" : "registration",
        variant.equals("application") ? "other-app" : "app",
        variant.equals("binding") ? null : "binding",
        2,
        variant.equals("revision") ? "invalid" : "b".repeat(64),
        variant.equals("version") ? 0 : 2,
        variant.equals("state") ? "STALE" : "VERIFIED_IDENTITY",
        "MANAGED_APPLICATION_CONTROL_VERIFIED",
        variant.equals("profile") ? "WORK" : "PRIMARY",
        !variant.equals("flag"),
        1000L,
        1000L,
        variant.equals("expires") ? 1000L : 2000L,
        operations);
  }

  FleetPolicyAccess.Target target() {
    return new FleetPolicyAccess.Target(
        new Device(
            "device",
            "student",
            "registration",
            "Tablet",
            Device.Platform.ANDROID,
            "14",
            Device.State.ACTIVE,
            "FULLY_MANAGED",
            "MANAGED",
            1000L,
            "RECENT",
            "fixture-key",
            1L),
        List.of());
  }
}
