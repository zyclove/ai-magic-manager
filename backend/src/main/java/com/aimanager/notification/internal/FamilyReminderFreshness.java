package com.aimanager.notification.internal;

/** Recovery and subscription renewal suppress an unsent reminder without reviving old consent. */
interface FamilyReminderFreshness {
  boolean allows(String tenantId,String eventId);
}
