package com.aimanager.commerce;

/** 服务端收费验收边界。配置开关、客户端声明和清单登记均不能替代真实验收。 */
public interface FamilySalesGate {
  boolean allowed();
}
