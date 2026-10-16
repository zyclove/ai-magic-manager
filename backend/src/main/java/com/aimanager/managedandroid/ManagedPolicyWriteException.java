package com.aimanager.managedandroid;

/**
 * Sanitized transport outcome. It never embeds provider resources, bodies, credentials or causes.
 */
public final class ManagedPolicyWriteException extends IllegalStateException {
  public enum Outcome {
    NOT_DISPATCHED,
    OUTCOME_UNKNOWN
  }

  private final Outcome outcome;

  public ManagedPolicyWriteException(Outcome outcome) {
    super(
        java.util.Objects.requireNonNull(outcome) == Outcome.NOT_DISPATCHED
            ? "Managed complete policy write was not dispatched"
            : "Managed complete policy write outcome is unknown; reconcile before any write");
    this.outcome = outcome;
  }

  public Outcome outcome() {
    return outcome;
  }
}
