package com.aimanager.observation;

/** 同步事务事件；各领域自行清理其载荷，不跨领域直接操作业务表。 */
public record ObservationAuthorizationChanged(String tenantId, String deviceId, String registrationId,
                                             boolean inventoryEnabled, boolean usageEnabled) {}
