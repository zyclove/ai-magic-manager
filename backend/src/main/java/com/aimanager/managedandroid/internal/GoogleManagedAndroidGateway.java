package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.shared.SafetyCriticalPackages;
import com.google.api.client.googleapis.json.GoogleJsonResponseException;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.google.api.services.androidmanagement.v1.model.ApplicationPolicy;
import com.google.api.services.androidmanagement.v1.model.Device;
import com.google.api.services.androidmanagement.v1.model.EnrollmentToken;
import com.google.api.services.androidmanagement.v1.model.NonComplianceDetail;
import com.google.api.services.androidmanagement.v1.model.Policy;
import java.io.IOException;
import java.time.Duration;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Official generated Google client adapter. It is intentionally not an HTTP controller. */
public final class GoogleManagedAndroidGateway implements ManagedAndroidGateway {
  private static final Logger LOG = LoggerFactory.getLogger(GoogleManagedAndroidGateway.class);
  private static final Pattern RESOURCE_ID = Pattern.compile("[A-Za-z0-9_-]{1,128}");
  private static final Pattern PACKAGE =
      Pattern.compile("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+");
  private static final Pattern ENROLLMENT_NONCE = Pattern.compile("[A-Za-z0-9_-]{32,128}");
  private static final int MAX_APPLICATIONS = 3000;
  private final AndroidManagement client;
  private final Set<String> protectedPackages;

  public GoogleManagedAndroidGateway(AndroidManagement client) {
    this(client, SafetyCriticalPackages.withAdditional(""));
  }

  public GoogleManagedAndroidGateway(AndroidManagement client, Set<String> protectedPackages) {
    this.client = Objects.requireNonNull(client);
    var safety = new HashSet<>(SafetyCriticalPackages.withAdditional(""));
    Objects.requireNonNull(protectedPackages).stream()
        .map(String::strip)
        .filter(value -> !value.isEmpty())
        .map(value -> value.toLowerCase(Locale.ROOT))
        .forEach(safety::add);
    this.protectedPackages = Set.copyOf(safety);
  }

  @Override
  public boolean available() {
    return true;
  }

  @Override
  public PolicyReceipt putApplicationPolicy(
      String enterpriseId, String policyId, List<AppRestriction> rules) {
    String name = policyName(enterpriseId, policyId);
    Objects.requireNonNull(rules, "rules");
    if (rules.size() > MAX_APPLICATIONS)
      throw new IllegalArgumentException("Too many application rules");
    Set<String> seen = new HashSet<>();
    List<ApplicationPolicy> applications =
        rules.stream()
            .map(
                rule -> {
                  Objects.requireNonNull(rule, "rule");
                  String packageName = Objects.requireNonNull(rule.packageName(), "packageName");
                  if (!PACKAGE.matcher(packageName).matches() || !seen.add(packageName)) {
                    throw new IllegalArgumentException("Invalid or duplicate application package");
                  }
                  AppControl control = Objects.requireNonNull(rule.control(), "control");
                  if (control != AppControl.ALLOW
                      && protectedPackages.contains(packageName.toLowerCase(Locale.ROOT))) {
                    throw new IllegalArgumentException(
                        "A safety-critical application cannot be blocked");
                  }
                  ApplicationPolicy app = new ApplicationPolicy().setPackageName(packageName);
                  return switch (control) {
                    case ALLOW -> app.setInstallType("AVAILABLE").setDisabled(false);
                    case BLOCK_LAUNCH -> app.setInstallType("AVAILABLE").setDisabled(true);
                    case BLOCK_INSTALL -> app.setInstallType("BLOCKED");
                  };
                })
            .toList();
    try {
      // An unspecified Play Store mode defaults to WHITELIST: replacing applications could
      // uninstall every app omitted from this list. Only an explicitly provisioned, exclusively
      // owned BLACKLIST policy may be updated by this narrow adapter.
      Policy existing = client.enterprises().policies().get(name).execute();
      if (existing == null
          || !name.equals(existing.getName())
          || !"BLACKLIST".equals(existing.getPlayStoreMode())
          || Boolean.TRUE.equals(existing.getInstallAppsDisabled())) {
        LOG.warn("Android management application policy preflight rejected: unsafe policy mode");
        throw new IllegalStateException(
            "Managed application policy is not explicitly provisioned for blocklist updates");
      }
      Policy result =
          client
              .enterprises()
              .policies()
              .patch(name, new Policy().setApplications(applications))
              .setUpdateMask("applications")
              .execute();
      if (result == null || result.getVersion() == null || result.getVersion() < 1) {
        throw new IllegalStateException("Android management policy response has no valid version");
      }
      return new PolicyReceipt(name, result.getVersion());
    } catch (GoogleJsonResponseException error) {
      if (error.getStatusCode() == 404) {
        LOG.warn("Android management application policy preflight rejected: policy missing");
        throw new IllegalStateException(
            "Managed application policy must be provisioned before application updates");
      }
      throw providerFailure("policy patch", error);
    } catch (IOException error) {
      throw providerFailure("policy patch", error);
    }
  }

  @Override
  public EnterpriseIdentity readEnterprise(String enterpriseId) {
    String name = enterpriseName(enterpriseId);
    try {
      var result = client.enterprises().get(name).execute();
      if (result == null || !name.equals(result.getName())) {
        throw new IllegalStateException("Android management enterprise response identity mismatch");
      }
      return new EnterpriseIdentity(name, result.getEnterpriseDisplayName());
    } catch (IOException error) {
      throw providerFailure("enterprise identity read", error);
    }
  }

  @Override
  public EnrollmentMaterial createEnrollmentToken(
      String enterpriseId, String policyId, Duration lifetime, String additionalData) {
    String enterprise = enterpriseName(enterpriseId);
    String policy = policyName(enterpriseId, policyId);
    Objects.requireNonNull(lifetime, "lifetime");
    if (additionalData != null && !ENROLLMENT_NONCE.matcher(additionalData).matches()) {
      throw new IllegalArgumentException("Invalid opaque enrollment correlation data");
    }
    long seconds = lifetime.getSeconds();
    if (seconds < 300 || seconds > 1800 || lifetime.getNano() != 0) {
      throw new IllegalArgumentException("Enrollment lifetime must be 5-30 whole minutes");
    }
    EnrollmentToken request =
        new EnrollmentToken()
            .setPolicyName(policy)
            .setDuration(seconds + "s")
            .setOneTimeOnly(true)
            .setAllowPersonalUsage("PERSONAL_USAGE_DISALLOWED");
    if (additionalData != null) request.setAdditionalData(additionalData);
    try {
      EnrollmentToken result =
          client.enterprises().enrollmentTokens().create(enterprise, request).execute();
      if (result == null || result.getName() == null || result.getValue() == null) {
        throw new IllegalStateException("Android management enrollment response is incomplete");
      }
      return new EnrollmentMaterial(
          result.getName(), result.getValue(), result.getQrCode(), result.getExpirationTimestamp());
    } catch (IOException error) {
      throw providerFailure("enrollment token create", error);
    }
  }

  @Override
  public ManagedEnrollmentIdentity readEnrollmentIdentity(String enterpriseId, String deviceId) {
    String name = deviceName(enterpriseId, deviceId);
    try {
      Device result = client.enterprises().devices().get(name).execute();
      if (result == null || !name.equals(result.getName())) {
        throw new IllegalStateException("Android management device response identity mismatch");
      }
      return new ManagedEnrollmentIdentity(
          name,
          result.getManagementMode(),
          result.getEnrollmentTime(),
          result.getEnrollmentTokenName(),
          result.getEnrollmentTokenData());
    } catch (IOException error) {
      throw providerFailure("device enrollment identity read", error);
    }
  }

  @Override
  public AssignmentReceipt assignPolicy(String enterpriseId, String deviceId, String policyId) {
    String device = deviceName(enterpriseId, deviceId);
    String policy = policyName(enterpriseId, policyId);
    try {
      client
          .enterprises()
          .devices()
          .patch(device, new Device().setPolicyName(policy))
          .setUpdateMask("policyName")
          .execute();
      return new AssignmentReceipt(device, policy);
    } catch (IOException error) {
      throw providerFailure("device policy assignment", error);
    }
  }

  @Override
  public ManagedDeviceState readDeviceState(
      String enterpriseId, String deviceId, String expectedPolicyId, long expectedVersion) {
    String name = deviceName(enterpriseId, deviceId);
    String expectedPolicy = policyName(enterpriseId, expectedPolicyId);
    if (expectedVersion < 1)
      throw new IllegalArgumentException("Expected policy version must be positive");
    try {
      Device result = client.enterprises().devices().get(name).execute();
      if (result == null || !name.equals(result.getName())) {
        throw new IllegalStateException("Android management device response identity mismatch");
      }
      String requested = result.getPolicyName();
      String applied = result.getAppliedPolicyName();
      ApplyState state =
          !expectedPolicy.equals(requested)
                  || !expectedPolicy.equals(applied)
                  || !("DEVICE_OWNER".equals(result.getManagementMode())
                      || "PROFILE_OWNER".equals(result.getManagementMode()))
                  || result.getAppliedPolicyVersion() == null
                  || result.getAppliedPolicyVersion() < expectedVersion
              ? ApplyState.PENDING
              : Boolean.FALSE.equals(result.getPolicyCompliant())
                  ? ApplyState.NON_COMPLIANT
                  : Boolean.TRUE.equals(result.getPolicyCompliant())
                      ? ApplyState.APPLIED
                      : ApplyState.PENDING;
      List<String> reasons =
          result.getNonComplianceDetails() == null
              ? List.of()
              : result.getNonComplianceDetails().stream()
                  .map(NonComplianceDetail::getNonComplianceReason)
                  .filter(Objects::nonNull)
                  .toList();
      return new ManagedDeviceState(
          name,
          result.getManagementMode(),
          requested,
          applied,
          result.getAppliedPolicyVersion(),
          state,
          reasons,
          result.getLastPolicySyncTime());
    } catch (IOException error) {
      throw providerFailure("device status read", error);
    }
  }

  private static String enterpriseName(String id) {
    return "enterprises/" + validId(id);
  }

  private static String policyName(String enterpriseId, String id) {
    return enterpriseName(enterpriseId) + "/policies/" + validId(id);
  }

  private static String deviceName(String enterpriseId, String id) {
    return enterpriseName(enterpriseId) + "/devices/" + validId(id);
  }

  private static String validId(String id) {
    if (id == null || !RESOURCE_ID.matcher(id).matches())
      throw new IllegalArgumentException("Invalid provider resource ID");
    return id;
  }

  private static IllegalStateException providerFailure(String operation, IOException error) {
    // Google error bodies may contain enrollment secrets or tenant identifiers; never propagate
    // them.
    int status =
        error instanceof GoogleJsonResponseException response ? response.getStatusCode() : 0;
    LOG.warn(
        "Android management operation failed: operation={}, status={}, errorType={}",
        operation,
        status,
        error.getClass().getSimpleName());
    // Keep the transport cause out of propagated exceptions; it can include sensitive response
    // text.
    return new IllegalStateException(
        "Android management " + operation + " failed (HTTP " + status + ")");
  }
}
