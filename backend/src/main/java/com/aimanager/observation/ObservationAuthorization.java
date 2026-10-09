package com.aimanager.observation;

import com.aimanager.deviceidentity.DeviceContext;

/** 报告模块在设备及凭据锁之后调用；授权检查与报告写入必须属于同一事务。 */
public interface ObservationAuthorization {
    void requireInventory(DeviceContext identity, long authorizationVersion);
    /** 调用方先完成设备可见范围授权；关闭时不得暴露历史库存载荷。 */
    boolean inventoryEnabled(String tenantId, String deviceId, String registrationId);
}
