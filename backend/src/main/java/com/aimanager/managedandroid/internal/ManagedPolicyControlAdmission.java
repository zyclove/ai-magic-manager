package com.aimanager.managedandroid.internal;

import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.catalog.ApplicationIdentity;
import com.aimanager.managedandroid.ManagedControlOperation;
import com.aimanager.managedandroid.ManagedDesiredPolicy;
import com.aimanager.managedandroid.ManagedPolicyEvidenceAccess.ApplicationEvidence;
import com.aimanager.shared.AndroidRuntimePermissions;
import com.aimanager.shared.DomainException;
import java.sql.Connection;
import java.time.Clock;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Current local application qualifications only. Never grants resource ownership or dispatches I/O.
 */
@Component
class ManagedPolicyControlAdmission {
  private final ApplicationCatalog catalog;
  private final ManagedApplicationEvidenceStore evidence;
  private final Clock clock;

  ManagedPolicyControlAdmission(
      ApplicationCatalog catalog, ManagedApplicationEvidenceStore evidence, Clock clock) {
    this.catalog = catalog;
    this.evidence = evidence;
    this.clock = clock;
  }

  /** Called after the binding authority locks, in the same short READ_COMMITTED transaction. */
  Checked check(
      ManagedAgentBindingStore.VerifiedBindingContext binding, ManagedDesiredPolicy desired) {
    if (!TransactionSynchronizationManager.isActualTransactionActive()
        || !Objects.equals(
            TransactionSynchronizationManager.getCurrentTransactionIsolationLevel(),
            Connection.TRANSACTION_READ_COMMITTED))
      throw new IllegalStateException(
          "Application admission requires a READ_COMMITTED transaction");
    if (binding == null
        || desired == null
        || desired.applications().size() > 100
        || !Objects.equals(binding.deviceId(), desired.deviceId())
        || !Objects.equals(binding.registrationId(), desired.registrationId())) throw rejected();
    var identities = new TreeMap<String, ApplicationIdentity>();
    var requested = new TreeMap<String, ManagedDesiredPolicy.ApplicationIntent>();
    for (var application : desired.applications()) {
      if (application == null
          || application.applicationId() == null
          || requested.putIfAbsent(application.applicationId(), application) != null
          || application.requiredOperations().isEmpty()
          || application.requiredOperations().size() > 100
          || new HashSet<>(application.requiredOperations()).size()
              != application.requiredOperations().size()
          || application.requiredOperations().stream()
              .anyMatch(operation -> !validOperation(operation))) throw rejected();
      var identity =
          catalog.requireEvidenceIdentity(
              binding.tenantId(), binding.actorId(), application.applicationId());
      if (identity == null
          || !application.applicationId().equals(identity.applicationId())
          || identity.platform() != binding.platform()
          || identity.profile() != ApplicationDefinition.Profile.PRIMARY
          || !"PRIMARY".equals(application.profile())
          || !Objects.equals(identity.packageName(), application.packageName())
          || application.signingDigests().isEmpty()
          || application.signingDigests().size() != identity.signingDigests().size()
          || !new HashSet<>(application.signingDigests())
              .equals(new HashSet<>(identity.signingDigests()))
          || identity.revision() == null
          || !identity.revision().matches("[0-9a-f]{64}")) throw rejected();
      identities.put(identity.applicationId(), identity);
    }
    // A deliberately empty published baseline has no application operations to qualify.
    if (identities.isEmpty()) return new Checked(List.of(), List.of(), Long.MAX_VALUE);
    var facts = evidence.forPolicy(binding, identities);
    if (facts == null || facts.size() != identities.size()) throw rejected();
    var ordered = new TreeMap<String, ApplicationEvidence>();
    long now = clock.millis(), expiresAt = Long.MAX_VALUE;
    for (var fact : facts) {
      if (fact == null
          || fact.applicationId() == null
          || ordered.putIfAbsent(fact.applicationId(), fact) != null) throw rejected();
      var identity = identities.get(fact.applicationId());
      if (identity == null
          || !Objects.equals(fact.deviceId(), binding.deviceId())
          || !Objects.equals(fact.registrationId(), binding.registrationId())
          || !Objects.equals(fact.bindingId(), binding.bindingId())
          || fact.bindingVersion() != binding.bindingVersion()
          || !identity.revision().equals(fact.definitionRevision())
          || !"VERIFIED_IDENTITY".equals(fact.state())
          || !"PRIMARY".equals(fact.profileScope())
          || !fact.systemControlAvailable()
          || fact.evidenceVersion() < 1
          || fact.reportedAt() == null
          || fact.reportedAt() < 0
          || fact.retrievedAt() == null
          || fact.retrievedAt() < 0
          || fact.retrievedAt() > now
          || fact.expiresAt() == null
          || fact.expiresAt() <= now
          || fact.expiresAt() <= fact.retrievedAt()
          || !fact.controlOperations()
              .containsAll(requested.get(fact.applicationId()).requiredOperations()))
        throw rejected();
      expiresAt = Math.min(expiresAt, fact.expiresAt());
    }
    return new Checked(List.copyOf(identities.values()), List.copyOf(ordered.values()), expiresAt);
  }

  /** Compilation may consume the remaining evidence lifetime; do not return an expired result. */
  void requireFresh(Checked checked) {
    if (checked == null || clock.millis() >= checked.expiresAt()) throw rejected();
  }

  private boolean validOperation(ManagedControlOperation operation) {
    if (operation == null || operation.kind() == null || operation.effect() == null) return false;
    return switch (operation.kind()) {
      case APP_LAUNCH, APP_INSTALL ->
          operation.permission() == null
              && (operation.effect() == ManagedControlOperation.Effect.ALLOW
                  || operation.effect() == ManagedControlOperation.Effect.DENY);
      case RUNTIME_PERMISSION ->
          AndroidRuntimePermissions.contains(operation.permission())
              && (operation.effect() == ManagedControlOperation.Effect.DENY
                  || operation.effect() == ManagedControlOperation.Effect.DEFAULT);
    };
  }

  private static DomainException rejected() {
    return new DomainException(
        HttpStatus.UNPROCESSABLE_ENTITY, "MANAGED_PREPARATION_APPLICATION_UNVERIFIED");
  }

  record Checked(
      List<ApplicationIdentity> identities, List<ApplicationEvidence> facts, long expiresAt) {
    Checked {
      identities = List.copyOf(identities);
      facts = List.copyOf(facts);
    }

    @Override
    public String toString() {
      return "ManagedApplicationAdmission[REDACTED]";
    }
  }
}
