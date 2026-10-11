package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * Runs before context refresh starts web traffic and scheduled work. Until all erasure handlers and
 * applied checkpoints exist, a nonempty ledger persists one bounded recovery page and then refuses
 * readiness. A persisted read cursor must never be treated as completed erasure.
 */
@Component
class ErasureStartupGuard implements SmartInitializingSingleton {
  private final ErasureRecoveryJobs recovery;
  private final boolean required;

  ErasureStartupGuard(
      ErasureRecoveryJobs recovery,
      @Value("${manager.erasure-recovery.required:${ERASURE_RECOVERY_REQUIRED:false}}")
          boolean required,
      @Value("${manager.erasure-ledger.url:${ERASURE_LEDGER_URL:}}") String url) {
    this.recovery = recovery;
    this.required = required || !url.isBlank();
  }

  @Override
  public void afterSingletonsInstantiated() {
    if (!required) return;
    // Even an empty journal must agree with the business projection: it may be an old snapshot.
    if (recovery.reconcile(100).head().sequence() != 0) {
      throw new ErasureLedger.Failure("ERASURE_LEDGER_RECONCILIATION_REQUIRED");
    }
  }
}
