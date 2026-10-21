package com.aimanager.commerce;

/** 家庭历史报告的商业准入；调用方仍负责成人或设备身份授权。 */
public interface FamilyHistoryAccess {
  void lock(String tenantId);
  void requireRange(String tenantId,long from);
}
