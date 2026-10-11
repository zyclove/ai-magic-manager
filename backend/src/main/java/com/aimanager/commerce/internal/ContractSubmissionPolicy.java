package com.aimanager.commerce.internal;

import com.aimanager.commerce.internal.CommercialFact.State;
import com.aimanager.shared.DomainException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/**
 * Separates the trusted issuer connection from the ability to activate new contract business.
 * Pausing active contracts does not prevent an already trusted issuer from sending revocations.
 */
@Component
final class ContractSubmissionPolicy {
  private final boolean evidenceEnabled;
  private final boolean activeSubmissionsEnabled;

  ContractSubmissionPolicy(
      @Value("${manager.contract.evidence-enabled:false}") boolean evidenceEnabled,
      @Value("${manager.contract.active-submissions-enabled:false}")
          boolean activeSubmissionsEnabled) {
    this.evidenceEnabled = evidenceEnabled;
    this.activeSubmissionsEnabled = activeSubmissionsEnabled;
  }

  boolean activeAvailable() {
    return evidenceEnabled && activeSubmissionsEnabled;
  }

  boolean revocationAvailable() {
    return evidenceEnabled;
  }

  void requireAllowed(ContractEvidence evidence) {
    requireIssuer();
    if (evidence.state() == State.ACTIVE) requireActive();
  }

  void requireActive() {
    requireIssuer();
    if (!activeSubmissionsEnabled) {
      throw new DomainException(HttpStatus.CONFLICT, "CONTRACT_ACTIVE_SUBMISSIONS_PAUSED");
    }
  }

  private void requireIssuer() {
    if (!evidenceEnabled) {
      throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "CONTRACT_PROVIDER_UNAVAILABLE");
    }
  }
}
