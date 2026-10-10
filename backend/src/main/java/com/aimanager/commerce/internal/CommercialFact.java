package com.aimanager.commerce.internal;

import java.util.Set;

/**
 * A normalized entitlement fact supplied only after an external payment/contract verifier succeeds.
 */
record CommercialFact(
    String tenantId,
    SourceSystem sourceSystem,
    String sourceReference,
    long sourceRevision,
    String productKey,
    CapacityKind capacityKind,
    int deviceCapacity,
    Set<Feature> features,
    long activeFrom,
    long expiresAt,
    State state,
    String evidenceHash,
    String verifiedBy) {
  enum SourceSystem {
    GOOGLE_PLAY,
    APP_STORE,
    CONTRACT,
    PRIVATE_LICENSE
  }

  enum CapacityKind {
    BASE,
    ADD_ON
  }

  enum State {
    ACTIVE,
    REVOKED
  }

  enum Feature {
    ADVANCED_SCHEDULES,
    WEB_FILTERING,
    MANAGED_ANDROID,
    ORG_BULK,
    AI_INSIGHTS
  }
}
