package com.aimanager.notification;

/** Bounded retention of the inbox projection; never removes approval or audit history. */
public interface NotificationMaintenance {
  int purgeExpired(int limit);
}
