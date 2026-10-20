package com.aimanager.managedandroid.internal;

import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.time.Duration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Processes a durable read attempt outside a long transaction. The journal and handoff service own
 * every authorization/state change; an event completing is not evidence of device enforcement.
 */
@Service
class ManagedPreparationWorker {
  private static final Logger LOG = LoggerFactory.getLogger(ManagedPreparationWorker.class);
  private final ManagedPreparationRequestJournal requests;
  private final ManagedPolicyPreparationService preparation;
  private final ManagedPreparationHandoffService handoff;
  private final ManagedProviderCalls calls;
  private final Clock clock;
  private final long commitReserveMillis;

  ManagedPreparationWorker(
      ManagedPreparationRequestJournal requests,
      ManagedPolicyPreparationService preparation,
      ManagedPreparationHandoffService handoff,
      ManagedProviderCalls calls,
      Clock clock,
      @Value("${manager.emm.execution.preparation.commit-reserve-millis:10000}")
          long commitReserveMillis) {
    if (commitReserveMillis < 1 || commitReserveMillis > 10000)
      throw new IllegalArgumentException("Invalid preparation commit time reserve");
    this.requests = requests;
    this.preparation = preparation;
    this.handoff = handoff;
    this.calls = calls;
    this.clock = clock;
    this.commitReserveMillis = commitReserveMillis;
  }

  /**
   * Internal sanitized storage outcome, allowing a scanner to stop instead of hammering storage.
   */
  static final class StorageUnavailable extends RuntimeException {
    StorageUnavailable() {
      super("Preparation storage unavailable");
    }
  }

  void process(String tenant, String request) {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Preparation worker requires separate transactions");
    if (Thread.currentThread().isInterrupted()) return;
    try {
      var claim = requests.claim(tenant, request);
      if (claim == null) return;
      try {
        if (Thread.currentThread().isInterrupted()) return;
        if (!requests.current(claim))
          throw new DomainException(HttpStatus.CONFLICT, "PREPARATION_NOT_CURRENT");
        var context = claim.binding();
        // Do not spend the remaining lease on external reads and leave no commit time.
        long remaining = claim.leaseUntil() - clock.millis() - commitReserveMillis;
        var budget = calls.budget(Duration.ofMillis(remaining));
        var prepared =
            preparation.prepare(
                claim.tenantId(),
                context.actorId(),
                claim.publicationId(),
                context.bindingId(),
                context.bindingVersion(),
                budget);
        if (Thread.currentThread().isInterrupted()) return;
        calls.check(budget);
        handoff.complete(claim, prepared);
      } catch (DataAccessException storageFailure) {
        // Do not immediately issue another database checkpoint against unavailable storage.
        // The durable lease remains recoverable after expiry and the event can be retried.
        throw new StorageUnavailable();
      } catch (RuntimeException failure) {
        if (Thread.currentThread().isInterrupted()) return;
        LOG.warn("Managed preparation attempt failed: type={}", failure.getClass().getSimpleName());
        try {
          // A false outcome means a cancelled/replaced/expired attempt. Never compensate or
          // overwrite the newer request state. Successful retry checkpointing is durable work.
          requests.failed(claim, retryable(failure));
        } catch (DataAccessException storageFailure) {
          throw new StorageUnavailable();
        } catch (RuntimeException checkpointFailure) {
          LOG.warn(
              "Managed preparation checkpoint failed: type={}",
              checkpointFailure.getClass().getSimpleName());
          throw new IllegalStateException("Preparation checkpoint unavailable");
        }
      }
    } catch (DataAccessException storageFailure) {
      throw new StorageUnavailable();
    }
  }

  private static boolean retryable(RuntimeException failure) {
    if (!(failure instanceof DomainException domain)) return true;
    int status = domain.status().value();
    return status == 408 || status == 429 || status >= 500;
  }
}
