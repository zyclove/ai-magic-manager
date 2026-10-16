package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway.AppControl;
import com.aimanager.managedandroid.ManagedAndroidGateway.AppRestriction;
import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.ObjectReader;
import com.google.api.client.http.HttpHeaders;
import com.google.api.client.http.HttpRequest;
import com.google.api.client.http.HttpResponseException;
import com.google.api.client.util.Data;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.google.api.services.androidmanagement.v1.model.ApplicationPolicy;
import com.google.api.services.androidmanagement.v1.model.Policy;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeMap;
import java.util.regex.Pattern;

/** Bounded transport and semantic checks for whole applications-field replacement only. */
final class GoogleApplicationPolicySupport {
  private static final int MAX_BYTES = 1024 * 1024;
  private static final int MAX_APPLICATIONS = 3000;
  private static final Pattern PACKAGE =
      Pattern.compile("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+");
  private static final ObjectReader JSON =
      new ObjectMapper(
              JsonFactory.builder().enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build())
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .reader();

  private GoogleApplicationPolicySupport() {}

  static List<ApplicationPolicy> requested(
      List<AppRestriction> rules, Set<String> protectedPackages) {
    Objects.requireNonNull(rules, "rules");
    if (rules.size() > MAX_APPLICATIONS)
      throw new IllegalArgumentException("Too many application rules");
    var seen = new HashSet<String>();
    var result = new ArrayList<ApplicationPolicy>();
    for (var rule : rules) {
      Objects.requireNonNull(rule, "rule");
      if (!validPackage(rule.packageName()) || !seen.add(rule.packageName()))
        throw new IllegalArgumentException("Invalid or duplicate application package");
      var control = Objects.requireNonNull(rule.control(), "control");
      if (control != AppControl.ALLOW
          && protectedPackages.contains(rule.packageName().toLowerCase(Locale.ROOT)))
        throw new IllegalArgumentException("A safety-critical application cannot be blocked");
      var app = new ApplicationPolicy().setPackageName(rule.packageName());
      switch (control) {
        case ALLOW -> app.setInstallType("AVAILABLE").setDisabled(false);
        case BLOCK_LAUNCH -> app.setInstallType("AVAILABLE").setDisabled(true);
        case BLOCK_INSTALL -> app.setInstallType("BLOCKED");
      }
      result.add(app);
    }
    result.sort(Comparator.comparing(ApplicationPolicy::getPackageName));
    return List.copyOf(result);
  }

  /** Null means a confirmed HTTP 404 only, never a parser, transport or identity failure. */
  static Policy read(
      AndroidManagement client, HttpRequest request, String name, boolean allowMissing)
      throws IOException {
    request.setNumberOfRetries(0).setFollowRedirects(false).setThrowExceptionOnExecuteError(false);
    request.setLoggingEnabled(false).setCurlLoggingEnabled(false);
    request.setConnectTimeout(boundedTimeout(request.getConnectTimeout(), 10000));
    request.setReadTimeout(boundedTimeout(request.getReadTimeout(), 15000));
    var response = request.execute();
    try {
      if (allowMissing && response.getStatusCode() == 404) return null;
      if (!response.isSuccessStatusCode())
        throw new HttpResponseException.Builder(
                response.getStatusCode(),
                "Managed application policy request failed",
                new HttpHeaders())
            .build();
      try (var input = response.getContent()) {
        if (input == null) throw invalid();
        byte[] bytes = input.readNBytes(MAX_BYTES + 1);
        if (bytes.length > MAX_BYTES) throw invalid();
        final Policy policy;
        try {
          JsonNode tree = JSON.readTree(bytes);
          validateShape(tree);
          policy =
              client
                  .getJsonFactory()
                  .fromInputStream(
                      new ByteArrayInputStream(bytes), StandardCharsets.UTF_8, Policy.class);
        } catch (IOException | RuntimeException malformed) {
          throw invalid();
        }
        if (policy == null
            || Data.isNull(policy)
            || !name.equals(policy.getName())
            || policy.getVersion() == null
            || Data.isNull(policy.getVersion())
            || policy.getVersion() < 1) throw invalid();
        return policy;
      }
    } finally {
      response.disconnect();
    }
  }

  private static int boundedTimeout(int configured, int maximum) {
    return configured <= 0 ? maximum : Math.min(configured, maximum);
  }

  /** Check JSON types before the generated SDK can coerce strings into booleans or numbers. */
  private static void validateShape(JsonNode policy) {
    if (policy == null || !policy.isObject()) throw invalid();
    requireString(policy, "name");
    requireString(policy, "playStoreMode");
    requireBoolean(policy, "installAppsDisabled");
    JsonNode version = policy.get("version");
    if (version == null || !(version.isTextual() || version.isIntegralNumber())) throw invalid();
    if (version.isTextual() && !version.textValue().matches("[1-9][0-9]{0,18}")) throw invalid();
    if (version.isIntegralNumber() && (!version.canConvertToLong() || version.longValue() < 1))
      throw invalid();
    JsonNode apps = policy.get("applications");
    if (apps == null) return;
    if (!apps.isArray() || apps.size() > MAX_APPLICATIONS) throw invalid();
    for (JsonNode app : apps) {
      if (!app.isObject()) throw invalid();
      var fields = app.fields();
      while (fields.hasNext()) {
        var field = fields.next();
        var value = field.getValue();
        if (value.isNull()) throw invalid();
        switch (field.getKey()) {
          case "packageName", "installType", "defaultPermissionPolicy", "autoUpdateMode" -> {
            if (!value.isTextual()) throw invalid();
          }
          case "disabled" -> {
            if (!value.isBoolean()) throw invalid();
          }
          case "permissionGrants", "delegatedScopes" -> {
            if (!value.isArray()) throw invalid();
          }
          case "managedConfiguration" -> {
            if (!value.isObject()) throw invalid();
          }
          default -> {
            /* Unknown fields remain unsupported by the semantic matcher. */
          }
        }
      }
    }
  }

  private static void requireString(JsonNode object, String key) {
    JsonNode value = object.get(key);
    if (value != null && !value.isTextual()) throw invalid();
  }

  private static void requireBoolean(JsonNode object, String key) {
    JsonNode value = object.get(key);
    if (value != null && !value.isBoolean()) throw invalid();
  }

  static boolean safeMode(Policy policy) {
    return "BLACKLIST".equals(policy.getPlayStoreMode())
        && (policy.getInstallAppsDisabled() == null
            || (!Data.isNull(policy.getInstallAppsDisabled()) && !policy.getInstallAppsDisabled()));
  }

  /**
   * Reject unsupported existing application semantics before replacing, rather than clearing them.
   */
  static boolean replaceable(Policy policy) {
    var existing = controls(policy.getApplications());
    return safeMode(policy) && existing != null;
  }

  static boolean matches(Policy policy, List<ApplicationPolicy> desired) {
    var actual = controls(policy.getApplications());
    return safeMode(policy) && actual != null && actual.equals(controls(desired));
  }

  /** Null means valid but outside this narrow control vocabulary; malformed reports throw. */
  private static Map<String, AppControl> controls(List<ApplicationPolicy> apps) {
    if (apps == null) return Map.of();
    if (Data.isNull(apps) || apps.size() > MAX_APPLICATIONS) throw invalid();
    var result = new TreeMap<String, AppControl>();
    boolean supported = true;
    var seen = new HashSet<String>();
    for (var app : apps) {
      if (app == null
          || Data.isNull(app)
          || !validPackage(app.getPackageName())
          || !seen.add(app.getPackageName())) throw invalid();
      for (var field : app.keySet()) {
        Object value = app.get(field);
        if (Data.isNull(value)) throw invalid();
        switch (field) {
          case "packageName", "installType", "disabled" -> {}
          case "permissionGrants", "delegatedScopes" -> {
            if (!(value instanceof List<?> list) || !list.isEmpty()) supported = false;
          }
          case "managedConfiguration" -> {
            if (!(value instanceof Map<?, ?> map) || !map.isEmpty()) supported = false;
          }
          case "defaultPermissionPolicy" -> {
            if (!"PERMISSION_POLICY_UNSPECIFIED".equals(value)) supported = false;
          }
          case "autoUpdateMode" -> {
            if (!Set.of("AUTO_UPDATE_MODE_UNSPECIFIED", "AUTO_UPDATE_DEFAULT").contains(value))
              supported = false;
          }
          default -> supported = false;
        }
      }
      String install = app.getInstallType();
      if (install == null || "INSTALL_TYPE_UNSPECIFIED".equals(install)) install = "AVAILABLE";
      boolean disabled = Boolean.TRUE.equals(app.getDisabled());
      switch (install) {
        case "AVAILABLE" ->
            result.put(app.getPackageName(), disabled ? AppControl.BLOCK_LAUNCH : AppControl.ALLOW);
        // Explicit disabled=true adds an unrequested field even though installation is blocked.
        case "BLOCKED" -> {
          if (disabled) supported = false;
          result.put(app.getPackageName(), AppControl.BLOCK_INSTALL);
        }
        default -> supported = false;
      }
    }
    return supported ? result : null;
  }

  private static boolean validPackage(String name) {
    return name != null && name.length() <= 255 && PACKAGE.matcher(name).matches();
  }

  private static IllegalStateException invalid() {
    return new IllegalStateException("Invalid managed application policy response");
  }
}
