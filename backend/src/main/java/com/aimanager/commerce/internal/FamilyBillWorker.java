package com.aimanager.commerce.internal;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** 默认关闭；每轮最多补排三天和执行三项，下载凭证及原始账单不进入日志。 */
@Component
@ConditionalOnProperty(prefix = "manager.family.bills.worker", name = "enabled", havingValue = "true")
class FamilyBillWorker {
  private static final Logger LOG = LoggerFactory.getLogger(FamilyBillWorker.class);
  private final FamilyBillReconciliationService bills;
  FamilyBillWorker(FamilyBillReconciliationService bills) { this.bills = bills; }
  @Scheduled(fixedDelayString = "${manager.family.bills.worker.interval-ms:60000}")
  void tick() {
    try {
      for (int count = 0; count < 3 && bills.scheduleOneDay(); count++) { /* 有界补齐停机期间的账单日。 */ }
      for (String id : bills.readyIds(3)) bills.run(id);
    } catch (RuntimeException failure) {
      LOG.warn("Family bill worker interrupted; durable task will be retried");
    }
  }
}
