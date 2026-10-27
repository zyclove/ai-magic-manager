package com.aimanager.policy.internal;

import static com.aimanager.tenant.TenantAccess.Role.GUARDIAN;
import static com.aimanager.tenant.TenantAccess.Role.ORG_ADMIN;
import static com.aimanager.tenant.TenantAccess.Role.OWNER;

import com.aimanager.idempotency.IdempotencyLookupOutcome;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.policy.PolicyDraft;
import com.aimanager.policy.PolicyRule;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.TenantAccess;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** A journal adapter; all policy compilation, references and writes stay in PolicyService. */
@Service
class PolicyDraftChangeService {
  private static final String JOURNAL_OPERATION = "policy.draft.change";
  private static final long MAX_REVISION = 9007199254740991L;
  private final PolicyService policies;
  private final TenantAccess access;
  private final IdempotencyService journal;

  PolicyDraftChangeService(PolicyService policies, TenantAccess access, IdempotencyService journal) {
    this.policies = policies;
    this.access = access;
    this.journal = journal;
  }

  enum Operation { CREATE, UPDATE }

  // Global Jackson settings reject fractional numbers and scalar coercion for Long revisions.
  record Change(Operation operation, String policyId, Long revision,
      @NotBlank @Size(max = 100) String name, PolicyDraft.Kind kind,
      @NotNull @Size(max = 100) List<@NotNull @Valid PolicyRule> rules) {}

  record Result(Operation operation, PolicyDraft committed, PolicyDraft current) {}

  @Transactional(timeout = 10)
  public PolicyDraft change(String tenant, String actor, Change input, String key) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    requireKey(key);
    var attributes = attributes(input);
    return journal.execute(tenant, actor, JOURNAL_OPERATION, key, attributes,
        PolicyDraft.class, () -> switch (input.operation()) {
          case CREATE -> policies.create(tenant, actor,
              new PolicyController.CreateDraft(input.name(), input.kind(), input.rules()), null);
          case UPDATE -> policies.update(tenant, actor, input.policyId(),
              new PolicyController.EditDraft(input.name(), input.rules()),
              ResourceVersions.tag(input.revision()));
        }, ignored -> ResponseOwnership.nonSubject());
  }

  /** Missing is inconclusive; result expiry leaves the transaction as a typed outcome. */
  @Transactional(timeout = 10)
  public IdempotencyLookupOutcome<Result> query(String tenant, String actor, String key, Change input) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    requireKey(key);
    return journal.findCommitted(tenant, actor, JOURNAL_OPERATION, key, attributes(input),
            PolicyDraft.class)
        .requirePresent(() -> new DomainException(HttpStatus.NOT_FOUND, "POLICY_DRAFT_RESULT_UNAVAILABLE"))
        .map(committed -> new Result(input.operation(), committed,
            policies.get(tenant, actor, committed.id())));
  }

  private Map<String, Object> attributes(Change input) {
    if (input == null || input.operation() == null || input.name() == null
        || input.name().isBlank() || input.name().length() > 100 || input.rules() == null
        || input.rules().size() > 100 || input.rules().stream().anyMatch(rule -> rule == null)) {
      throw invalid();
    }
    var attributes = new LinkedHashMap<String, Object>();
    attributes.put("operation", input.operation());
    attributes.put("name", input.name());
    attributes.put("rules", List.copyOf(input.rules()));
    switch (input.operation()) {
      case CREATE -> {
        if (input.policyId() != null || input.revision() != null || input.kind() == null) throw invalid();
        attributes.put("kind", input.kind());
      }
      case UPDATE -> {
        if (input.policyId() == null || input.policyId().isBlank() || input.policyId().length() > 100
            || input.revision() == null || input.revision() < 0 || input.revision() >= MAX_REVISION
            || input.kind() != null) throw invalid();
        attributes.put("policyId", input.policyId());
        attributes.put("revision", input.revision());
      }
    }
    return Map.copyOf(attributes);
  }

  private void requireKey(String key) {
    try {
      if (key != null && UUID.fromString(key).toString().equals(key)) return;
    } catch (IllegalArgumentException ignored) {
      // Invalid references do not disclose another actor's result or enter the journal.
    }
    throw invalid();
  }

  private DomainException invalid() {
    return DomainException.invalid("INVALID_POLICY_DRAFT_CHANGE");
  }
}
