package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import org.springframework.stereotype.Service;

/** 提供方读取位于事务外；最终确认必须重新加载当前授权及注册。 */
@Service
class ManagedAgentBindingService {
  private final ManagedAgentBindingStore store;
  private final ManagedAndroidGateway gateway;

  ManagedAgentBindingService(ManagedAgentBindingStore store, ManagedAndroidGateway gateway) {
    this.store = store;
    this.gateway = gateway;
  }

  ManagedAgentBindingStore.View verify(String tenant, String actor, String binding, long version) {
    var request = store.capture(tenant, actor, binding, version);
    var first = gateway.readEnrollmentIdentity(request.enterpriseId(), request.providerDeviceId());
    var evidence =
        gateway.readAgentEvidence(
            request.enterpriseId(), request.providerDeviceId(), request.packageName());
    if (evidence.isEmpty()) return store.get(tenant, actor, binding);
    var last = gateway.readEnrollmentIdentity(request.enterpriseId(), request.providerDeviceId());
    return store.complete(tenant, actor, binding, version, first, last, evidence.get());
  }
}
