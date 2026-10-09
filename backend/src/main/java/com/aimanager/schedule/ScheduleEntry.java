package com.aimanager.schedule;

/** Definitions are immutable; create a new ID to change a referenced plan. */
public record ScheduleEntry(String id, String name, ScheduleDefinition definition) {}
