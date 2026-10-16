package com.aimanager.policy.internal;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.ManagedAndroidGateway.AppControl;
import com.aimanager.managedandroid.ManagedAndroidGateway.PermissionDecision;
import com.aimanager.managedandroid.ManagedDesiredPolicy;
import com.aimanager.managedandroid.internal.ManagedExecutionTestData;
import com.aimanager.policy.PolicyRule;
import com.aimanager.policy.PolicySnapshot;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.List;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.transaction.support.TransactionTemplate;

class ManagedDesiredPolicyReaderTest {
  ManagedExecutionTestData data;
  ManagedExecutionTestData.Fixture f;
  ManagedExecutionPublicationReader reader;
  TransactionTemplate tx;
  final ObjectMapper json = new ObjectMapper();
  final String app = "10000000-0000-0000-0000-000000000001";

  @BeforeEach
  void setup() {
    data = new ManagedExecutionTestData();
    f = data.fixture();
    reader = new ManagedExecutionPublicationReader(data.db, json, new TenantAccess(data.db));
    tx = new TransactionTemplate(data.transactions);
  }

  @AfterEach
  void close() {
    data.close();
  }

  @Test
  void resolvesEveryPublishedApplicationAndPermissionRule() throws Exception {
    store(
        List.of(
            rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY, null),
            rule(
                "camera",
                PolicyRule.Kind.RUNTIME_PERMISSION,
                PolicyRule.Effect.DENY,
                "android.permission.CAMERA")));
    var desired = read();
    assertThat(desired)
        .as("published rules must supply complete immutable desired inputs")
        .isNotNull();
    assertThat(desired.publication().versionId()).isEqualTo(f.version());
    assertThat(desired.applications()).hasSize(1);
    var application = desired.applications().get(0);
    assertThat(application.control()).isEqualTo(AppControl.BLOCK_LAUNCH);
    assertThat(application.permissions())
        .singleElement()
        .satisfies(p -> assertThat(p.decision()).isEqualTo(PermissionDecision.DENY));
    assertThat(application.sourceRuleIds()).containsExactly("camera", "launch");
    assertThat(desired.rules())
        .extracting(ManagedDesiredPolicy.RuleReadiness::status)
        .containsOnly("UNVERIFIED");
  }

  ManagedDesiredPolicy read() {
    return tx.execute(
        s ->
            reader.requireDesiredTarget(
                f.tenant(), f.actor(), f.publication(), f.device(), f.registration()));
  }

  @Test
  void onlyUsesPublishedBytesEvenWhenDraftChanges() throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY, null)));
    data.db.update("UPDATE policy_drafts SET rules_json='[]' WHERE tenant_id=?", f.tenant());
    assertThat(read().applications().get(0).control()).isEqualTo(AppControl.BLOCK_LAUNCH);
  }

  @Test
  void returnedCollectionsCannotBeChanged() throws Exception {
    store(
        List.of(
            rule(
                "camera",
                PolicyRule.Kind.RUNTIME_PERMISSION,
                PolicyRule.Effect.DEFAULT,
                "android.permission.CAMERA")));
    var desired = read();
    assertThat(desired.applications().get(0).permissions().get(0).decision())
        .isEqualTo(PermissionDecision.PROMPT);
    assertThatThrownBy(() -> desired.applications().clear())
        .isInstanceOf(UnsupportedOperationException.class);
    assertThatThrownBy(() -> desired.applications().get(0).permissions().clear())
        .isInstanceOf(UnsupportedOperationException.class);
    assertThatThrownBy(() -> desired.applications().get(0).sourceRuleIds().clear())
        .isInstanceOf(UnsupportedOperationException.class);
    assertThatThrownBy(() -> desired.applications().get(0).signingDigests().clear())
        .isInstanceOf(UnsupportedOperationException.class);
    assertThatThrownBy(() -> desired.rules().clear())
        .isInstanceOf(UnsupportedOperationException.class);
    assertThatThrownBy(() -> desired.protectedPackages().clear())
        .isInstanceOf(UnsupportedOperationException.class);
  }

  @ParameterizedTest
  @EnumSource(
      value = PolicyRule.Kind.class,
      names = {
        "APP_UNINSTALL",
        "SPECIAL_ACCESS",
        "DAILY_QUOTA",
        "TIME_WINDOW",
        "DOMAIN_ACCESS",
        "USAGE_REMINDER"
      })
  void unsupportedOptionalRulesAreNotSilentlyDropped(PolicyRule.Kind kind) throws Exception {
    store(
        List.of(
            new PolicyRule(
                "optional", kind, PolicyRule.Effect.ALLOW, false, app, null, null, null, null)));
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_RULE_KIND_UNSUPPORTED");
  }

  @ParameterizedTest
  @ValueSource(strings = {"CHILD", "GUARDIAN", "AUDITOR", "TEACHER"})
  void desiredInputsKeepExistingRoleBoundary(String role) throws Exception {
    store(List.of());
    data.db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
    assertThatThrownBy(this::read).isInstanceOf(DomainException.class).hasMessage("SCOPE_DENIED");
  }

  @Test
  void configurationOnlyStillCannotSupplyExecutionInputs() throws Exception {
    store(List.of());
    data.db.update(
        "UPDATE policy_versions SET mode='CONFIGURE_ONLY' WHERE tenant_id=?", f.tenant());
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PUBLICATION_REQUIRED");
  }

  @Test
  void exactTenantActorAndRegistrationAreRequired() throws Exception {
    store(List.of());
    var other = data.fixture();
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireDesiredTarget(
                            other.tenant(),
                            other.actor(),
                            f.publication(),
                            f.device(),
                            f.registration())))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireDesiredTarget(
                            f.tenant(),
                            other.actor(),
                            f.publication(),
                            f.device(),
                            f.registration())))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireDesiredTarget(
                            f.tenant(),
                            f.actor(),
                            f.publication(),
                            f.device(),
                            other.registration())))
        .isInstanceOf(DomainException.class);
  }

  @Test
  void installDenyWithPermissionMustNotLoseThePermissionRule() throws Exception {
    store(
        List.of(
            rule("install", PolicyRule.Kind.APP_INSTALL, PolicyRule.Effect.DENY, null),
            rule(
                "camera",
                PolicyRule.Kind.RUNTIME_PERMISSION,
                PolicyRule.Effect.DENY,
                "android.permission.CAMERA")));
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_RULE_COMBINATION_UNSUPPORTED");
  }

  @Test
  void installDenyCannotPromiseThatLaunchIsAllowed() throws Exception {
    store(
        List.of(
            rule("install", PolicyRule.Kind.APP_INSTALL, PolicyRule.Effect.DENY, null),
            rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null)));
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_RULE_COMBINATION_UNSUPPORTED");
  }

  @Test
  void installingAndLaunchRulesAreComposedWithoutResettingLaunchBlock() throws Exception {
    store(
        List.of(
            rule("install", PolicyRule.Kind.APP_INSTALL, PolicyRule.Effect.ALLOW, null),
            rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY, null)));
    assertThat(read().applications().get(0).control()).isEqualTo(AppControl.BLOCK_LAUNCH);
  }

  @Test
  void installAndLaunchDenyRemainOneBlockedApplication() throws Exception {
    store(
        List.of(
            rule("install", PolicyRule.Kind.APP_INSTALL, PolicyRule.Effect.DENY, null),
            rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY, null)));
    assertThat(read().applications().get(0).control()).isEqualTo(AppControl.BLOCK_INSTALL);
  }

  @Test
  void automaticPermissionGrantIsRejected() throws Exception {
    store(
        List.of(
            rule(
                "camera",
                PolicyRule.Kind.RUNTIME_PERMISSION,
                PolicyRule.Effect.GRANT,
                "android.permission.CAMERA")));
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_RULE_EFFECT_UNSUPPORTED");
  }

  @Test
  void missingEvaluationsCannotHideAnUnsupportedOrDroppedRule() throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY, null)));
    mutate(
        n ->
            ((com.fasterxml.jackson.databind.node.ObjectNode) n.path("targets").get(0))
                .putArray("rules"));
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_RULE_COVERAGE_INVALID");
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "predictedEffect",
        "kind",
        "applicationId",
        "permission",
        "sourceRuleIds",
        "required",
        "effectiveEffect"
      })
  void mismatchedEvaluationCannotChangePublishedMeaning(String field) throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY, null)));
    mutate(
        n -> {
          var e =
              (com.fasterxml.jackson.databind.node.ObjectNode)
                  n.path("targets").get(0).path("rules").get(0);
          switch (field) {
            case "predictedEffect", "effectiveEffect" -> e.put(field, "ALLOW");
            case "kind" -> e.put(field, "APP_INSTALL");
            case "applicationId" -> e.put(field, ManagedExecutionTestData.id());
            case "permission" -> e.put(field, "android.permission.CAMERA");
            case "sourceRuleIds" -> e.putArray(field).add("missing");
            case "required" -> e.put(field, false);
          }
        });
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_RULE_COVERAGE_INVALID");
  }

  @ParameterizedTest
  @ValueSource(strings = {"WORK", "SECONDARY", "UNKNOWN"})
  void unsupportedProfilesAreExplicitlyRejected(String profile) throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null)));
    mutate(
        n ->
            ((com.fasterxml.jackson.databind.node.ObjectNode) n.path("applications").get(0))
                .put("profile", profile));
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_APPLICATION_SCOPE_UNSUPPORTED");
  }

  @Test
  void sameLayerDenyWinsAndEverySourceIdIsRetained() throws Exception {
    store(
        List.of(
            rule("a", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null),
            rule("b", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY, null)));
    mutate(
        n -> {
          var list =
              (com.fasterxml.jackson.databind.node.ArrayNode)
                  n.path("targets").get(0).path("rules");
          var e = (com.fasterxml.jackson.databind.node.ObjectNode) list.get(0);
          e.put("predictedEffect", "DENY");
          e.putArray("sourceRuleIds").add("b").add("a");
          list.remove(1);
        });
    var result = read();
    assertThat(result.applications().get(0).control()).isEqualTo(AppControl.BLOCK_LAUNCH);
    assertThat(result.applications().get(0).sourceRuleIds()).containsExactly("a", "b");
    assertThat(result.rules())
        .extracting(ManagedDesiredPolicy.RuleReadiness::sourceRuleId)
        .containsExactly("a", "b");
  }

  @Test
  void samePermissionDenyWinsOverDefault() throws Exception {
    store(
        List.of(
            rule(
                "a",
                PolicyRule.Kind.RUNTIME_PERMISSION,
                PolicyRule.Effect.DEFAULT,
                "android.permission.CAMERA"),
            rule(
                "b",
                PolicyRule.Kind.RUNTIME_PERMISSION,
                PolicyRule.Effect.DENY,
                "android.permission.CAMERA")));
    mutate(
        n -> {
          var list =
              (com.fasterxml.jackson.databind.node.ArrayNode)
                  n.path("targets").get(0).path("rules");
          var e = (com.fasterxml.jackson.databind.node.ObjectNode) list.get(0);
          e.put("predictedEffect", "DENY");
          e.putArray("sourceRuleIds").add("a").add("b");
          list.remove(1);
        });
    assertThat(read().applications().get(0).permissions().get(0).decision())
        .isEqualTo(PermissionDecision.DENY);
  }

  @Test
  void duplicateApplicationAliasesCannotOverwriteOnePackage() throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null)));
    mutate(
        n -> {
          var apps = (com.fasterxml.jackson.databind.node.ArrayNode) n.path("applications");
          var alias = apps.get(0).deepCopy();
          ((com.fasterxml.jackson.databind.node.ObjectNode) alias)
              .put("id", ManagedExecutionTestData.id());
          apps.add(alias);
        });
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_APPLICATION_IDENTITY_INVALID");
  }

  @Test
  void emptyPolicyIsAnExplicitBaselineRatherThanMissingRules() throws Exception {
    store(List.of());
    mutate(n -> ((com.fasterxml.jackson.databind.node.ObjectNode) n).putArray("applications"));
    assertThat(read().applications()).isEmpty();
    assertThat(read().rules()).isEmpty();
  }

  @Test
  void revocationIsCheckedAgainWhenReadingThePublishedInputs() throws Exception {
    store(List.of());
    data.db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    assertThatThrownBy(this::read).isInstanceOf(DomainException.class).hasMessage("SCOPE_DENIED");
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "null",
        "{}",
        "[]",
        "{\"schemaVersion\":1,\"schemaVersion\":1,\"targets\":[]}",
        "{} {}"
      })
  void malformedStoredInputCannotBecomeACompletePolicy(String value) {
    data.db.update(
        "UPDATE policy_versions SET snapshot_json=? WHERE tenant_id=?", value, f.tenant());
    assertThatThrownBy(this::read).isInstanceOf(IllegalStateException.class);
  }

  void mutate(java.util.function.Consumer<com.fasterxml.jackson.databind.JsonNode> change)
      throws Exception {
    var n =
        json.readTree(
            data.db.queryForObject(
                "SELECT snapshot_json FROM policy_versions WHERE tenant_id=? AND id=?",
                String.class,
                f.tenant(),
                f.version()));
    change.accept(n);
    data.db.update(
        "UPDATE policy_versions SET snapshot_json=? WHERE tenant_id=? AND id=?",
        json.writeValueAsString(n),
        f.tenant(),
        f.version());
  }

  @ParameterizedTest
  @ValueSource(strings = {"", "not-an-id", "NULL"})
  void missingOrInvalidApplicationReferenceHasStableError(String value) throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null)));
    mutate(
        n -> {
          var r = (com.fasterxml.jackson.databind.node.ObjectNode) n.path("sourceRules").get(0);
          if (value.equals("NULL")) r.remove("applicationId");
          else r.put("applicationId", value);
        });
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_APPLICATION_IDENTITY_INVALID");
  }

  @ParameterizedTest
  @ValueSource(strings = {"required-string", "required-number", "schema-string"})
  void scalarCoercionDoesNotRepairCorruptPublishedInputs(String field) throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null)));
    mutate(
        n -> {
          var r = (com.fasterxml.jackson.databind.node.ObjectNode) n.path("sourceRules").get(0);
          if (field.equals("required-string")) r.put("required", "false");
          else if (field.equals("required-number")) r.put("required", 0);
          else ((com.fasterxml.jackson.databind.node.ObjectNode) n).put("schemaVersion", "1");
        });
    assertThatThrownBy(this::read).isInstanceOf(IllegalStateException.class);
  }

  @Test
  void actualPreviewCompilerGroupsAreAcceptedWithoutUpgradingReadiness() throws Exception {
    var rules =
        List.of(
            rule("allow", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null),
            rule("deny", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY, null));
    store(rules);
    var device =
        new Device(
            f.device(),
            f.subject(),
            f.registration(),
            "Fixture",
            Device.Platform.ANDROID,
            "14",
            Device.State.ACTIVE,
            "FULLY_MANAGED",
            "PARTIAL",
            null,
            "CURRENT",
            "fixture",
            0);
    var capability =
        new com.aimanager.fleet.CapabilityView(
            "app.launch_block",
            true,
            "GRANTED",
            "FIXTURE",
            1L,
            "SUPPORTED",
            true,
            "AWAITING_EXECUTION");
    var definition =
        new ApplicationDefinition(
            app,
            "Lesson",
            Device.Platform.ANDROID,
            "com.example.lesson",
            ApplicationDefinition.Profile.PRIMARY,
            List.of("a".repeat(64)),
            "DECLARED");
    var preview =
        new RuleCompiler("")
            .compile(
                rules,
                java.util.Map.of(app, definition),
                new com.aimanager.fleet.FleetPolicyAccess.Target(device, List.of(capability)));
    mutate(
        n ->
            ((com.fasterxml.jackson.databind.node.ObjectNode) n.path("targets").get(0))
                .set("rules", json.valueToTree(preview)));
    var desired = read();
    assertThat(desired.applications().get(0).control()).isEqualTo(AppControl.BLOCK_LAUNCH);
    assertThat(desired.applications().get(0).sourceRuleIds()).containsExactly("allow", "deny");
    assertThat(desired.rules()).allMatch(r -> r.status().equals("UNVERIFIED"));
  }

  @ParameterizedTest
  @ValueSource(strings = {"kind", "unknown"})
  void numericEnumsAndUnknownStoredFieldsAreNotSilentlyAccepted(String field) throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null)));
    mutate(
        n ->
            ((com.fasterxml.jackson.databind.node.ObjectNode) n.path("sourceRules").get(0))
                .put(field, 0));
    assertThatThrownBy(this::read).isInstanceOf(IllegalStateException.class);
  }

  @ParameterizedTest
  @ValueSource(strings = {"sourceRules", "applications", "schedules", "protectedPackageExemptions"})
  void missingSourceCollectionsAreNotAnEmptyPolicy(String field) throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null)));
    mutate(n -> ((com.fasterxml.jackson.databind.node.ObjectNode) n).remove(field));
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_SOURCE_INVALID");
  }

  @Test
  void duplicateSourceRulesDoNotDisappearDuringGrouping() throws Exception {
    var r = rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null);
    store(List.of(r, r));
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_SOURCE_INVALID");
  }

  @Test
  void snapshotRecoveryExemptionsAreValidatedBeforeTranslation() throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.DENY, null)));
    mutate(
        n ->
            ((com.fasterxml.jackson.databind.node.ObjectNode) n)
                .putArray("protectedPackageExemptions")
                .add("com.example.lesson"));
    assertThatThrownBy(this::read)
        .isInstanceOf(DomainException.class)
        .hasMessage("SAFETY_BASELINE_PROTECTED");
  }

  @Test
  void noProviderCallsOrDatabaseWritesAreNeededForDesiredTranslation() throws Exception {
    store(List.of(rule("launch", PolicyRule.Kind.APP_LAUNCH, PolicyRule.Effect.ALLOW, null)));
    var before =
        data.db.queryForObject(
            "SELECT snapshot_json FROM policy_versions WHERE tenant_id=?",
            String.class,
            f.tenant());
    read();
    assertThat(
            data.db.queryForObject(
                "SELECT snapshot_json FROM policy_versions WHERE tenant_id=?",
                String.class,
                f.tenant()))
        .isEqualTo(before);
    assertThat(
            data.db.queryForObject(
                "SELECT COUNT(*) FROM managed_policy_execution_tasks WHERE tenant_id=?",
                Long.class,
                f.tenant()))
        .isZero();
  }

  PolicyRule rule(String id, PolicyRule.Kind kind, PolicyRule.Effect effect, String permission) {
    return new PolicyRule(id, kind, effect, true, app, null, null, permission, null);
  }

  void store(List<PolicyRule> rules) throws Exception {
    var evaluations =
        rules.stream()
            .map(
                r ->
                    new PolicySnapshot.RuleEvaluation(
                        List.of(r.id()),
                        r.kind(),
                        r.applicationId(),
                        null,
                        r.permission(),
                        null,
                        null,
                        r.required(),
                        r.effect(),
                        null,
                        "UNVERIFIED",
                        "APPLICATION_PROFILE_NOT_VERIFIED",
                        List.of()))
            .toList();
    var target =
        new PolicySnapshot.Target(
            f.device(),
            f.registration(),
            Device.Platform.ANDROID,
            Device.State.ACTIVE,
            "FULLY_MANAGED",
            "14",
            0,
            "CURRENT",
            List.of(),
            evaluations,
            List.of());
    var definition =
        new ApplicationDefinition(
            app,
            "Lesson",
            Device.Platform.ANDROID,
            "com.example.lesson",
            ApplicationDefinition.Profile.PRIMARY,
            List.of("a".repeat(64)),
            "DECLARED");
    var snapshot =
        new PolicySnapshot(
            1,
            "Published",
            rules,
            List.of(definition),
            List.of(),
            List.of(),
            List.of(target),
            null);
    data.db.update(
        "UPDATE policy_versions SET snapshot_json=? WHERE tenant_id=? AND id=?",
        json.writeValueAsString(snapshot),
        f.tenant(),
        f.version());
  }
}
