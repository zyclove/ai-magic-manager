package com.aimanager.policy.internal;

import static com.aimanager.policy.PolicyRule.Effect.*;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.ManagedAndroidGateway.AppControl;
import com.aimanager.managedandroid.ManagedAndroidGateway.PermissionDecision;
import com.aimanager.managedandroid.ManagedAndroidGateway.RuntimePermissionDecision;
import com.aimanager.managedandroid.ManagedDesiredPolicy;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess.Publication;
import com.aimanager.policy.PolicyRule;
import com.aimanager.policy.PolicySnapshot;
import com.aimanager.shared.DomainException;
import java.util.*;
import org.springframework.http.HttpStatus;

/** Complete desired-state translation. Frozen preview facts never certify current OS authority. */
final class ManagedDesiredPolicyResolver {
  private record Key(PolicyRule.Kind kind, String application, String permission) {}

  ManagedDesiredPolicy resolve(
      Publication publication, PolicySnapshot snapshot, PolicySnapshot.Target target) {
    if (snapshot.sourceRules() == null
        || snapshot.sourceRules().size() > 100
        || snapshot.applications() == null
        || snapshot.applications().size() > 100
        || snapshot.protectedPackageExemptions() == null
        || snapshot.protectedPackageExemptions().size() > 1000
        || snapshot.schedules() == null
        || !snapshot.schedules().isEmpty()
        || target.rules() == null
        || target.rules().size() > 100) throw invalid();
    var apps = new TreeMap<String, ApplicationDefinition>();
    var packages = new HashSet<String>();
    for (var app : snapshot.applications()) {
      if (app == null
          || !id(app.id())
          || !pkg(app.packageName())
          || app.platform() == null
          || app.profile() == null
          || app.signingDigests() == null
          || app.signingDigests().size() > 8
          || app.signingDigests().stream().anyMatch(s -> s == null || !s.matches("[0-9a-f]{64}"))
          || new HashSet<>(app.signingDigests()).size() != app.signingDigests().size()
          || apps.putIfAbsent(app.id(), app) != null
          || !packages.add(app.packageName()))
        throw reject("EXECUTION_APPLICATION_IDENTITY_INVALID");
    }
    var protections = new TreeSet<String>();
    for (String protectedPackage : snapshot.protectedPackageExemptions()) {
      if (!pkg(protectedPackage)) throw invalid();
      protections.add(protectedPackage);
    }
    var groups = new HashMap<Key, List<PolicyRule>>();
    var sourceIds = new HashSet<String>();
    for (var rule : snapshot.sourceRules()) {
      if (rule == null
          || rule.kind() == null
          || rule.effect() == null
          || rule.required() == null
          || rule.id() == null
          || !rule.id().matches("[a-z][a-z0-9_-]{0,49}")
          || !sourceIds.add(rule.id())) throw invalid();
      if (!Set.of(
              PolicyRule.Kind.APP_LAUNCH,
              PolicyRule.Kind.APP_INSTALL,
              PolicyRule.Kind.RUNTIME_PERMISSION)
          .contains(rule.kind())) throw reject("EXECUTION_RULE_KIND_UNSUPPORTED");
      if (!id(rule.applicationId())) throw reject("EXECUTION_APPLICATION_IDENTITY_INVALID");
      var app = apps.get(rule.applicationId());
      if (app == null) throw reject("EXECUTION_APPLICATION_IDENTITY_INVALID");
      if (app.platform() != target.platform()
          || app.profile() != ApplicationDefinition.Profile.PRIMARY)
        throw reject("EXECUTION_APPLICATION_SCOPE_UNSUPPORTED");
      groups
          .computeIfAbsent(
              new Key(rule.kind(), rule.applicationId(), rule.permission()),
              unused -> new ArrayList<>())
          .add(rule);
    }
    // Reuse domain field/permission/safety validation rather than inventing a second rule schema.
    new RuleCompiler(String.join(",", protections)).validate(snapshot.sourceRules(), apps);
    if (target.platform() == null || target.state() != Device.State.ACTIVE)
      throw reject("EXECUTION_TARGET_UNAVAILABLE");
    var evaluated = new HashMap<Key, PolicySnapshot.RuleEvaluation>();
    var readiness = new TreeMap<String, ManagedDesiredPolicy.RuleReadiness>();
    for (var evaluation : target.rules()) {
      if (evaluation == null
          || evaluation.kind() == null
          || evaluation.sourceRuleIds() == null
          || evaluation.status() == null
          || evaluation.status().isBlank()
          || evaluation.status().length() > 100
          || evaluation.reasonCode() == null
          || evaluation.reasonCode().isBlank()
          || evaluation.reasonCode().length() > 150) throw coverage();
      var key = new Key(evaluation.kind(), evaluation.applicationId(), evaluation.permission());
      var group = groups.get(key);
      if (group == null
          || evaluated.putIfAbsent(key, evaluation) != null
          || evaluation.sourceRuleIds().size() != group.size()
          || !new HashSet<>(evaluation.sourceRuleIds())
              .equals(
                  group.stream().map(PolicyRule::id).collect(java.util.stream.Collectors.toSet()))
          || evaluation.scheduleId() != null
          || evaluation.domain() != null
          || evaluation.seconds() != null
          || evaluation.effectiveEffect() != null
          || evaluation.predictedEffect() != effect(group)
          || evaluation.required() != group.stream().anyMatch(PolicyRule::required))
        throw coverage();
      for (var rule : group)
        readiness.put(
            rule.id(),
            new ManagedDesiredPolicy.RuleReadiness(
                rule.id(), evaluation.status(), evaluation.reasonCode()));
    }
    if (evaluated.size() != groups.size() || readiness.size() != sourceIds.size()) throw coverage();
    var byApp = new TreeMap<String, List<PolicySnapshot.RuleEvaluation>>();
    evaluated
        .values()
        .forEach(e -> byApp.computeIfAbsent(e.applicationId(), unused -> new ArrayList<>()).add(e));
    var result = new ArrayList<ManagedDesiredPolicy.ApplicationIntent>();
    for (var entry : byApp.entrySet()) {
      var app = apps.get(entry.getKey());
      PolicyRule.Effect launch = null, install = null;
      var permissions = new TreeMap<String, RuntimePermissionDecision>();
      var ids = new TreeSet<String>();
      for (var evaluation : entry.getValue()) {
        ids.addAll(evaluation.sourceRuleIds());
        switch (evaluation.kind()) {
          case APP_LAUNCH -> launch = evaluation.predictedEffect();
          case APP_INSTALL -> install = evaluation.predictedEffect();
          case RUNTIME_PERMISSION -> {
            if (evaluation.predictedEffect() != DENY && evaluation.predictedEffect() != DEFAULT)
              throw reject("EXECUTION_RULE_EFFECT_UNSUPPORTED");
            permissions.put(
                evaluation.permission(),
                new RuntimePermissionDecision(
                    evaluation.permission(),
                    evaluation.predictedEffect() == DENY
                        ? PermissionDecision.DENY
                        : PermissionDecision.PROMPT));
          }
          default -> throw reject("EXECUTION_RULE_KIND_UNSUPPORTED");
        }
      }
      if (install == DENY && (launch == ALLOW || !permissions.isEmpty()))
        throw reject("EXECUTION_RULE_COMBINATION_UNSUPPORTED");
      var control =
          install == DENY
              ? AppControl.BLOCK_INSTALL
              : launch == DENY ? AppControl.BLOCK_LAUNCH : AppControl.ALLOW;
      result.add(
          new ManagedDesiredPolicy.ApplicationIntent(
              app.id(),
              app.packageName(),
              app.profile().name(),
              app.signingDigests().stream().sorted().toList(),
              control,
              List.copyOf(permissions.values()),
              List.copyOf(ids)));
    }
    result.sort(Comparator.comparing(ManagedDesiredPolicy.ApplicationIntent::packageName));
    return new ManagedDesiredPolicy(
        publication,
        target.deviceId(),
        target.registrationId(),
        result,
        List.copyOf(readiness.values()),
        List.copyOf(protections));
  }

  private PolicyRule.Effect effect(List<PolicyRule> group) {
    var effects =
        group.stream().map(PolicyRule::effect).collect(java.util.stream.Collectors.toSet());
    if (effects.contains(DENY)) return DENY;
    if (effects.contains(DEFAULT)) return DEFAULT;
    if (effects.contains(GRANT)) return GRANT;
    return ALLOW;
  }

  private boolean id(String value) {
    return value != null
        && value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
  }

  private boolean pkg(String value) {
    return value != null
        && value.length() <= 255
        && value.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+");
  }

  private DomainException invalid() {
    return reject("EXECUTION_SOURCE_INVALID");
  }

  private DomainException coverage() {
    return reject("EXECUTION_RULE_COVERAGE_INVALID");
  }

  private DomainException reject(String code) {
    return new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, code);
  }
}
