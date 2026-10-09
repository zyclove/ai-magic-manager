package com.aimanager.schedule;

public interface ScheduleCatalog {
    ScheduleEntry requireDefinition(String tenantId, String actorId, String scheduleId);
}
