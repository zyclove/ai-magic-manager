package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.SecretMaterial;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

/** Coordinates short-lived provider I/O around small database transactions. */
@Service
class ManagedEnrollmentService {
  private static final Logger LOG = LoggerFactory.getLogger(ManagedEnrollmentService.class);
  private static final Pattern RESOURCE_ID = Pattern.compile("[A-Za-z0-9_-]{1,128}");
  private final ManagedEnrollmentStore store;
  private final ManagedAndroidGateway gateway;
  private final Clock clock;
  private final String bootstrapPolicyId;
  private final long maxProviderStatusAgeMillis;

  ManagedEnrollmentService(
      ManagedEnrollmentStore store,
      ManagedAndroidGateway gateway,
      Clock clock,
      @Value("${manager.emm.bootstrap-policy-id:${manager.emm.google.bootstrap-policy-id:}}") String bootstrapPolicyId,
      @Value("${manager.emm.provider-status-max-age-seconds:86400}") long maxProviderStatusAgeSeconds) {
    this.store = store;
    this.gateway = gateway;
    this.clock = clock;
    this.bootstrapPolicyId = bootstrapPolicyId;
    if (maxProviderStatusAgeSeconds < 3600 || maxProviderStatusAgeSeconds > 604800)
      throw new IllegalArgumentException("Invalid EMM provider status age configuration");
    this.maxProviderStatusAgeMillis = maxProviderStatusAgeSeconds * 1000;
    if (!bootstrapPolicyId.isBlank() && !RESOURCE_ID.matcher(bootstrapPolicyId).matches())
      throw new IllegalArgumentException("Invalid configured Android enrollment policy ID");
  }

  /** Secret token/QR is returned once; only metadata and the nonce digest enter the database. */
  Issued issue(String tenant, String actor, String subject) {
    if (!gateway.available() || bootstrapPolicyId.isBlank())
      throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "EMM_UNAVAILABLE");
    String nonce = SecretMaterial.token();
    var prepared = store.prepare(tenant, actor, subject, bootstrapPolicyId, SecretMaterial.hash(nonce));
    ManagedAndroidGateway.EnrollmentMaterial material = null;
    try {
      var baseline = gateway.requireSafeEnrollmentPolicy(prepared.enterpriseId(), bootstrapPolicyId);
      material = gateway.createEnrollmentToken(
          prepared.enterpriseId(), bootstrapPolicyId, Duration.ofMinutes(5), nonce);
      if (material == null || material.value() == null || material.value().isBlank()
          || material.value().length() > 4096
          || material.qrCode() == null || material.qrCode().isBlank()
          || material.qrCode().length() > 16384
          || material.tokenName() == null || material.expiresAt() == null)
        throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_ENROLLMENT_RESPONSE_INVALID");
      var after = gateway.requireSafeEnrollmentPolicy(prepared.enterpriseId(), bootstrapPolicyId);
      if (!baseline.policyName().equals(after.policyName())
          || !baseline.providerVersion().equals(after.providerVersion()))
        throw new DomainException(HttpStatus.CONFLICT, "EMM_ENROLLMENT_POLICY_CHANGED");
      long expires;
      try {
        expires = Instant.parse(material.expiresAt()).toEpochMilli();
      } catch (DateTimeParseException malformed) {
        throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_ENROLLMENT_RESPONSE_INVALID");
      }
      var intent = store.issued(
          tenant, prepared.id(), actor, baseline.providerVersion(), material.tokenName(), expires);
      return new Issued(view(intent), material.value(), material.qrCode());
    } catch (RuntimeException failure) {
      // Creation may have succeeded remotely while a later check failed. Never leave an
      // untracked enrollment token intentionally active.
      boolean cleanupConfirmed = material == null;
      if (material != null && material.tokenName() != null) {
        try {
          gateway.deleteEnrollmentToken(prepared.enterpriseId(), material.tokenName());
          cleanupConfirmed = true;
        } catch (RuntimeException cleanupFailure) {
          LOG.error("Managed enrollment token cleanup failed: intent={}, type={}",
              prepared.id(), cleanupFailure.getClass().getSimpleName());
        }
      }
      try {
        if (cleanupConfirmed || material == null || material.tokenName() == null)
          store.failed(tenant, prepared.id(), actor);
        else store.cleanupFailedIssue(tenant, prepared.id(), actor, material.tokenName());
      } catch (RuntimeException ledgerFailure) {
        LOG.error("Managed enrollment failure record unavailable: intent={}, type={}",
            prepared.id(), ledgerFailure.getClass().getSimpleName());
      }
      throw failure;
    }
  }

  View verify(String tenant, String id, String actor, String providerDeviceId, long version) {
    if (!RESOURCE_ID.matcher(String.valueOf(providerDeviceId)).matches())
      throw DomainException.invalid("INVALID_PROVIDER_DEVICE_ID");
    var intent = store.forVerification(tenant, id, actor);
    var evidence = gateway.readEnrollmentIdentity(intent.enterpriseId(), providerDeviceId);
    if (evidence == null)
      throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_DEVICE_IDENTITY_INVALID");
    var verified = store.verify(tenant, id, actor, providerDeviceId, evidence, version);
    try {
      gateway.deleteEnrollmentToken(verified.enterpriseId(), verified.tokenName());
    } catch (RuntimeException cleanupFailure) {
      LOG.warn("Used managed enrollment token cleanup pending: intent={}, type={}",
          verified.id(), cleanupFailure.getClass().getSimpleName());
    }
    return view(verified);
  }

  View cancel(String tenant, String id, String actor, long version) {
    var intent = store.requestCancel(tenant, id, actor, version);
    if ("CANCELLED".equals(intent.state())) return view(intent);
    // Preserve pending cleanup for the original provider after a connector switch.
    if (!intent.provider().equals(gateway.providerCode())) return view(intent);
    if (intent.tokenName() != null) {
      try {
        gateway.deleteEnrollmentToken(intent.enterpriseId(), intent.tokenName());
      } catch (RuntimeException cleanupFailure) {
        LOG.warn("Managed enrollment cancellation pending: intent={}, type={}",
            intent.id(), cleanupFailure.getClass().getSimpleName());
        return view(intent);
      }
    }
    return view(store.cancelled(tenant, id, actor));
  }

  View get(String tenant, String id, String actor) {
    return view(store.get(tenant, id, actor));
  }

  /** Manual live read of the original enrollment baseline; never certifies the local agent. */
  ProviderStatus providerStatus(String tenant, String id, String actor) {
    var intent = store.forProviderStatus(tenant, id, actor);
    var identity = gateway.readEnrollmentIdentity(intent.enterpriseId(), intent.providerDeviceId());
    ManagedEnrollmentStore.requireProvenance(intent, intent.providerDeviceId(), identity);
    var baseline = gateway.requireSafeEnrollmentPolicy(intent.enterpriseId(), intent.policyId());
    String expectedName = "enterprises/" + intent.enterpriseId() + "/policies/" + intent.policyId();
    if (baseline == null || !expectedName.equals(baseline.policyName())
        || baseline.providerVersion() == null
        || baseline.providerVersion() != intent.policyVersion())
      throw new DomainException(HttpStatus.CONFLICT, "EMM_ENROLLMENT_POLICY_CHANGED");
    var state = gateway.readDeviceState(intent.enterpriseId(), intent.providerDeviceId(),
        intent.policyId(), intent.policyVersion());
    if (state == null
        || !("enterprises/" + intent.enterpriseId() + "/devices/" + intent.providerDeviceId())
            .equals(state.deviceName())
        || !"DEVICE_OWNER".equals(state.managementMode()))
      throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_DEVICE_IDENTITY_INVALID");
    // Re-read provenance after status to avoid presenting a re-enrolled device as this intent.
    ManagedEnrollmentStore.requireProvenance(intent, intent.providerDeviceId(),
        gateway.readEnrollmentIdentity(intent.enterpriseId(), intent.providerDeviceId()));
    // Provider I/O is deliberately outside database locks. Recheck the local authority after
    // those reads so a concurrent binding/contract revocation or intent change cannot be
    // presented as a current provider status for this enrollment.
    if (!intent.equals(store.forProviderStatus(tenant, id, actor)))
      throw new DomainException(HttpStatus.CONFLICT, "MANAGED_ENROLLMENT_CHANGED");
    String result;
    String limitation;
    if (!expectedName.equals(state.requestedPolicyName())
        || (state.appliedPolicyVersion() != null
            && state.appliedPolicyVersion() > intent.policyVersion())) {
      result = "DRIFT";
      limitation = "PROVIDER_POLICY_CHANGED";
    } else if (state.state() == ManagedAndroidGateway.ApplyState.NON_COMPLIANT) {
      result = "NON_COMPLIANT";
      limitation = "PROVIDER_REPORTED_NON_COMPLIANCE";
    } else if (state.state() == ManagedAndroidGateway.ApplyState.APPLIED
        && expectedName.equals(state.appliedPolicyName())
        && state.appliedPolicyVersion() != null
        && state.appliedPolicyVersion() == intent.policyVersion()) {
      result = "APPLIED";
      limitation = null;
    } else {
      result = "PENDING";
      limitation = "PROVIDER_APPLICATION_UNCONFIRMED";
    }
    Long lastSync = null;
    if (state.lastPolicySyncTime() != null) {
      try {
        lastSync = Instant.parse(state.lastPolicySyncTime()).toEpochMilli();
      } catch (DateTimeParseException malformed) {
        throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_DEVICE_STATE_INVALID");
      }
    }
    long checkedAt = clock.millis();
    if (("APPLIED".equals(result) || "NON_COMPLIANT".equals(result))
        && (lastSync == null || lastSync < checkedAt - maxProviderStatusAgeMillis
            || lastSync > checkedAt + 300_000)) {
      result = "STALE";
      limitation = "PROVIDER_REPORT_STALE";
    }
    return new ProviderStatus(intent.id(), intent.tenantId(), intent.providerDeviceId(),
        result, limitation, intent.policyVersion(), state.appliedPolicyVersion(),
        checkedAt, lastSync, false);
  }

  ItemPage<View> list(String tenant, String actor, int limit, String cursor) {
    var page = store.list(tenant, actor, limit, cursor);
    return new ItemPage<>(page.items().stream().map(ManagedEnrollmentService::view).toList(),
        page.nextCursor());
  }

  private static View view(ManagedEnrollmentStore.Intent intent) {
    return new View(intent.id(), intent.tenantId(), intent.subjectId(), intent.provider(),
        intent.enterpriseId(), intent.providerDeviceId(), intent.providerMode(), intent.state(),
        intent.version(), intent.createdAt(), intent.issuedAt() == 0 ? null : intent.issuedAt(),
        intent.expiresAt(), intent.verifiedAt() == 0 ? null : intent.verifiedAt());
  }

  record View(
      String id, String tenantId, String subjectId, String provider, String enterpriseId,
      String providerDeviceId, String managementMode, String state, long version,
      long createdAt, Long issuedAt, long expiresAt, Long verifiedAt) {}

  /** Never include value or QR in logs, exception messages, or a repeated GET response. */
  record Issued(View intent, String tokenValue, String qrCode) {
    @Override public String toString() { return "ManagedEnrollmentIssued[REDACTED]"; }
  }

  /** providerBaselineApplied never means the Flutter child app is bound or enforcing rules. */
  record ProviderStatus(String intentId, String tenantId, String providerDeviceId,
      String state, String limitationCode, long expectedPolicyVersion,
      Long appliedPolicyVersion, long checkedAt, Long lastPolicySyncAt,
      boolean localAgentBound) {}
}
