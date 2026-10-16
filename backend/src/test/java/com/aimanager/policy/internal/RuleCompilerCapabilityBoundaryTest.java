package com.aimanager.policy.internal;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.CapabilityView;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.FleetPolicyAccess;
import com.aimanager.policy.PolicyRule;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/** Existing capability boundaries must survive the target application identity restriction. */
class RuleCompilerCapabilityBoundaryTest {
  private final RuleCompiler compiler = new RuleCompiler("");

  @Test
  void supportedDomainRuleDoesNotRequireApplicationEvidence() {
    var rule = new PolicyRule(
        "domain-rule", PolicyRule.Kind.DOMAIN_ACCESS, PolicyRule.Effect.DENY,
        true, null, null, null, null, "example.invalid");

    var evaluation = compiler.compile(
        List.of(rule), Map.of(), target("network.domain_filter")).get(0);

    assertThat(evaluation.status()).isEqualTo("SUPPORTED_PENDING");
    assertThat(evaluation.reasonCode()).isEqualTo("AWAITING_EXECUTION");
    assertThat(evaluation.effectiveEffect()).isNull();
  }

  @Test
  void applicationEvidenceCannotEnableAutomaticRuntimePermissionGrant() {
    var application = new ApplicationDefinition(
        "app", "Fixture app", Device.Platform.ANDROID, "example.learning.app",
        ApplicationDefinition.Profile.PRIMARY, List.of("a".repeat(64)), "INSTALLED_VERIFIED");
    var rule = new PolicyRule(
        "grant-rule", PolicyRule.Kind.RUNTIME_PERMISSION, PolicyRule.Effect.GRANT,
        true, "app", null, null, "android.permission.CAMERA", null);

    var evaluation = compiler.compile(
        List.of(rule), Map.of("app", application), target("permission.runtime")).get(0);

    assertThat(evaluation.status()).isEqualTo("UNSUPPORTED");
    assertThat(evaluation.reasonCode()).isEqualTo("AUTO_GRANT_NOT_AVAILABLE");
    assertThat(evaluation.effectiveEffect()).isNull();
  }

  private static FleetPolicyAccess.Target target(String capabilityKey) {
    var device = new Device(
        "device", "student", "registration", "Fixture tablet", Device.Platform.ANDROID,
        "14", Device.State.ACTIVE, "FULLY_MANAGED", "MANAGED", 1000L, "RECENT",
        "fixture-key-thumbprint", 1L);
    var capability = new CapabilityView(
        capabilityKey, true, "GRANTED", "PROVIDER", 1000L, "SUPPORTED", true, null);
    return new FleetPolicyAccess.Target(device, List.of(capability));
  }
}
