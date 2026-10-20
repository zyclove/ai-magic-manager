package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedPolicyResourceEvidence;
import com.aimanager.managedandroid.ManagedPolicyResourceEvidence.Target;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.Duration;
import java.util.Objects;
import java.util.Optional;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Joins current task preparation to a qualified provider's read-only resource authority report.
 * Does not reserve resources or dispatch policy writes. Subsequent execution must still commit its
 * final authorization/uncertainty checkpoint and honor the provider's exclusivity mechanism.
 */
@Service
class ManagedExecutionResourceAuthorityService {
  private final ManagedPolicyExecutionJournal journal;
  private final ManagedExecutionPreparationService preparation;
  private final ManagedAndroidGateway gateway;
  private final ObjectMapper mapper;
  private final Clock clock;
  private final ManagedProviderCalls calls;
  private final long maxAgeMillis;
  private final long reuseMillis;
  private final long skewMillis;

  ManagedExecutionResourceAuthorityService(
      ManagedPolicyExecutionJournal journal,
      ManagedExecutionPreparationService preparation,
      ManagedAndroidGateway gateway,
      ObjectMapper mapper,
      Clock clock,
      @Value("${manager.emm.policy-resource-authority.max-report-age-seconds:120}")
          long maxAgeSeconds,
      @Value("${manager.emm.policy-resource-authority.max-reuse-age-seconds:30}") long reuseSeconds,
      @Value("${manager.emm.policy-resource-authority.clock-skew-seconds:5}") long skewSeconds,
      ManagedProviderCalls calls) {
    if (maxAgeSeconds < 1
        || maxAgeSeconds > 600
        || reuseSeconds < 1
        || reuseSeconds > maxAgeSeconds
        || skewSeconds < 0
        || skewSeconds > 30)
      throw new IllegalArgumentException("Invalid resource authority freshness configuration");
    this.journal = journal;
    this.preparation = preparation;
    this.gateway = gateway;
    this.mapper = mapper;
    this.clock = clock;
    this.calls = Objects.requireNonNull(calls);
    this.maxAgeMillis = maxAgeSeconds * 1000;
    this.reuseMillis = reuseSeconds * 1000;
    this.skewMillis = skewSeconds * 1000;
  }

  VerifiedExecution verify(ManagedPolicyExecutionJournal.Claim claim) {
    requireOutsideTransaction();
    Objects.requireNonNull(claim);
    ManagedProviderCalls.Budget budget;
    try {
      budget =
          calls.budget(Duration.ofMillis(Math.subtractExact(claim.leaseUntil(), clock.millis())));
    } catch (RuntimeException unavailable) {
      throw providerUnavailable();
    }
    return verify(claim, budget);
  }

  /** Both complete preparations and the resource read consume the original caller budget. */
  VerifiedExecution verify(
      ManagedPolicyExecutionJournal.Claim claim, ManagedProviderCalls.Budget budget) {
    requireOutsideTransaction();
    checkBudget(budget);
    var connector = connector();
    var before = preparation.prepare(claim, budget);
    checkBudget(budget);
    if (!connector.provider().equals(before.target().binding().provider())) throw unavailable();
    // Initial preparation performs provider I/O too; do not query a connector revoked meanwhile.
    requireCurrent(before.target(), connector, claim);
    var target = target(before.target(), connector);
    Optional<ManagedPolicyResourceEvidence> response;
    try {
      response = calls.call(budget, () -> gateway.readPolicyResourceAuthority(target));
    } catch (RuntimeException failure) {
      throw providerUnavailable();
    }
    long retrievedAt = clock.millis();
    // Reject cancellation, ownership changes and adapter changes before doing more provider I/O.
    requireCurrent(before.target(), connector, claim);
    checkBudget(budget);
    var evidence = response == null ? null : response.orElse(null);
    evidenceDeadline(target, evidence, retrievedAt);

    // Resource lookup can outlive a catalog/qualification change. Reuse the complete existing
    // preparation chain instead of inventing a weaker subset of its authorization checks.
    var after = preparation.prepare(claim, budget);
    checkBudget(budget);
    if (!before.target().equals(after.target())) throw changed();
    requireCurrent(after.target(), connector, claim);
    long deadline =
        Math.min(
            Math.min(before.expiresAt(), after.expiresAt()),
            evidenceDeadline(target, evidence, retrievedAt));
    if (clock.millis() >= deadline) throw invalidEvidence();
    checkBudget(budget);
    return new VerifiedExecution(after, evidence, deadline);
  }

  private static void requireOutsideTransaction() {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Resource authority requires separate short transactions");
  }

  private void checkBudget(ManagedProviderCalls.Budget budget) {
    try {
      calls.check(budget);
    } catch (RuntimeException unavailable) {
      throw providerUnavailable();
    }
  }

  private void requireCurrent(
      ManagedPolicyExecutionJournal.WritePreparationTarget expected,
      Connector connector,
      ManagedPolicyExecutionJournal.Claim claim) {
    if (!expected.equals(journal.writePreparationTarget(claim)) || !connector.equals(connector()))
      throw changed();
  }

  private Connector connector() {
    Connector current;
    boolean available, supported;
    try {
      available = gateway.available();
      supported = gateway.supportsPolicyResourceAuthority();
      current = new Connector(gateway.providerCode(), gateway.policyResourceAuthorityRevision());
    } catch (RuntimeException failure) {
      throw providerUnavailable();
    }
    if (!available
        || !supported
        || current.provider() == null
        || !current.provider().matches("[A-Z][A-Z0-9_]{2,31}")
        || current.revision() == null
        || !current.revision().matches("[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")) throw unavailable();
    return current;
  }

  private Target target(
      ManagedPolicyExecutionJournal.WritePreparationTarget current, Connector connector) {
    var binding = current.binding();
    var claim = current.claim();
    String bindingHash;
    try {
      bindingHash = SecretMaterial.hash(mapper.writeValueAsString(binding));
    } catch (JsonProcessingException failure) {
      throw changed();
    }
    var purpose =
        switch (claim.action()) {
          case WRITE_POLICY -> ManagedPolicyResourceEvidence.Purpose.WRITE_POLICY;
          case ASSIGN_POLICY -> ManagedPolicyResourceEvidence.Purpose.ASSIGN_POLICY;
          default -> throw changed();
        };
    return new Target(
        claim.tenantId(),
        claim.taskId(),
        current.publicationId(),
        current.publication().versionId(),
        binding.deviceId(),
        binding.registrationId(),
        binding.bindingId(),
        binding.bindingVersion(),
        bindingHash,
        connector.provider(),
        connector.revision(),
        claim.enterpriseId(),
        binding.enterpriseBindingVersion(),
        claim.deviceId(),
        claim.policyId(),
        claim.policyVersion(),
        claim.documentSha256(),
        claim.generation(),
        purpose);
  }

  /** Bounds both provider report age and local reuse time, including slow final preparation. */
  private long evidenceDeadline(
      Target target, ManagedPolicyResourceEvidence evidence, long retrievedAt) {
    if (evidence == null
        || !Objects.equals(target, evidence.target())
        || evidence.mechanism()
            != ManagedPolicyResourceEvidence.Mechanism.AUDITED_EXCLUSIVE_NAMESPACE
        || !reference(evidence.evidenceReference())
        || !reference(evidence.namespaceReference())
        || evidence.observedAt() == null
        || evidence.expiresAt() == null) throw invalidEvidence();
    try {
      long observed = evidence.observedAt().toEpochMilli(),
          expires = evidence.expiresAt().toEpochMilli();
      long now = clock.millis();
      if (observed > Math.addExact(retrievedAt, skewMillis)
          || expires <= observed
          || now < Math.subtractExact(retrievedAt, skewMillis)) throw invalidEvidence();
      long deadline =
          Math.min(
              expires,
              Math.min(
                  Math.addExact(observed, maxAgeMillis), Math.addExact(retrievedAt, reuseMillis)));
      if (now >= deadline) throw invalidEvidence();
      return deadline;
    } catch (ArithmeticException invalid) {
      throw invalidEvidence();
    }
  }

  private static boolean reference(String value) {
    return value != null
        && !value.isBlank()
        && value.length() <= 200
        && value.chars().noneMatch(Character::isISOControl);
  }

  private static DomainException unavailable() {
    return new DomainException(
        HttpStatus.SERVICE_UNAVAILABLE, "MANAGED_RESOURCE_CONNECTOR_UNAVAILABLE");
  }

  private static DomainException providerUnavailable() {
    return new DomainException(
        HttpStatus.SERVICE_UNAVAILABLE, "MANAGED_RESOURCE_PROVIDER_UNAVAILABLE");
  }

  private static DomainException changed() {
    return new DomainException(HttpStatus.CONFLICT, "MANAGED_RESOURCE_CONTEXT_CHANGED");
  }

  private static DomainException invalidEvidence() {
    return new DomainException(
        HttpStatus.UNPROCESSABLE_ENTITY, "MANAGED_RESOURCE_EVIDENCE_INVALID");
  }

  private record Connector(String provider, String revision) {
    @Override
    public String toString() {
      return "ResourceAuthorityConnector[REDACTED]";
    }
  }

  /** Short-lived internal observation. Not a reservation or an unconditional write permit. */
  record VerifiedExecution(
      ManagedExecutionPreparationService.PreparedExecution prepared,
      ManagedPolicyResourceEvidence evidence,
      long expiresAt) {
    @Override
    public String toString() {
      return "VerifiedExecutionResourceAuthority[REDACTED]";
    }
  }
}
