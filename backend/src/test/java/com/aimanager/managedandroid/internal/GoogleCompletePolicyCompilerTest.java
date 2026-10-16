package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.managedandroid.ManagedAndroidGateway.*;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class GoogleCompletePolicyCompilerTest {
  @Test
  void desiredInputPreservesPublishedRecoveryPackages() {
    var desired = desired("PRIMARY", List.of("com.example.lesson"));
    assertThatThrownBy(() -> compiler.compileDesired(30, "DEVICE_OWNER", desired))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void desiredInputCannotOverrideCurrentRecoveryPackages() {
    var protectedCompiler =
        new GoogleCompletePolicyCompiler("com.aimanager.child", Set.of("com.example.lesson"));
    assertThatThrownBy(
            () ->
                protectedCompiler.compileDesired(30, "DEVICE_OWNER", desired("PRIMARY", List.of())))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void desiredInputNeedsIndependentModeAndApiEvidence() {
    var desired = desired("PRIMARY", List.of());
    assertThatThrownBy(() -> compiler.compileDesired(29, "DEVICE_OWNER", desired))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> compiler.compileDesired(30, "FULLY_MANAGED", desired))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () -> compiler.compileDesired(30, "DEVICE_OWNER", desired("WORK", List.of())))
        .isInstanceOf(IllegalArgumentException.class);
  }

  private com.aimanager.managedandroid.ManagedDesiredPolicy desired(
      String profile, List<String> protectedPackages) {
    return new com.aimanager.managedandroid.ManagedDesiredPolicy(
        new com.aimanager.managedandroid.ManagedExecutionPublicationAccess.Publication(
            "version", "c".repeat(64), 1),
        "device",
        "registration",
        List.of(
            new com.aimanager.managedandroid.ManagedDesiredPolicy.ApplicationIntent(
                "app",
                "com.example.lesson",
                profile,
                List.of("a".repeat(64)),
                AppControl.BLOCK_LAUNCH,
                List.of(
                    new RuntimePermissionDecision(
                        "android.permission.CAMERA", PermissionDecision.DENY)),
                List.of("launch", "camera"))),
        List.of(),
        protectedPackages);
  }

  @Test
  void combinesApplicationAndPermissionPolicyWithoutLosingTheManagementAgent() throws Exception {
    var compiler = new GoogleCompletePolicyCompiler("com.aimanager.child", Set.of());
    var result =
        compiler.compile(
            30,
            "DEVICE_OWNER",
            List.of(new AppRestriction("com.example.lesson", AppControl.BLOCK_LAUNCH)),
            List.of(
                new GoogleCompletePolicyCompiler.AppPermissions(
                    "com.example.lesson",
                    List.of(
                        new RuntimePermissionDecision(
                            "android.permission.CAMERA", PermissionDecision.DENY)))));
    assertThat(result)
        .as("complete policy must preserve both application controls and runtime decisions")
        .isNotNull();
    var policy = new ObjectMapper().readTree(result.documentJson()).path("policy");
    assertThat(policy.path("playStoreMode").asText()).isEqualTo("BLACKLIST");
    assertThat(policy.path("applications").size()).isEqualTo(2);
    var agent = policy.path("applications").get(0);
    assertThat(agent.path("packageName").asText()).isEqualTo("com.aimanager.child");
    assertThat(agent.path("installType").asText()).isEqualTo("FORCE_INSTALLED");
    var lesson = policy.path("applications").get(1);
    assertThat(lesson.path("disabled").asBoolean()).isTrue();
    assertThat(lesson.path("permissionGrants").get(0).path("policy").asText()).isEqualTo("DENY");
  }

  private final GoogleCompletePolicyCompiler compiler =
      new GoogleCompletePolicyCompiler("com.aimanager.child", Set.of("com.example.recovery"));
  private final ObjectMapper json = new ObjectMapper();

  private AppRestriction control(String name, AppControl value) {
    return new AppRestriction(name, value);
  }

  private GoogleCompletePolicyCompiler.AppPermissions permissions(
      String name, PermissionDecision value) {
    return new GoogleCompletePolicyCompiler.AppPermissions(
        name, List.of(new RuntimePermissionDecision("android.permission.CAMERA", value)));
  }

  private GoogleCompletePolicyCompiler.Compiled compile(
      List<AppRestriction> apps, List<GoogleCompletePolicyCompiler.AppPermissions> permissions) {
    return compiler.compile(30, "DEVICE_OWNER", apps, permissions);
  }

  private GoogleCompletePolicyCompiler.Compiled empty() {
    return compile(List.of(), List.of());
  }

  @Test
  void baselineHasExplicitPromptReportingAndRecoverableAgent() throws Exception {
    var result = empty();
    var root = json.readTree(result.documentJson());
    var policy = root.path("policy");
    assertThat(root.path("schemaVersion").asInt()).isEqualTo(1);
    assertThat(root.path("adapterRevision").asText()).isEqualTo("google-complete-policy-v1");
    assertThat(policy.path("defaultPermissionPolicy").asText()).isEqualTo("PROMPT");
    assertThat(policy.path("statusReportingSettings").path("applicationReportsEnabled").asBoolean())
        .isTrue();
    assertThat(policy.path("applications").get(0).path("userControlSettings").asText())
        .isEqualTo("USER_CONTROL_DISALLOWED");
    assertThat(result.sha256()).isEqualTo(SecretMaterial.hash(result.documentJson()));
    assertThat(result.toString()).doesNotContain("com.aimanager.child", result.documentJson());
  }

  @Test
  void canonicalOrderSurvivesInputOrderAndRoundTrips() {
    var controls =
        new ArrayList<>(
            List.of(
                control("com.example.z", AppControl.BLOCK_LAUNCH),
                control("com.example.a", AppControl.ALLOW)));
    var perms =
        new ArrayList<>(
            List.of(
                permissions("com.example.z", PermissionDecision.DENY),
                permissions("com.example.a", PermissionDecision.PROMPT)));
    var first = compile(controls, perms);
    Collections.reverse(controls);
    Collections.reverse(perms);
    var second = compile(controls, perms);
    assertThat(second.documentJson()).isEqualTo(first.documentJson());
    var restored = compiler.restore(first.documentJson(), first.sha256(), 30, "DEVICE_OWNER");
    assertThat(restored.documentJson()).isEqualTo(first.documentJson());
    assertThat(restored.sha256()).isEqualTo(first.sha256());
  }

  @Test
  void permissionOnlyApplicationAndBlockedInstallAreExplicit() {
    var result =
        compile(
            List.of(control("com.example.blocked", AppControl.BLOCK_INSTALL)),
            List.of(permissions("com.example.permission", PermissionDecision.PROMPT)));
    var apps = result.requestBody().getApplications();
    assertThat(apps.get(1).getInstallType()).isEqualTo("BLOCKED");
    assertThat(apps.get(1).getDisabled()).isFalse();
    assertThat(apps.get(2).getInstallType()).isEqualTo("AVAILABLE");
    assertThat(apps.get(2).getPermissionGrants().get(0).getPolicy()).isEqualTo("PROMPT");
  }

  @Test
  void mutableSdkObjectsAndCallerListsCannotChangeFrozenDocument() {
    var source = new ArrayList<>(List.of(control("com.example.lesson", AppControl.ALLOW)));
    var result = compile(source, List.of());
    var bytes = result.documentJson();
    source.clear();
    result.requestBody().getApplications().clear();
    result.requestBody().setPlayStoreMode("WHITELIST");
    assertThat(result.documentJson()).isEqualTo(bytes);
    assertThat(result.requestBody().getApplications()).hasSize(2);
    assertThat(result.requestBody().getPlayStoreMode()).isEqualTo("BLACKLIST");
  }

  @ParameterizedTest
  @ValueSource(ints = {-1, 0, 1, 29})
  void unsupportedApiDoesNotProduceAWeakenedAgentBaseline(int api) {
    assertThatThrownBy(() -> compiler.compile(api, "DEVICE_OWNER", List.of(), List.of()))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @ParameterizedTest
  @ValueSource(strings = {"", "PROFILE_OWNER", "UNKNOWN", "DEVICE_ADMIN"})
  void nonOwnerModeCannotCompile(String mode) {
    assertThatThrownBy(() -> compiler.compile(30, mode, List.of(), List.of()))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "com.android.settings",
        "com.android.dialer",
        "com.google.android.apps.work.clouddpc",
        "com.aimanager.child",
        "com.example.recovery"
      })
  void safetyAndConfiguredRecoveryCannotBeBlockedOrDenied(String pkg) {
    assertThatThrownBy(() -> compile(List.of(control(pkg, AppControl.BLOCK_LAUNCH)), List.of()))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> compile(List.of(control(pkg, AppControl.BLOCK_INSTALL)), List.of()))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> compile(List.of(), List.of(permissions(pkg, PermissionDecision.DENY))))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @ParameterizedTest
  @ValueSource(strings = {"", "bad", "com.example/a", "com.example..app", "com.example. app"})
  void malformedPackagesAreRejected(String pkg) {
    assertThatThrownBy(() -> compile(List.of(control(pkg, AppControl.ALLOW)), List.of()))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> new GoogleCompletePolicyCompiler(pkg, Set.of()))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void duplicateApplicationsAndPermissionGroupsAreRejected() {
    var app = control("com.example.lesson", AppControl.ALLOW);
    var perm = permissions("com.example.lesson", PermissionDecision.DENY);
    assertThatThrownBy(() -> compile(List.of(app, app), List.of()))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> compile(List.of(), List.of(perm, perm)))
        .isInstanceOf(IllegalArgumentException.class);
    var decision =
        new RuntimePermissionDecision("android.permission.CAMERA", PermissionDecision.DENY);
    assertThatThrownBy(
            () ->
                compile(
                    List.of(),
                    List.of(
                        new GoogleCompletePolicyCompiler.AppPermissions(
                            "com.example.lesson", List.of(decision, decision)))))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void blockedApplicationCannotPretendToUseRuntimePermissions() {
    assertThatThrownBy(
            () ->
                compile(
                    List.of(control("com.example.lesson", AppControl.BLOCK_INSTALL)),
                    List.of(permissions("com.example.lesson", PermissionDecision.DENY))))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void unsupportedPermissionAndNullValuesAreRejected() {
    assertThatThrownBy(() -> compile(null, List.of())).isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> compile(List.of(), null)).isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> compile(List.of(control("com.example.lesson", null)), List.of()))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () ->
                compile(
                    List.of(),
                    List.of(
                        new GoogleCompletePolicyCompiler.AppPermissions(
                            "com.example.lesson", null))))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () ->
                compile(
                    List.of(),
                    List.of(
                        new GoogleCompletePolicyCompiler.AppPermissions(
                            "com.example.lesson",
                            List.of(
                                new RuntimePermissionDecision(
                                    "android.permission.INTERNET", PermissionDecision.DENY))))))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void sizeLimitsApplyToCombinedApplicationsAndSerializedDocument() {
    var apps = new ArrayList<AppRestriction>();
    for (int i = 0; i < 199; i++) apps.add(control("com.example.a" + i, AppControl.ALLOW));
    assertThat(compile(apps, List.of()).requestBody().getApplications()).hasSize(200);
    apps.add(control("com.example.extra", AppControl.ALLOW));
    assertThatThrownBy(() -> compile(apps, List.of())).isInstanceOf(IllegalArgumentException.class);
    apps.remove(apps.size() - 1);
    var perms = new ArrayList<GoogleCompletePolicyCompiler.AppPermissions>();
    for (var app : apps)
      perms.add(
          new GoogleCompletePolicyCompiler.AppPermissions(
              app.packageName(),
              com.aimanager.shared.AndroidRuntimePermissions.names().stream()
                  .map(p -> new RuntimePermissionDecision(p, PermissionDecision.DENY))
                  .toList()));
    assertThatThrownBy(() -> compile(apps, perms)).isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void permissionsAreSortedAndAgentCannotBeReconfigured() {
    var result =
        compile(
            List.of(control("com.aimanager.child", AppControl.ALLOW)),
            List.of(
                new GoogleCompletePolicyCompiler.AppPermissions(
                    "com.example.lesson",
                    List.of(
                        new RuntimePermissionDecision(
                            "android.permission.RECORD_AUDIO", PermissionDecision.DENY),
                        new RuntimePermissionDecision(
                            "android.permission.CAMERA", PermissionDecision.PROMPT)))));
    assertThat(result.requestBody().getApplications().get(0).getInstallType())
        .isEqualTo("FORCE_INSTALLED");
    assertThat(result.requestBody().getApplications().get(1).getPermissionGrants())
        .extracting(
            com.google.api.services.androidmanagement.v1.model.PermissionGrant::getPermission)
        .containsExactly("android.permission.CAMERA", "android.permission.RECORD_AUDIO");
    assertThatThrownBy(
            () ->
                compile(
                    List.of(),
                    List.of(permissions("com.aimanager.child", PermissionDecision.PROMPT))))
        .isInstanceOf(IllegalArgumentException.class);
    var another = new GoogleCompletePolicyCompiler("com.example.otheragent", Set.of());
    assertThatThrownBy(
            () -> another.restore(result.documentJson(), result.sha256(), 30, "DEVICE_OWNER"))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void restoredPolicyRetainsAllControlsAndPermissions() {
    var result =
        compile(
            List.of(
                control("com.example.a", AppControl.BLOCK_INSTALL),
                control("com.example.b", AppControl.BLOCK_LAUNCH)),
            List.of(
                permissions("com.example.b", PermissionDecision.DENY),
                permissions("com.example.c", PermissionDecision.PROMPT)));
    var restored = compiler.restore(result.documentJson(), result.sha256(), 30, "DEVICE_OWNER");
    assertThat(restored.documentJson()).isEqualTo(result.documentJson());
    assertThat(restored.requestBody()).isEqualTo(result.requestBody());
  }

  @Test
  void changedRecoveryConfigurationRejectsAnOldDenial() {
    var result =
        compile(List.of(control("com.example.lesson", AppControl.BLOCK_LAUNCH)), List.of());
    var changed =
        new GoogleCompletePolicyCompiler("com.aimanager.child", Set.of("com.example.lesson"));
    assertThatThrownBy(
            () -> changed.restore(result.documentJson(), result.sha256(), 30, "DEVICE_OWNER"))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void permissionOrderDoesNotChangeCanonicalDocument() {
    var decisions =
        new ArrayList<>(
            List.of(
                new RuntimePermissionDecision(
                    "android.permission.CAMERA", PermissionDecision.PROMPT),
                new RuntimePermissionDecision(
                    "android.permission.RECORD_AUDIO", PermissionDecision.DENY)));
    var first =
        compile(
            List.of(),
            List.of(
                new GoogleCompletePolicyCompiler.AppPermissions("com.example.lesson", decisions)));
    Collections.reverse(decisions);
    var second =
        compile(
            List.of(),
            List.of(
                new GoogleCompletePolicyCompiler.AppPermissions("com.example.lesson", decisions)));
    assertThat(first.documentJson()).isEqualTo(second.documentJson());
  }

  @Test
  void restorationEnforcesDocumentSizeBeforeParsing() {
    String document = " ".repeat(65537);
    assertThatThrownBy(
            () -> compiler.restore(document, SecretMaterial.hash(document), 30, "DEVICE_OWNER"))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void restoreRequiresHashAndKnownCanonicalDocument() {
    var value = empty();
    assertThatThrownBy(
            () -> compiler.restore(value.documentJson(), "0".repeat(64), 30, "DEVICE_OWNER"))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () ->
                compiler.restore(
                    " " + value.documentJson(),
                    SecretMaterial.hash(" " + value.documentJson()),
                    30,
                    "DEVICE_OWNER"))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () -> compiler.restore(value.documentJson(), value.sha256(), 29, "DEVICE_OWNER"))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @ParameterizedTest
  @ValueSource(strings = {"null", "[]", "{}", "{} {}", "{\"schemaVersion\":1,\"schemaVersion\":1}"})
  void restoreRejectsMalformedJson(String text) {
    assertThatThrownBy(() -> compiler.restore(text, SecretMaterial.hash(text), 30, "DEVICE_OWNER"))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "revision",
        "unknownPolicyField",
        "missingAgent",
        "permissionGrant",
        "extraAppField",
        "disabledAgent",
        "reporting",
        "globalGrant",
        "unknownEnvelope",
        "wrongBoolean",
        "nullBoolean",
        "numberBoolean"
      })
  void restoredPayloadCannotChangeTheSupportedContract(String mutation) throws Exception {
    var root =
        (com.fasterxml.jackson.databind.node.ObjectNode) json.readTree(empty().documentJson());
    var policy = (com.fasterxml.jackson.databind.node.ObjectNode) root.path("policy");
    var apps = (com.fasterxml.jackson.databind.node.ArrayNode) policy.path("applications");
    var agent = (com.fasterxml.jackson.databind.node.ObjectNode) apps.get(0);
    switch (mutation) {
      case "revision" -> root.put("adapterRevision", "google-complete-policy-v2");
      case "unknownPolicyField" -> policy.put("factoryResetDisabled", true);
      case "missingAgent" -> apps.removeAll();
      case "permissionGrant" ->
          agent
              .putArray("permissionGrants")
              .addObject()
              .put("permission", "android.permission.CAMERA")
              .put("policy", "GRANT");
      case "extraAppField" -> agent.putArray("delegatedScopes").add("CERT_INSTALL");
      case "disabledAgent" -> agent.put("disabled", true);
      case "reporting" ->
          ((com.fasterxml.jackson.databind.node.ObjectNode) policy.path("statusReportingSettings"))
              .put("applicationReportsEnabled", false);
      case "globalGrant" -> policy.put("defaultPermissionPolicy", "GRANT");
      case "unknownEnvelope" -> root.put("tenantId", "untrusted");
      case "wrongBoolean" -> agent.put("disabled", "false");
      case "nullBoolean" -> agent.putNull("disabled");
      case "numberBoolean" -> agent.put("disabled", 0);
      default -> throw new AssertionError();
    }
    String changed = json.writeValueAsString(root);
    assertThatThrownBy(
            () -> compiler.restore(changed, SecretMaterial.hash(changed), 30, "DEVICE_OWNER"))
        .isInstanceOf(IllegalArgumentException.class);
  }
}
