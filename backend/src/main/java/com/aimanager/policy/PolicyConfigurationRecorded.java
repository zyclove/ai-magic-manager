package com.aimanager.policy;

import java.util.List;

/** Trusted in-process event only. Broker messages cannot create or authorize policy state. */
public record PolicyConfigurationRecorded(String tenantId, String publicationId, PolicyVersion version,
                                          List<PolicySnapshot.Target> previousTargets, String correlationId) {}
