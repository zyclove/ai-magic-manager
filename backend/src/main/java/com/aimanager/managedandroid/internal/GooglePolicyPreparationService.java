package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedDesiredPolicy;
import com.aimanager.managedandroid.ManagedDeviceExecutionProfile;
import com.aimanager.managedandroid.ManagedDeviceExecutionVerifier;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SafetyCriticalPackages;
import java.time.Clock;
import java.time.Instant;
import java.util.Objects;
import java.util.Set;
import java.util.function.Supplier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Current-context preparation only; no queue admission, assignment or provider write. */
@Service
class GooglePolicyPreparationService {
  private final ManagedAgentBindingStore bindings;
  private final ManagedEnrollmentStore enrollments;
  private final ManagedExecutionPublicationAccess publications;
  private final ManagedAndroidGateway gateway;
  private final ManagedDeviceProfileSettings settings;
  private final Clock clock;
  private final TransactionTemplate tx;
  private final Set<String> protectedPackages;

  GooglePolicyPreparationService(
      ManagedAgentBindingStore bindings,
      ManagedEnrollmentStore enrollments,
      ManagedExecutionPublicationAccess publications,
      ManagedAndroidGateway gateway,
      ManagedDeviceProfileSettings settings,
      Clock clock,
      PlatformTransactionManager transactions,
      @Value("${manager.policies.additional-protected-packages:}")
          String additionalProtectedPackages) {
    this.bindings = bindings;
    this.enrollments = enrollments;
    this.publications = publications;
    this.gateway = gateway;
    this.settings = settings;
    this.clock = clock;
    this.protectedPackages = SafetyCriticalPackages.withAdditional(additionalProtectedPackages);
    tx = new TransactionTemplate(transactions);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    tx.setTimeout(10);
  }

  Prepared prepare(String tenant, String actor, String publication, String binding, long version) {
    // Imperative guard also covers direct callers, where Spring method interception is absent.
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Policy preparation requires separate short transactions");
    var before = tx.execute(status -> capture(tenant, actor, publication, binding, version));
    var target = before.binding();
    var first =
        read(
            () -> gateway.readEnrollmentIdentity(target.enterpriseId(), target.providerDeviceId()));
    ManagedEnrollmentStore.requireProvenance(before.enrollment(), target.providerDeviceId(), first);
    ManagedDeviceExecutionProfile profile =
        read(
            () ->
                gateway
                    .readExecutionProfile(target.enterpriseId(), target.providerDeviceId())
                    .orElse(null));
    Instant retrievedAt = clock.instant();
    var last =
        read(
            () -> gateway.readEnrollmentIdentity(target.enterpriseId(), target.providerDeviceId()));
    ManagedEnrollmentStore.requireProvenance(before.enrollment(), target.providerDeviceId(), last);
    if (!first.equals(last))
      throw new DomainException(HttpStatus.CONFLICT, "EMM_DEVICE_IDENTITY_CHANGED");
    return tx.execute(
        status -> {
          var current = capture(tenant, actor, publication, binding, version);
          if (!before.equals(current)) throw changed();
          Instant notBefore =
              Instant.ofEpochMilli(
                  Math.max(
                      current.enrollment().verifiedAt(),
                      Math.max(target.registeredAt(), target.bindingVerifiedAt())));
          String deviceName =
              "enterprises/" + target.enterpriseId() + "/devices/" + target.providerDeviceId();
          var verified = settings.verifier.verify(deviceName, notBefore, profile, retrievedAt);
          var document =
              new GoogleCompletePolicyCompiler(target.agentPackageName(), protectedPackages)
                  .compileDesired(
                      verified.apiLevel(), verified.managementMode(), current.desired());
          // A slow compilation may consume the remaining evidence lifetime; do not return an
          // expired result.
          verified = settings.verifier.verify(deviceName, notBefore, profile, retrievedAt);
          return new Prepared(
              publication, current.binding(), current.desired(), verified, document);
        });
  }

  private Snapshot capture(
      String tenant, String actor, String publication, String binding, long version) {
    if (!gateway.available()
        || !"GOOGLE_AMAPI".equals(gateway.providerCode())
        || !gateway.supportsExecutionProfiles()
        || !gateway.supportsCompletePolicyDocuments())
      throw new DomainException(
          HttpStatus.SERVICE_UNAVAILABLE, "MANAGED_PREPARATION_CONNECTOR_UNAVAILABLE");
    var current = bindings.requireVerifiedContext(tenant, actor, binding, version);
    var enrollment = enrollments.forProviderStatus(tenant, current.enrollmentId(), actor);
    var desired =
        publications.requireDesiredTarget(
            tenant, actor, publication, current.deviceId(), current.registrationId());
    if (!Objects.equals(tenant, current.tenantId())
        || !Objects.equals(actor, current.actorId())
        || !Objects.equals(binding, current.bindingId())
        || version != current.bindingVersion()
        || !"GOOGLE_AMAPI".equals(current.provider())
        || !Objects.equals(tenant, enrollment.tenantId())
        || !Objects.equals(current.enrollmentId(), enrollment.id())
        || current.enrollmentVersion() != enrollment.version()
        || !Objects.equals(current.subjectId(), enrollment.subjectId())
        || !Objects.equals(current.provider(), enrollment.provider())
        || !Objects.equals(current.enterpriseId(), enrollment.enterpriseId())
        || current.enterpriseBindingVersion() != enrollment.bindingVersion()
        || !Objects.equals(current.providerDeviceId(), enrollment.providerDeviceId())
        || !"VERIFIED".equals(enrollment.state())
        || !"DEVICE_OWNER".equals(enrollment.providerMode())
        || !"DEVICE_OWNER".equals(current.managementMode())
        || !Objects.equals(current.deviceId(), desired.deviceId())
        || !Objects.equals(current.registrationId(), desired.registrationId())) throw changed();
    return new Snapshot(current, enrollment, desired);
  }

  private <T> T read(Supplier<T> operation) {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Provider reads cannot run inside a transaction");
    try {
      return operation.get();
    } catch (RuntimeException failure) {
      // Provider failures may contain secrets. Preserve no message, body or exception cause.
      throw new DomainException(
          HttpStatus.SERVICE_UNAVAILABLE, "MANAGED_PREPARATION_PROVIDER_UNAVAILABLE");
    }
  }

  private static DomainException changed() {
    return new DomainException(HttpStatus.CONFLICT, "MANAGED_PREPARATION_CONTEXT_CHANGED");
  }

  private record Snapshot(
      ManagedAgentBindingStore.VerifiedBindingContext binding,
      ManagedEnrollmentStore.Intent enrollment,
      ManagedDesiredPolicy desired) {
    @Override
    public String toString() {
      return "ManagedPreparationSnapshot[REDACTED]";
    }
  }

  /** Internal observation and compiled bytes. Never an execution permit or client DTO. */
  record Prepared(
      String publicationId,
      ManagedAgentBindingStore.VerifiedBindingContext binding,
      ManagedDesiredPolicy desired,
      ManagedDeviceExecutionVerifier.Verified profile,
      GoogleCompletePolicyCompiler.Compiled document) {
    @Override
    public String toString() {
      return "PreparedManagedPolicy[REDACTED]";
    }
  }
}
