package com.aimanager.policy.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.CapabilityView;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.FleetPolicyAccess;
import com.aimanager.policy.PolicyRule;
import com.aimanager.shared.DomainException;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** Existing capability boundaries must survive the target application identity restriction. */
class RuleCompilerCapabilityBoundaryTest {
  private final RuleCompiler compiler = new RuleCompiler("");

  @Test
  void supportedDomainRuleDoesNotRequireApplicationEvidence() {
    var rule =
        new PolicyRule(
            "domain-rule",
            PolicyRule.Kind.DOMAIN_ACCESS,
            PolicyRule.Effect.DENY,
            true,
            null,
            null,
            null,
            null,
            "example.invalid");

    var evaluation =
        compiler.compile(List.of(rule), Map.of(), target("network.domain_filter")).get(0);

    assertThat(evaluation.status()).isEqualTo("SUPPORTED_PENDING");
    assertThat(evaluation.reasonCode()).isEqualTo("AWAITING_EXECUTION");
    assertThat(evaluation.effectiveEffect()).isNull();
  }

  @Test
  void savedDomainRulesRemainCanonicalWhenTheNormalizerIsShared() {
    for (String domain : List.of("example.invalid", "xn--bcher-kva.example")) {
      compiler.validate(List.of(domainRule(domain)), Map.of());
    }
    for (String domain : List.of("EXAMPLE.invalid", "bücher.example")) {
      assertThatThrownBy(() -> compiler.validate(List.of(domainRule(domain)), Map.of()))
          .isInstanceOf(DomainException.class).hasMessage("DOMAIN_NOT_CANONICAL");
    }
    for (String domain : List.of(" example.invalid ", "https://example.invalid", "127.0.0.1",
        "example.invalid.", "*.example.invalid")) {
      assertThatThrownBy(() -> compiler.validate(List.of(domainRule(domain)), Map.of()))
          .isInstanceOf(DomainException.class).hasMessage("INVALID_DOMAIN");
    }
  }

  private static PolicyRule domainRule(String domain) {
    return new PolicyRule("domain-rule", PolicyRule.Kind.DOMAIN_ACCESS, PolicyRule.Effect.DENY,
        true, null, null, null, null, domain);
  }

  @Test
  void applicationEvidenceCannotEnableAutomaticRuntimePermissionGrant() {
    var application =
        new ApplicationDefinition(
            "app",
            "Fixture app",
            Device.Platform.ANDROID,
            "example.learning.app",
            ApplicationDefinition.Profile.PRIMARY,
            List.of("a".repeat(64)),
            "INSTALLED_VERIFIED");
    var rule =
        new PolicyRule(
            "grant-rule",
            PolicyRule.Kind.RUNTIME_PERMISSION,
            PolicyRule.Effect.GRANT,
            true,
            "app",
            null,
            null,
            "android.permission.CAMERA",
            null);

    var evaluation =
        compiler
            .compile(List.of(rule), Map.of("app", application), target("permission.runtime"))
            .get(0);

    assertThat(evaluation.status()).isEqualTo("UNSUPPORTED");
    assertThat(evaluation.reasonCode()).isEqualTo("AUTO_GRANT_NOT_AVAILABLE");
    assertThat(evaluation.effectiveEffect()).isNull();
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {"registration", "different-registration"})
  void verifiedIdentityStillCannotEstablishProfileOrExecution(String registration) {
    var app =
        new ApplicationDefinition(
            "app",
            "Reader",
            Device.Platform.ANDROID,
            "org.example.reader",
            ApplicationDefinition.Profile.PRIMARY,
            List.of("a".repeat(64)),
            "ADMIN_DECLARED");
    var rule =
        new PolicyRule(
            "launch",
            PolicyRule.Kind.APP_LAUNCH,
            PolicyRule.Effect.DENY,
            true,
            "app",
            null,
            null,
            null,
            null);
    var fact =
        new com.aimanager.managedandroid.ManagedPolicyEvidenceAccess.ApplicationEvidence(
            "device",
            registration,
            "app",
            "binding",
            2,
            "revision",
            2,
            "VERIFIED_IDENTITY",
            "MANAGED_APPLICATION_PROFILE_UNVERIFIED",
            "UNKNOWN",
            false,
            1000L,
            1000L,
            2000L);
    var result =
        compiler
            .compile(List.of(rule), Map.of("app", app), target("app.launch_block"), List.of(fact))
            .get(0);
    assertThat(result.status()).isEqualTo("UNVERIFIED");
    assertThat(result.reasonCode())
        .isEqualTo(
            registration.equals("registration")
                ? "APPLICATION_PROFILE_NOT_VERIFIED"
                : "APPLICATION_IDENTITY_NOT_VERIFIED");
    assertThat(result.effectiveEffect()).isNull();
  }

  private static FleetPolicyAccess.Target target(String capabilityKey) {
    var device =
        new Device(
            "device",
            "student",
            "registration",
            "Fixture tablet",
            Device.Platform.ANDROID,
            "14",
            Device.State.ACTIVE,
            "FULLY_MANAGED",
            "MANAGED",
            1000L,
            "RECENT",
            "fixture-key-thumbprint",
            1L);
    var capability =
        new CapabilityView(
            capabilityKey, true, "GRANTED", "PROVIDER", 1000L, "SUPPORTED", true, null);
    return new FleetPolicyAccess.Target(device, List.of(capability));
  }
}
