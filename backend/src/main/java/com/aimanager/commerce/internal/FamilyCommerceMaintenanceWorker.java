package com.aimanager.commerce.internal;

import java.util.concurrent.TimeUnit;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** 未经上线验收默认关闭；重试状态保存在数据库，重启不重置原单。 */
@Component
@ConditionalOnProperty(name="manager.family.commerce.worker.enabled",havingValue="true")
class FamilyCommerceMaintenanceWorker {
  private final FamilyCommerceMaintenance maintenance;
  FamilyCommerceMaintenanceWorker(FamilyCommerceMaintenance maintenance){this.maintenance=maintenance;}
  @Scheduled(fixedDelayString="${manager.family.commerce.worker.interval-seconds:30}",initialDelayString="${manager.family.commerce.worker.interval-seconds:30}",timeUnit=TimeUnit.SECONDS)
  void run(){maintenance.sweep(50);}
}
