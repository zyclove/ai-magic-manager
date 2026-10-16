package com.aimanager.policy.internal;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.CapabilityView;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.FleetPolicyAccess;
import com.aimanager.policy.PolicyRule;
import com.aimanager.policy.PolicySnapshot;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * Stage 4 regression: a catalog claim is not evidence for a device registration.
 * These pure compiler cases use no provider credentials or device writes.
 */
class TargetApplicationEvidenceTest {
  private static final String APPLICATION_ID = "0c9b33b3-bb8d-4c60-85e7-95744a16e27e";
  private final RuleCompiler compiler = new RuleCompiler("");

  @Test
  void catalogVerificationCannotCertifyDifferentDevices() {
    var application = application("INSTALLED_VERIFIED");

    var evaluations =
        List.of(
            compile(application, target("device-a", "registration-a")),
            compile(application, target("device-b", "registration-b")));
    assertThat(evaluations).allSatisfy(TargetApplicationEvidenceTest::assertUnverified);
  }

  @Test
  void catalogVerificationCannotSurviveDeviceReregistration() {
    var application = application("INSTALLED_VERIFIED");

    assertUnverified(compile(application, target("device-a", "new-registration")));
  }

  @Test
  void declaredCatalogIdentityRemainsUnverified() {
    assertUnverified(
        compile(application("ADMIN_DECLARED"), target("device-a", "registration-a")));
  }

  @Test
  void absentApplicationEvidenceDoesNotHideARevokedDevice() {
    var active = target("device-a", "registration-a");
    var device = active.device();
    var revoked =
        new Device(
            device.id(), device.subjectId(), device.registrationId(), device.displayName(),
            device.platform(), device.osVersion(), Device.State.REVOKED,
            device.managementMode(), device.controlLevel(), device.lastHeartbeatAt(),
            device.observationStatus(), device.keyThumbprint(), device.version() + 1);

    var evaluation =
        compile(
            application("INSTALLED_VERIFIED"),
            new FleetPolicyAccess.Target(revoked, active.capabilities()));

    assertThat(evaluation.status()).isEqualTo("UNAVAILABLE");
    assertThat(evaluation.reasonCode()).isEqualTo("DEVICE_NOT_ACTIVE");
  }

  private PolicySnapshot.RuleEvaluation compile(
      ApplicationDefinition application, FleetPolicyAccess.Target target) {
    var rule =
        new PolicyRule(
            "block-app", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY,
            true, APPLICATION_ID, null, null, null, null);
    return compiler.compile(List.of(rule), Map.of(APPLICATION_ID, application), target).get(0);
  }

  private static void assertUnverified(PolicySnapshot.RuleEvaluation evaluation) {
    assertThat(evaluation.status()).isEqualTo("UNVERIFIED");
    assertThat(evaluation.reasonCode()).isEqualTo("APPLICATION_IDENTITY_NOT_VERIFIED");
    assertThat(evaluation.effectiveEffect()).isNull();
  }

  private static ApplicationDefinition application(String catalogStatus) {
    return new ApplicationDefinition(
        APPLICATION_ID, "Fixture learning app", Device.Platform.ANDROID,
        "example.learning.app", ApplicationDefinition.Profile.PRIMARY,
        List.of("a".repeat(64)), catalogStatus);
  }

  private static FleetPolicyAccess.Target target(String deviceId, String registrationId) {
    var device =
        new Device(
            deviceId, "student-a", registrationId, "Fixture tablet", Device.Platform.ANDROID,
            "14", Device.State.ACTIVE, "FULLY_MANAGED", "MANAGED", 1000L, "RECENT",
            "fixture-key-thumbprint", 1L);
    var capability =
        new CapabilityView(
            "app.launch_block", true, "GRANTED", "PROVIDER", 1000L,
            "SUPPORTED", true, null);
    return new FleetPolicyAccess.Target(device, List.of(capability));
  }
}
