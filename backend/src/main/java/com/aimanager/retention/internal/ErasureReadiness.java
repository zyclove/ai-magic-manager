package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import org.springframework.boot.actuate.health.*;
import org.springframework.stereotype.Component;

@Component("erasureAdmission")
class ErasureReadiness implements HealthIndicator {
  private final ErasureWorkScope scope;

  ErasureReadiness(ErasureWorkScope scope) {
    this.scope = scope;
  }

  @Override
  public Health health() {
    try {
      return scope.state() == ErasureLedger.WorkState.READY
          ? Health.up().build()
          : Health.down().build();
    } catch (ErasureLedger.Failure unavailable) {
      return Health.down().build();
    }
  }
}
