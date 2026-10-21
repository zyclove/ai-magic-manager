package com.aimanager.commerce;

import java.util.List;

/** Family commercial admission, independent of device identity and technical capability. */
public interface FamilyDeviceAccess {
  /** Hold before subject, enrollment or device locks; shared with every commercial ledger write. */
  void lockFamily(String tenantId);
  View state(String tenantId);
  void requireEnrollmentSeat(String tenantId, String existingDeviceId);
  void requireManagedChange(String tenantId, List<String> deviceIds, boolean relaxing);
  void requireAdvancedService(String tenantId, List<String> deviceIds);

  record View(String tenantId, long version, String status, int effectiveDeviceLimit, int activeCount,
      Long graceEndsAt, String selectedDeviceId, String selectedRegistrationId, List<DeviceAccess> devices) {}
  record DeviceAccess(String id, String registrationId, String displayName, String subjectId,
      String subjectName, String state, long createdAt, String access, boolean selected, boolean canSelect) {}
}
