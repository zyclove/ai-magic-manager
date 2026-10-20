package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SafetyCriticalPackages;
import com.aimanager.shared.SecretMaterial;
import java.time.Clock;
import java.util.Objects;
import java.util.Set;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Transfers a current, fully prepared result to the durable execution journal in one short
 * transaction. All provider reads already happened in the preparer; no provider I/O occurs here.
 * Task creation is not proof that a policy has been written, assigned or applied.
 */
@Service
class ManagedPreparationHandoffService {
  private final ManagedPreparationRequestJournal requests;
  private final ManagedPolicyExecutionJournal executions;
  private final ManagedExecutionPublicationAccess publications;
  private final ManagedPolicyControlAdmission controls;
  private final ManagedPolicyDocumentCompilers compilers;
  private final ManagedAndroidGateway gateway;
  private final Clock clock;
  private final TransactionTemplate tx;
  private final Set<String> protectedPackages;

  ManagedPreparationHandoffService(
      ManagedPreparationRequestJournal requests,
      ManagedPolicyExecutionJournal executions,
      ManagedExecutionPublicationAccess publications,
      ManagedPolicyControlAdmission controls,
      ManagedPolicyDocumentCompilers compilers,
      ManagedAndroidGateway gateway,
      Clock clock,
      PlatformTransactionManager transactions,
      @Value("${manager.policies.additional-protected-packages:}")
          String additionalProtectedPackages) {
    this.requests = requests;
    this.executions = executions;
    this.publications = publications;
    this.controls = controls;
    this.compilers = compilers;
    this.gateway = gateway;
    this.clock = clock;
    protectedPackages = SafetyCriticalPackages.withAdditional(additionalProtectedPackages);
    tx = new TransactionTemplate(transactions);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    tx.setTimeout(10);
  }

  ManagedPolicyExecutionJournal.View complete(
      ManagedPreparationRequestJournal.Claim claim,
      ManagedPolicyPreparationService.Prepared prepared) {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Preparation handoff requires a separate transaction");
    return tx.execute(
        status -> {
          var target = requests.handoffTarget(claim);
          var binding = target.binding();
          requireAvailable(binding.provider());
          if (prepared == null
              || !Objects.equals(claim.publicationId(), prepared.publicationId())
              || !binding.equals(prepared.binding())
              || prepared.desired() == null
              || prepared.profile() == null
              || prepared.document() == null
              || prepared.controls() == null) throw changed();
          var desired =
              publications.requireDesiredTarget(
                  binding.tenantId(),
                  binding.actorId(),
                  claim.publicationId(),
                  binding.deviceId(),
                  binding.registrationId());
          if (desired == null
              || desired.publication() == null
              || !target.versionId().equals(desired.publication().versionId())
              || !binding.deviceId().equals(desired.deviceId())
              || !binding.registrationId().equals(desired.registrationId())
              || !desired.equals(prepared.desired())) throw changed();
          var currentControls = controls.check(binding, desired);
          if (currentControls == null || !currentControls.equals(prepared.controls()))
            throw changed();
          var profile = prepared.profile();
          var document = prepared.document();
          String expectedDevice =
              "enterprises/" + binding.enterpriseId() + "/devices/" + binding.providerDeviceId();
          if (!expectedDevice.equals(profile.deviceName())
              || !"DEVICE_OWNER".equals(profile.managementMode())
              || profile.apiLevel() < 30
              || profile.reportedAt() == null
              || profile.retrievedAt() == null
              || profile.expiresAt() == null
              || !profile.expiresAt().isAfter(profile.retrievedAt())
              || !binding.agentPackageName().equals(document.agentPackage())
              || profile.apiLevel() != document.apiLevel()
              || !profile.managementMode().equals(document.managementMode())
              || document.documentJson() == null
              || document.sha256() == null
              || !SecretMaterial.hash(document.documentJson()).equals(document.sha256()))
            throw changed();
          long evidenceDeadline;
          try {
            if (profile.retrievedAt().toEpochMilli() > clock.millis()) throw changed();
            evidenceDeadline =
                Math.min(
                    target.expiresAt(),
                    Math.min(profile.expiresAt().toEpochMilli(), currentControls.expiresAt()));
          } catch (ArithmeticException invalid) {
            throw changed();
          }
          requireFresh(claim, currentControls, evidenceDeadline);
          // Recompile through the existing adapter registry; never accept arbitrary
          // complete-looking
          // JSON or a digest alone as proof that the current desired policy produced this document.
          var currentDocument =
              compilers.compile(
                  binding.provider(),
                  binding.agentPackageName(),
                  profile,
                  desired,
                  protectedPackages);
          if (!document.equals(currentDocument)) throw changed();
          requireAvailable(binding.provider());
          if (!target.equals(requests.handoffTarget(claim))) throw changed();
          requireFresh(claim, currentControls, evidenceDeadline);
          // Preserve the original absolute authorization deadline. Admission evidence must be
          // fresh now; each later write/assignment re-prepares and checks its own current evidence
          // and lease. Evidence reuse expiry is not the lifetime of the durable request.
          var task = executions.enqueuePrepared(claim, document, target.expiresAt());
          // An unusually slow database/audit callback must not commit already-expired evidence.
          requireFresh(claim, currentControls, evidenceDeadline);
          return task;
        });
  }

  private void requireAvailable(String provider) {
    if (!gateway.available()
        || !Objects.equals(provider, gateway.providerCode())
        || !gateway.supportsExecutionProfiles()
        || !gateway.supportsCompletePolicyDocuments()
        || !gateway.supportsPolicyResourceAuthority()
        || gateway.policyResourceAuthorityRevision() == null
        || gateway.policyResourceAuthorityRevision().isBlank()
        || !compilers.supports(provider))
      throw new DomainException(
          HttpStatus.SERVICE_UNAVAILABLE, "MANAGED_PREPARATION_CONNECTOR_UNAVAILABLE");
  }

  private void requireFresh(
      ManagedPreparationRequestJournal.Claim claim,
      ManagedPolicyControlAdmission.Checked checked,
      long deadline) {
    if (clock.millis() >= Math.min(deadline, claim.leaseUntil()))
      throw new DomainException(HttpStatus.CONFLICT, "PREPARATION_HANDOFF_EXPIRED");
    controls.requireFresh(checked);
  }

  private static DomainException changed() {
    return new DomainException(HttpStatus.CONFLICT, "PREPARATION_RESULT_CHANGED");
  }
}
