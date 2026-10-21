package com.aimanager.commerce;

/** Actual merged subscription coverage, including verified refunds; never advances a grace window. */
public interface FamilySubscriptionReminders {
  /** Non-locking current read for a notification's final freshness check; cannot grant rights. */
  Window current(String tenantId);
  /** Commercial account first, before any device locks, for reminder projection. */
  Window lockCurrent(String tenantId);
  record Window(Long activePeriodEnd,Long lastPeriodEnd,Long graceEndsAt,boolean selectionPending) {}
}
