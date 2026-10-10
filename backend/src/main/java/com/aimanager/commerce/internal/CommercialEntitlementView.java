package com.aimanager.commerce.internal;

import java.util.List;

/**
 * Commercial rights only; system permissions and device compatibility must be checked separately.
 */
record CommercialEntitlementView(
    String tenantId,
    long version,
    long evaluatedAt,
    int activeSourceCount,
    long baseDeviceCapacity,
    long addOnDeviceCapacity,
    long paidDeviceCapacity,
    List<String> features,
    boolean technicalCapabilityIndependent) {}
