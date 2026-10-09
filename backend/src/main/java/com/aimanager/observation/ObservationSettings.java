package com.aimanager.observation;

/** 儿童设备可见的授权事实；不包含管理员账号、授权理由或任何凭据。 */
public record ObservationSettings(String deviceId, String registrationId, long version,
                                  boolean inventoryEnabled, boolean usageEnabled, Long updatedAt) {}
