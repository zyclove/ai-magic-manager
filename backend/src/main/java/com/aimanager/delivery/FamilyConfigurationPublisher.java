package com.aimanager.delivery;
/** Adds explicitly signed family assistance without changing managed ENFORCE semantics. */
public interface FamilyConfigurationPublisher {
  void publish(String tenant,String actor,java.util.List<String> devices,String policy,long version,FamilyAssistanceDocument rules);
  /** Renews each unselected device's existing assistance without copying another device's new rule. */
  default void publishRetainingExisting(String tenant,String actor,java.util.List<String> devices,String policy,long version,
      FamilyAssistanceDocument rules,java.util.List<String> allowedDeviceIds) {
    publishRetainingExisting(tenant,actor,devices,policy,version,rules,allowedDeviceIds,false);
  }
  void publishRetainingExisting(String tenant,String actor,java.util.List<String> devices,String policy,long version,
      FamilyAssistanceDocument rules,java.util.List<String> allowedDeviceIds,boolean allowRelaxation);
}
