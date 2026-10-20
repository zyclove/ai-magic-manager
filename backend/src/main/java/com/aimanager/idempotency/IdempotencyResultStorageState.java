package com.aimanager.idempotency;

/** 完整响应的物理存储状态；不替代主体归属、逻辑过期或 ERASED 拒绝标记。 */
public enum IdempotencyResultStorageState {
  /** 响应仍在存储中；是否允许读取还必须检查固定恢复期限。 */
  RETAINED,
  /** 完整响应已清理，必要防重占位继续保留。 */
  REDACTED
}
