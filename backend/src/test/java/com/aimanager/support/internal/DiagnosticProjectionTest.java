package com.aimanager.support.internal;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.delivery.DeliveryDiagnosticSource;
import com.aimanager.fleet.*;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import org.junit.jupiter.api.Test;

class DiagnosticProjectionTest {
  static final String TENANT = "11111111-1111-1111-1111-111111111111";
  static final String DEVICE = "22222222-2222-2222-2222-222222222222";
  static final String REGISTRATION = "33333333-3333-3333-3333-333333333333";
  static final String POLICY = "44444444-4444-4444-4444-444444444444";
  static final String VERSION = "55555555-5555-5555-5555-555555555555";
  static final String DELIVERY = "66666666-6666-6666-6666-666666666666";
  static final String CORRELATION = "77777777-7777-7777-7777-777777777777";
  static final long NOW = 1791600000000L;
  final ObjectMapper json = new ObjectMapper();
  final DiagnosticProjection projection = new DiagnosticProjection();

  FleetDiagnosticSource.Snapshot fleet(String os, String agent, List<CapabilityView> capabilities) {
    var device =
        new Device(
            DEVICE,
            "child-private-subject",
            REGISTRATION,
            "CHILD_PRIVATE_TEXT",
            Device.Platform.ANDROID,
            os,
            Device.State.ACTIVE,
            "BYOD",
            "COMPANION",
            NOW - 1000,
            "ONLINE",
            "SECRET_KEY_THUMBPRINT",
            2);
    return new FleetDiagnosticSource.Snapshot(device, agent, capabilities);
  }

  CapabilityView capability(String key, String grant) {
    return new CapabilityView(
        key, true, grant, "AGENT_REPORT", NOW - 500, "UNVERIFIED", false, "EVIDENCE_NOT_CERTIFIED");
  }

  DeliveryDiagnosticSource.Item item(String error, String hash) {
    return new DeliveryDiagnosticSource.Item(
        DELIVERY,
        POLICY,
        VERSION,
        1,
        "UPSERT_CONFIGURATION",
        "DEVICE_REPORTED_REJECTED",
        hash,
        NOW - 10000,
        NOW + 10000,
        NOW - 8000,
        null,
        error);
  }

  DiagnosticProjection.Document project(
      FleetDiagnosticSource.Snapshot fleet,
      List<DeliveryDiagnosticSource.Item> deliveries,
      Map<String, String> hashes) {
    return projection.project(TENANT, fleet, deliveries, hashes, NOW, CORRELATION, "0.1.0");
  }

  @Test
  void outputsOnlyExplicitFieldsAndNeverSerializesDeviceOrUnknownCapabilityText() throws Exception {
    var result =
        project(
            fleet(
                "14",
                "1.2.3",
                List.of(
                    capability("usage.report", "GRANTED"),
                    capability("child.private.text", "GRANTED"))),
            List.of(item("STORAGE_FAILURE", "a".repeat(64))),
            Map.of(VERSION, "b".repeat(64)));
    var tree = json.valueToTree(result);
    var names = new HashSet<String>();
    tree.fieldNames().forEachRemaining(names::add);
    assertThat(names)
        .containsExactlyInAnyOrder(
            "schemaVersion",
            "generatedAt",
            "correlationId",
            "scope",
            "versions",
            "device",
            "capabilities",
            "omittedCapabilityCount",
            "configurations",
            "evidenceStatus");
    assertThat(tree.path("scope").size()).isEqualTo(3);
    assertThat(tree.path("scope").path("registrationId").asText()).isEqualTo(REGISTRATION);
    assertThat(tree.path("versions").path("agent").path("value").asText()).isEqualTo("1.2.3");
    assertThat(tree.path("capabilities").size()).isEqualTo(1);
    assertThat(tree.path("omittedCapabilityCount").asInt()).isEqualTo(1);
    assertThat(tree.path("configurations").get(0).path("policyHash").asText())
        .isEqualTo("b".repeat(64));
    assertThat(json.writeValueAsString(result))
        .doesNotContain(
            "CHILD_PRIVATE_TEXT",
            "child-private-subject",
            "SECRET_KEY_THUMBPRINT",
            "child.private.text",
            "displayName",
            "publicKey",
            "compactJws",
            "documentJson");
  }

  @Test
  void rejectsFreeTextVersionsRatherThanKeepingAnApparentlyValidPrefix() throws Exception {
    var result =
        project(
            fleet(
                "14 https://private.example/path?token=SECRET",
                "1.2.3 CHILD_PRIVATE_TEXT",
                List.of()),
            List.of(),
            Map.of());
    var tree = json.valueToTree(result);
    assertThat(tree.path("versions").path("os").path("value").isNull()).isTrue();
    assertThat(tree.path("versions").path("os").path("status").asText()).isEqualTo("REDACTED");
    assertThat(tree.path("versions").path("agent").path("status").asText()).isEqualTo("REDACTED");
    assertThat(json.writeValueAsString(result))
        .doesNotContain("SECRET", "private.example", "CHILD_PRIVATE_TEXT");
    var absent = json.valueToTree(project(fleet(null, null, List.of()), List.of(), Map.of()));
    assertThat(absent.path("versions").path("agent").path("status").asText())
        .isEqualTo("UNREPORTED");
  }

  @Test
  void unknownErrorGrantStateAndHashesNeverEchoUntrustedStrings() throws Exception {
    var caps =
        List.of(
            new CapabilityView(
                "usage.report",
                true,
                "SECRET_GRANT",
                "SECRET_SOURCE",
                NOW,
                "SECRET_STATUS",
                true,
                "SECRET_REASON"));
    var result =
        project(
            fleet("14", "1.0.0", caps),
            List.of(item("SECRET_ERROR", "SECRET_HASH")),
            Map.of(VERSION, "SECRET_POLICY"));
    var tree = json.valueToTree(result);
    assertThat(tree.path("capabilities").get(0).path("grantStatus").asText()).isEqualTo("UNKNOWN");
    assertThat(tree.path("configurations").get(0).path("rejectionCode").asText())
        .isEqualTo("UNKNOWN_REJECTION");
    assertThat(tree.path("configurations").get(0).path("policyHash").isNull()).isTrue();
    assertThat(json.writeValueAsString(result)).doesNotContain("SECRET", "effectiveSupported");
  }

  @Test
  void overCapacityIsRejectedRatherThanSilentlyTruncated() {
    assertThatThrownBy(
            () ->
                project(
                    fleet(
                        "14",
                        "1.0",
                        Collections.nCopies(71, capability("usage.report", "GRANTED"))),
                    List.of(),
                    Map.of()))
        .isInstanceOf(DomainException.class)
        .hasMessage("DIAGNOSTIC_TOO_LARGE");
    assertThatThrownBy(
            () ->
                project(
                    fleet("14", "1.0", List.of()),
                    Collections.nCopies(101, item(null, null)),
                    Map.of()))
        .isInstanceOf(DomainException.class)
        .hasMessage("DIAGNOSTIC_TOO_LARGE");
  }

  @Test
  void malformedScopeAndCorrelationIdentifiersFailClosed() {
    assertThatThrownBy(
            () ->
                projection.project(
                    "other/tenant",
                    fleet("14", "1.0", List.of()),
                    List.of(),
                    Map.of(),
                    NOW,
                    CORRELATION,
                    null))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(
            () ->
                projection.project(
                    TENANT,
                    fleet("14", "1.0", List.of()),
                    List.of(),
                    Map.of(),
                    NOW,
                    "https://secret.example",
                    null))
        .isInstanceOf(DomainException.class);
  }

  @Test
  void servedOrReceivedWithoutStoredConfirmationExpires() {
    for (String state : List.of("SERVED", "DEVICE_REPORTED_RECEIVED")) {
      var delivery =
          new DeliveryDiagnosticSource.Item(
              DELIVERY,
              POLICY,
              VERSION,
              1,
              "UPSERT_CONFIGURATION",
              state,
              null,
              NOW - 20000,
              NOW - 1,
              NOW - 10000,
              null,
              null);
      var result = project(fleet("14", "1.0", List.of()), List.of(delivery), Map.of());
      assertThat(result.configurations().get(0).deliveryState()).isEqualTo("EXPIRED_AWAITING_PULL");
    }
  }

  @Test
  void missingCapabilityKeyHasStableSourceError() {
    assertThatThrownBy(
            () ->
                project(
                    fleet("14", "1.0", List.of(capability(null, "GRANTED"))), List.of(), Map.of()))
        .isInstanceOf(DomainException.class)
        .hasMessage("DIAGNOSTIC_SOURCE_INVALID");
  }

  @Test
  void invalidFutureEvidenceIsUnknownAndCapabilitiesAreDeterministicallyOrdered() {
    var future =
        new CapabilityView(
            "usage.report",
            true,
            "GRANTED",
            "AGENT_REPORT",
            NOW + 60000,
            "UNVERIFIED",
            false,
            "EVIDENCE_NOT_CERTIFIED");
    var result =
        json.valueToTree(
            project(
                fleet(
                    "14", "1.0", List.of(future, capability("app.launch_block", "NOT_REQUESTED"))),
                List.of(),
                Map.of()));
    assertThat(result.path("capabilities").get(0).path("key").asText())
        .isEqualTo("app.launch_block");
    assertThat(result.path("capabilities").get(1).path("checkedAt").isNull()).isTrue();
    assertThat(result.path("capabilities").get(1).path("status").asText()).isEqualTo("UNKNOWN");
  }
}
