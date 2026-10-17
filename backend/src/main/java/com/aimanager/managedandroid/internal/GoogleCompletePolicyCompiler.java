package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway.AppControl;
import com.aimanager.managedandroid.ManagedAndroidGateway.AppRestriction;
import com.aimanager.managedandroid.ManagedAndroidGateway.PermissionDecision;
import com.aimanager.managedandroid.ManagedAndroidGateway.RuntimePermissionDecision;
import com.aimanager.managedandroid.ManagedDesiredPolicy;
import com.aimanager.shared.AndroidRuntimePermissions;
import com.aimanager.shared.SafetyCriticalPackages;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.model.ApplicationPolicy;
import com.google.api.services.androidmanagement.v1.model.PermissionGrant;
import com.google.api.services.androidmanagement.v1.model.Policy;
import com.google.api.services.androidmanagement.v1.model.StatusReportingSettings;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.regex.Pattern;

/**
 * Pure, versioned compiler for a NEW exclusively owned Google policy resource. It does not patch
 * existing policies, activate an adapter, verify device authority or perform network I/O. Inputs
 * must contain the whole resolved application/permission policy, not a partial UI edit.
 */
final class GoogleCompletePolicyCompiler {
  static final String REVISION = "google-complete-policy-v1";
  private static final int MAX_BYTES = 65536;
  private static final int MAX_APPS = 200;
  private static final Pattern PACKAGE =
      Pattern.compile("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+");
  private static final GsonFactory SDK_JSON = GsonFactory.getDefaultInstance();
  private static final ObjectMapper JSON =
      new ObjectMapper(
              JsonFactory.builder().enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build())
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);
  private final String agentPackage;
  private final Set<String> protectedPackages;

  /** The agent package comes from verified deployment/binding configuration, never child input. */
  GoogleCompletePolicyCompiler(String agentPackage, Set<String> protectedPackages) {
    requirePackage(agentPackage);
    if (protectedPackages == null) throw invalid();
    var safety = new HashSet<>(SafetyCriticalPackages.withAdditional(""));
    for (String pkg : protectedPackages) {
      requirePackage(pkg);
      safety.add(pkg.toLowerCase(Locale.ROOT));
    }
    safety.add(agentPackage.toLowerCase(Locale.ROOT));
    this.agentPackage = agentPackage;
    this.protectedPackages = Set.copyOf(safety);
  }

  /** Compile-time input only. The compiled result never retains caller collections. */
  record AppPermissions(String packageName, List<RuntimePermissionDecision> decisions) {}

  /** Immutable bytes and digest; mutable generated SDK objects are fresh copies on every call. */
  static final class Compiled {
    private final String documentJson;
    private final String policyJson;
    private final String sha256;

    private Compiled(String documentJson, String policyJson) {
      this.documentJson = documentJson;
      this.policyJson = policyJson;
      this.sha256 = SecretMaterial.hash(documentJson);
    }

    String documentJson() {
      return documentJson;
    }

    String sha256() {
      return sha256;
    }

    Policy requestBody() {
      try {
        return SDK_JSON.fromString(policyJson, Policy.class);
      } catch (java.io.IOException malformed) {
        throw new IllegalStateException("Compiled policy decoding failed");
      }
    }

    @Override
    public String toString() {
      return "CompiledManagedPolicy[REDACTED]";
    }
  }

  Compiled compile(
      int apiLevel,
      String managementMode,
      List<AppRestriction> controls,
      List<AppPermissions> permissions) {
    requireOwner(apiLevel, managementMode);
    if (controls == null
        || permissions == null
        || controls.size() > MAX_APPS
        || permissions.size() > MAX_APPS) throw invalid();
    var apps = new TreeMap<String, ApplicationPolicy>();
    for (var control : controls) {
      if (control == null || control.control() == null) throw invalid();
      requirePackage(control.packageName());
      if (apps.containsKey(control.packageName())) throw invalid();
      if (control.control() != AppControl.ALLOW && isProtected(control.packageName()))
        throw invalid();
      apps.put(control.packageName(), application(control.packageName(), control.control()));
    }
    var seen = new HashSet<String>();
    for (var group : permissions) {
      if (group == null) throw invalid();
      requirePackage(group.packageName());
      if (!seen.add(group.packageName())
          || group.decisions() == null
          || group.decisions().size() > 64) throw invalid();
      var grants = new TreeMap<String, PermissionGrant>();
      for (var decision : group.decisions()) {
        if (decision == null
            || decision.decision() == null
            || !AndroidRuntimePermissions.contains(decision.permission())
            || grants.containsKey(decision.permission())) throw invalid();
        if (decision.decision() == PermissionDecision.DENY && isProtected(group.packageName()))
          throw invalid();
        grants.put(
            decision.permission(),
            new PermissionGrant()
                .setPermission(decision.permission())
                .setPolicy(decision.decision().name()));
      }
      // The management application uses the fixed PROMPT baseline; no rule can alter its
      // permissions.
      if (agentPackage.equals(group.packageName()) && !grants.isEmpty()) throw invalid();
      var app =
          apps.computeIfAbsent(group.packageName(), pkg -> application(pkg, AppControl.ALLOW));
      if ("BLOCKED".equals(app.getInstallType()) && !grants.isEmpty()) throw invalid();
      app.setPermissionGrants(List.copyOf(grants.values()));
    }
    apps.put(
        agentPackage,
        new ApplicationPolicy()
            .setPackageName(agentPackage)
            .setInstallType("FORCE_INSTALLED")
            .setDisabled(false)
            .setPermissionGrants(List.of())
            .setUserControlSettings("USER_CONTROL_DISALLOWED"));
    if (apps.size() > MAX_APPS) throw invalid();
    Policy policy =
        new Policy()
            .setPlayStoreMode("BLACKLIST")
            .setDefaultPermissionPolicy("PROMPT")
            .setApplications(List.copyOf(apps.values()))
            .setStatusReportingSettings(
                new StatusReportingSettings().setApplicationReportsEnabled(true));
    try {
      String body = SDK_JSON.toString(policy);
      Map<?, ?> payload = JSON.readValue(body, Map.class);
      String document =
          JSON.writeValueAsString(
              Map.of("schemaVersion", 1, "adapterRevision", REVISION, "policy", payload));
      if (document.getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) throw invalid();
      return new Compiled(document, JSON.writeValueAsString(payload));
    } catch (java.io.IOException malformed) {
      throw new IllegalStateException("Policy compilation failed");
    }
  }

  /**
   * Consume the entire publication translation. API/mode must be independently verified; frozen
   * readiness and catalog declarations are intentionally not promoted into execution authority.
   */
  Compiled compileDesired(int apiLevel, String verifiedMode, ManagedDesiredPolicy desired) {
    if (desired == null) throw invalid();
    var protections = new HashSet<>(protectedPackages);
    protections.addAll(desired.protectedPackages());
    var complete = new GoogleCompletePolicyCompiler(agentPackage, protections);
    var controls = new ArrayList<AppRestriction>();
    var permissions = new ArrayList<AppPermissions>();
    for (var app : desired.applications()) {
      if (!"PRIMARY".equals(app.profile())) throw invalid();
      controls.add(new AppRestriction(app.packageName(), app.control()));
      if (!app.permissions().isEmpty())
        permissions.add(new AppPermissions(app.packageName(), app.permissions()));
    }
    return complete.compile(apiLevel, verifiedMode, controls, permissions);
  }

  /**
   * Restore only our exact canonical dialect and configured management application. Hash equality
   * detects accidental substitution; it is not authentication or evidence of provider ownership.
   * Recompilation rejects additional fields and does not silently strip an unsupported policy.
   */
  Compiled restore(String document, String expectedSha256, int apiLevel, String managementMode) {
    requireOwner(apiLevel, managementMode);
    if (document == null
        || document.getBytes(StandardCharsets.UTF_8).length > MAX_BYTES
        || expectedSha256 == null
        || !expectedSha256.matches("[0-9a-f]{64}")
        || !expectedSha256.equals(SecretMaterial.hash(document))) throw invalid();
    try {
      JsonNode root = JSON.readTree(document);
      requireFields(root, Set.of("schemaVersion", "adapterRevision", "policy"));
      if (!root.path("schemaVersion").isInt()
          || root.path("schemaVersion").intValue() != 1
          || !REVISION.equals(text(root, "adapterRevision"))) throw invalid();
      JsonNode policy = root.path("policy");
      requireFields(
          policy,
          Set.of(
              "applications",
              "defaultPermissionPolicy",
              "playStoreMode",
              "statusReportingSettings"));
      if (!"BLACKLIST".equals(text(policy, "playStoreMode"))
          || !"PROMPT".equals(text(policy, "defaultPermissionPolicy"))) throw invalid();
      var reports = policy.path("statusReportingSettings");
      requireFields(reports, Set.of("applicationReportsEnabled"));
      if (!bool(reports, "applicationReportsEnabled")) throw invalid();
      var apps = policy.path("applications");
      if (!apps.isArray() || apps.size() < 1 || apps.size() > MAX_APPS) throw invalid();
      var controls = new ArrayList<AppRestriction>();
      var permissions = new ArrayList<AppPermissions>();
      int agents = 0;
      for (var app : apps) {
        String pkg = text(app, "packageName");
        boolean agent = agentPackage.equals(pkg);
        requireFields(
            app,
            agent
                ? Set.of(
                    "packageName",
                    "installType",
                    "disabled",
                    "permissionGrants",
                    "userControlSettings")
                : Set.of("packageName", "installType", "disabled", "permissionGrants"));
        boolean disabled = bool(app, "disabled");
        String install = text(app, "installType");
        if (agent) {
          agents++;
          if (!"FORCE_INSTALLED".equals(install)
              || disabled
              || !"USER_CONTROL_DISALLOWED".equals(text(app, "userControlSettings")))
            throw invalid();
        } else {
          AppControl control;
          if ("AVAILABLE".equals(install))
            control = disabled ? AppControl.BLOCK_LAUNCH : AppControl.ALLOW;
          else if ("BLOCKED".equals(install) && !disabled) control = AppControl.BLOCK_INSTALL;
          else throw invalid();
          controls.add(new AppRestriction(pkg, control));
        }
        var grants = app.path("permissionGrants");
        if (!grants.isArray() || grants.size() > 64) throw invalid();
        var values = new ArrayList<RuntimePermissionDecision>();
        for (var grant : grants) {
          requireFields(grant, Set.of("permission", "policy"));
          values.add(
              new RuntimePermissionDecision(
                  text(grant, "permission"), PermissionDecision.valueOf(text(grant, "policy"))));
        }
        permissions.add(new AppPermissions(pkg, values));
      }
      if (agents != 1) throw invalid();
      var restored = compile(apiLevel, managementMode, controls, permissions);
      if (!restored.documentJson().equals(document)) throw invalid();
      return restored;
    } catch (java.io.IOException | RuntimeException malformed) {
      throw invalid();
    }
  }

  private static ApplicationPolicy application(String pkg, AppControl control) {
    return new ApplicationPolicy()
        .setPackageName(pkg)
        .setInstallType(control == AppControl.BLOCK_INSTALL ? "BLOCKED" : "AVAILABLE")
        .setDisabled(control == AppControl.BLOCK_LAUNCH)
        .setPermissionGrants(List.of());
  }

  private boolean isProtected(String pkg) {
    return protectedPackages.contains(pkg.toLowerCase(Locale.ROOT));
  }

  private static void requireOwner(int api, String mode) {
    if (api < 30 || !"DEVICE_OWNER".equals(mode)) throw invalid();
  }

  private static void requirePackage(String pkg) {
    if (pkg == null || pkg.length() > 255 || !PACKAGE.matcher(pkg).matches()) throw invalid();
  }

  private static void requireFields(JsonNode value, Set<String> expected) {
    if (value == null || !value.isObject() || value.size() != expected.size()) throw invalid();
    var names = new HashSet<String>();
    value.fieldNames().forEachRemaining(names::add);
    if (!names.equals(expected)) throw invalid();
  }

  private static String text(JsonNode value, String name) {
    var field = value.path(name);
    if (!field.isTextual()) throw invalid();
    return field.textValue();
  }

  private static boolean bool(JsonNode value, String name) {
    var field = value.path(name);
    if (!field.isBoolean()) throw invalid();
    return field.booleanValue();
  }

  private static IllegalArgumentException invalid() {
    return new IllegalArgumentException("Invalid or unsupported complete managed policy");
  }
}
