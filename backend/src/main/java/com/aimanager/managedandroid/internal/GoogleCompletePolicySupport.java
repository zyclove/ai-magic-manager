package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway.*;
import com.aimanager.managedandroid.ManagedPolicyWriteException;
import com.aimanager.managedandroid.ManagedPolicyWriteException.Outcome;
import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.google.api.client.http.HttpHeaders;
import com.google.api.client.http.HttpRequest;
import com.google.api.client.http.HttpResponseException;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import java.io.IOException;
import java.util.Set;
import java.util.TreeMap;

/**
 * Whole-document transport. No assignment, scheduler, ownership proof or automatic write retry.
 * Google PATCH is an upsert: the caller must separately reserve and authorize the resource.
 */
final class GoogleCompletePolicySupport {
  private static final org.slf4j.Logger LOG =
      org.slf4j.LoggerFactory.getLogger(GoogleCompletePolicySupport.class);
  private static final int MAX_BYTES = 1024 * 1024;
  private static final String FIELDS =
      "applications,defaultPermissionPolicy,playStoreMode,statusReportingSettings";
  private static final ObjectMapper JSON =
      new ObjectMapper(
              JsonFactory.builder().enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build())
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
  private final AndroidManagement client;
  private final Set<String> protectedPackages;

  GoogleCompletePolicySupport(AndroidManagement client, Set<String> protectedPackages) {
    this.client = client;
    this.protectedPackages = protectedPackages;
  }

  PolicyReceipt write(String name, PolicyDocument document) {
    var prepared = prepare(name, document);
    try {
      // A known existing resource is never overwritten, including one with matching content.
      if (read(client.enterprises().policies().get(name).buildHttpRequest(), name, true) != null)
        throw new ManagedPolicyWriteException(Outcome.NOT_DISPATCHED);
    } catch (IOException | RuntimeException failure) {
      recordFailure("preflight", failure);
      throw new ManagedPolicyWriteException(Outcome.NOT_DISPATCHED);
    }
    try {
      var observed =
          read(
              client
                  .enterprises()
                  .policies()
                  .patch(name, prepared.compiled().requestBody())
                  .setUpdateMask(FIELDS)
                  .buildHttpRequest(),
              name,
              false);
      if (!prepared.content().equals(observed.content())) throw invalidResponse();
      return new PolicyReceipt(name, observed.version());
    } catch (IOException | RuntimeException failure) {
      recordFailure("write", failure);
      // A transport error, invalid identity or mismatched response cannot establish non-delivery.
      throw new ManagedPolicyWriteException(Outcome.OUTCOME_UNKNOWN);
    }
  }

  CompletePolicyInspection inspect(String name, PolicyDocument document, Long expectedVersion) {
    if (expectedVersion != null && expectedVersion < 1)
      throw new IllegalArgumentException("Invalid expected policy version");
    var prepared = prepare(name, document);
    try {
      var observed = read(client.enterprises().policies().get(name).buildHttpRequest(), name, true);
      if (observed == null)
        return new CompletePolicyInspection(name, null, CompletePolicyState.NOT_FOUND);
      var state =
          expectedVersion != null && !expectedVersion.equals(observed.version())
              ? CompletePolicyState.VERSION_MISMATCH
              : prepared.content().equals(observed.content())
                  ? CompletePolicyState.MATCHED
                  : CompletePolicyState.CONTENT_MISMATCH;
      return new CompletePolicyInspection(name, observed.version(), state);
    } catch (IOException | RuntimeException failure) {
      recordFailure("read", failure);
      throw new IllegalStateException("Managed complete policy read failed");
    }
  }

  private Prepared prepare(String name, PolicyDocument document) {
    if (name == null
        || !name.matches("enterprises/[A-Za-z0-9_-]{1,128}/policies/aim_[0-9a-f]{32}")
        || document == null)
      throw new IllegalArgumentException("Invalid complete policy candidate");
    var compiled =
        new GoogleCompletePolicyCompiler(document.agentPackage(), protectedPackages)
            .restore(
                document.documentJson(),
                document.sha256(),
                document.apiLevel(),
                document.managementMode());
    try {
      return new Prepared(
          compiled, normalize((ObjectNode) JSON.readTree(compiled.documentJson()).path("policy")));
    } catch (IOException | RuntimeException invalid) {
      throw new IllegalArgumentException("Invalid complete policy document");
    }
  }

  /** A null observation is reserved for an actual HTTP 404, before parsing an error body. */
  private Observed read(HttpRequest request, String name, boolean allowMissing) throws IOException {
    request.setNumberOfRetries(0).setFollowRedirects(false).setThrowExceptionOnExecuteError(false);
    request.setIOExceptionHandler(null).setUnsuccessfulResponseHandler(null);
    request.setLoggingEnabled(false).setCurlLoggingEnabled(false);
    request.setConnectTimeout(timeout(request.getConnectTimeout(), 10000));
    request.setReadTimeout(timeout(request.getReadTimeout(), 15000));
    var response = request.execute();
    try {
      if (allowMissing && response.getStatusCode() == 404) return null;
      if (!response.isSuccessStatusCode())
        throw new HttpResponseException.Builder(
                response.getStatusCode(),
                "Managed complete policy request failed",
                new HttpHeaders())
            .build();
      try (var input = response.getContent()) {
        if (input == null) throw invalidResponse();
        byte[] bytes = input.readNBytes(MAX_BYTES + 1);
        if (bytes.length > MAX_BYTES) throw invalidResponse();
        var root = JSON.readTree(bytes);
        if (root == null
            || !root.isObject()
            || !root.path("name").isTextual()
            || !name.equals(root.path("name").textValue())) throw invalidResponse();
        var value = root.get("version");
        long version;
        if (value != null && value.isIntegralNumber() && value.canConvertToLong())
          version = value.longValue();
        else if (value != null
            && value.isTextual()
            && value.textValue().matches("[1-9][0-9]{0,18}"))
          version = Long.parseLong(value.textValue());
        else throw invalidResponse();
        if (version < 1) throw invalidResponse();
        var body = (ObjectNode) root;
        body.remove("name");
        body.remove("version");
        return new Observed(version, normalize(body));
      }
    } finally {
      response.disconnect();
    }
  }

  /** Normalize only known equivalent defaults. Extra fields survive comparison and cannot match. */
  private ObjectNode normalize(ObjectNode policy) {
    textIfPresent(policy, "playStoreMode");
    textIfPresent(policy, "defaultPermissionPolicy");
    var reporting = policy.get("statusReportingSettings");
    if (reporting != null) {
      if (!reporting.isObject()) throw invalidResponse();
      booleanIfPresent(reporting, "applicationReportsEnabled");
    }
    var applications = policy.get("applications");
    var sorted = new TreeMap<String, ObjectNode>();
    if (applications != null) {
      if (!applications.isArray() || applications.size() > 200) throw invalidResponse();
      for (var entry : applications) {
        if (!entry.isObject()) throw invalidResponse();
        var app = (ObjectNode) entry;
        var name = app.get("packageName");
        if (name == null
            || !name.isTextual()
            || name.textValue().length() > 255
            || !name.textValue().matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+")
            || sorted.putIfAbsent(name.textValue(), app) != null) throw invalidResponse();
        textIfPresent(app, "installType");
        textIfPresent(app, "userControlSettings");
        if (!app.has("installType")
            || "INSTALL_TYPE_UNSPECIFIED".equals(app.path("installType").textValue()))
          app.put("installType", "AVAILABLE");
        booleanIfPresent(app, "disabled");
        if (!app.has("disabled")) app.put("disabled", false);
        var grants = app.get("permissionGrants");
        var permissions = new TreeMap<String, JsonNode>();
        if (grants != null) {
          if (!grants.isArray() || grants.size() > 64) throw invalidResponse();
          for (var grant : grants) {
            if (!grant.isObject()
                || !grant.path("permission").isTextual()
                || grant.path("permission").textValue().isBlank()
                || !grant.path("policy").isTextual()
                || grant.path("policy").textValue().isBlank()
                || permissions.putIfAbsent(grant.path("permission").textValue(), grant) != null)
              throw invalidResponse();
          }
        }
        var normalized = app.putArray("permissionGrants");
        permissions.values().forEach(normalized::add);
      }
    }
    var normalized = policy.putArray("applications");
    sorted.values().forEach(normalized::add);
    return policy;
  }

  private void textIfPresent(JsonNode object, String key) {
    if (object.has(key) && !object.get(key).isTextual()) throw invalidResponse();
  }

  private void booleanIfPresent(JsonNode object, String key) {
    if (object.has(key) && !object.get(key).isBoolean()) throw invalidResponse();
  }

  private static int timeout(int configured, int maximum) {
    return configured <= 0 ? maximum : Math.min(configured, maximum);
  }

  private static IllegalStateException invalidResponse() {
    return new IllegalStateException("Invalid complete policy response");
  }

  private static void recordFailure(String phase, Exception failure) {
    int status = failure instanceof HttpResponseException response ? response.getStatusCode() : 0;
    LOG.warn(
        "Managed complete policy operation failed: phase={}, status={}, errorType={}",
        phase,
        status,
        failure.getClass().getSimpleName());
  }

  private record Prepared(GoogleCompletePolicyCompiler.Compiled compiled, ObjectNode content) {
    @Override
    public String toString() {
      return "PreparedPolicy[REDACTED]";
    }
  }

  private record Observed(Long version, ObjectNode content) {
    @Override
    public String toString() {
      return "ObservedPolicy[REDACTED]";
    }
  }
}
