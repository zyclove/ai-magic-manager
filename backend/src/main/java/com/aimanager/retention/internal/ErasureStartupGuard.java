package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * Runs before context refresh starts web traffic and scheduled work. Until all erasure handlers and
 * applied checkpoints exist, a nonempty ledger requires recovery and must never be treated as done.
 */
@Component
class ErasureStartupGuard implements SmartInitializingSingleton {
  private final ErasureLedger ledger;
  private final boolean required;

  ErasureStartupGuard(
      ErasureLedger ledger,
      @Value("${manager.erasure-recovery.required:${ERASURE_RECOVERY_REQUIRED:false}}")
          boolean required,
      @Value("${manager.erasure-ledger.url:${ERASURE_LEDGER_URL:}}") String url) {
    this.ledger = ledger;
    this.required = required || !url.isBlank();
  }

  @Override
  public void afterSingletonsInstantiated() {
    if (!required) return;
    if (ledger.head().sequence() != 0)
      throw new ErasureLedger.Failure("ERASURE_LEDGER_RECONCILIATION_REQUIRED");
  }
}
