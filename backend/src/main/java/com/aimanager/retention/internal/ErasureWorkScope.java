package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
class ErasureWorkScope {
  private final ErasureLedger ledger;
  private final boolean enabled;
  private final String worker = UUID.randomUUID().toString();
  private final ThreadLocal<Active> current = new ThreadLocal<>();

  private static final class Active {
    final ErasureLedger.WorkPermit permit;
    int references;
    boolean completionUncertain;

    Active(ErasureLedger.WorkPermit permit) {
      this.permit = permit;
    }
  }

  ErasureWorkScope(
      ErasureLedger ledger,
      @Value("${manager.erasure-recovery.required:${ERASURE_RECOVERY_REQUIRED:false}}")
          boolean required,
      @Value("${manager.erasure-ledger.url:${ERASURE_LEDGER_URL:}}") String url) {
    this.ledger = ledger;
    this.enabled = required || !url.isBlank();
  }

  ErasureLedger.WorkPermit enter() {
    if (!enabled) return () -> {};
    var active = current.get();
    if (active == null) {
      active = new Active(ledger.beginWork(worker));
      current.set(active);
    }
    active.references++;
    var held = active;
    var owner = Thread.currentThread();
    return new ErasureLedger.WorkPermit() {
      private boolean closed;

      @Override
      public void close() {
        if (Thread.currentThread() != owner)
          throw new IllegalStateException("Work scope must exit on its owning thread");
        if (closed) return;
        closed = true;
        if (--held.references == 0) {
          current.remove();
          if (!held.completionUncertain) held.permit.close();
        }
      }
    };
  }

  void completionUncertain() {
    var active = current.get();
    if (active != null) active.completionUncertain = true;
  }

  ErasureLedger.WorkState state() {
    return enabled ? ledger.workState() : ErasureLedger.WorkState.READY;
  }
}
