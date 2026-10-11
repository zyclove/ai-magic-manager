package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.SecretMaterial;
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
  private final String bootstrapPolicyId;

  ManagedEnrollmentService(
      ManagedEnrollmentStore store,
      ManagedAndroidGateway gateway,
      @Value("${manager.emm.google.bootstrap-policy-id:}") String bootstrapPolicyId) {
    this.store = store;
    this.gateway = gateway;
    this.bootstrapPolicyId = bootstrapPolicyId;
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
      if (material != null && material.tokenName() != null) {
        try {
          gateway.deleteEnrollmentToken(prepared.enterpriseId(), material.tokenName());
        } catch (RuntimeException cleanupFailure) {
          LOG.error("Managed enrollment token cleanup failed: intent={}, type={}",
              prepared.id(), cleanupFailure.getClass().getSimpleName());
        }
      }
      try {
        store.failed(tenant, prepared.id(), actor);
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
}
