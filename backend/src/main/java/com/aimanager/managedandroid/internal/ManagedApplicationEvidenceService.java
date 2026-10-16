package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedApplicationReport;
import java.time.Clock;
import java.time.Instant;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Provider calls cannot inherit an outer transaction. A failed read uses the same acceptance CAS.
 */
@Service
class ManagedApplicationEvidenceService {
  private final ManagedApplicationEvidenceStore store;
  private final ManagedAndroidGateway gateway;
  private final Clock clock;

  ManagedApplicationEvidenceService(
      ManagedApplicationEvidenceStore store, ManagedAndroidGateway gateway, Clock clock) {
    this.store = store;
    this.gateway = gateway;
    this.clock = clock;
  }

  @Transactional(propagation = Propagation.NEVER)
  ManagedApplicationEvidenceStore.View refresh(
      String tenant, String actor, String binding, long version, String application) {
    var captured = store.begin(tenant, actor, binding, version, application);
    var current = captured.context().binding();
    ManagedAndroidGateway.ManagedEnrollmentIdentity first = null, last = null;
    ManagedApplicationReport report = null;
    Instant retrievedAt = null;
    boolean failed = false;
    try {
      first = gateway.readEnrollmentIdentity(current.enterpriseId(), current.providerDeviceId());
      report =
          gateway
              .readApplicationReport(
                  current.enterpriseId(),
                  current.providerDeviceId(),
                  captured.context().application().packageName())
              .orElse(null);
      retrievedAt = Instant.ofEpochMilli(clock.millis());
      last = gateway.readEnrollmentIdentity(current.enterpriseId(), current.providerDeviceId());
    } catch (RuntimeException providerFailure) {
      // Provider exceptions may contain HTTP bodies or credentials. Persist only the fixed reason.
      failed = true;
    }
    return store.finish(captured, first, last, report, retrievedAt, failed);
  }
}
