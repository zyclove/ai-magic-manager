package com.aimanager.approval.internal;

import com.aimanager.approval.ApprovalMaintenance;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Spring scheduler + row locks across replicas; one bounded batch per tick, no custom timer framework. */
@Component
@ConditionalOnProperty(name = "manager.approval.expiry-job.enabled", havingValue = "true", matchIfMissing = true)
class ApprovalExpiryJob {
    private final ApprovalMaintenance maintenance;
    private final int batch;
    ApprovalExpiryJob(ApprovalMaintenance maintenance, @Value("${manager.approval.expiry-job.batch-size:100}") int batch,
                      @Value("${manager.approval.expiry-job.interval-seconds:30}") long interval) {
        if (batch < 1 || batch > 1000 || interval < 5 || interval > 3600) throw new IllegalArgumentException("Invalid approval expiry job configuration");
        this.maintenance = maintenance; this.batch = batch;
    }
    @Scheduled(fixedDelayString = "${manager.approval.expiry-job.interval-seconds:30}", timeUnit = java.util.concurrent.TimeUnit.SECONDS)
    public void tick() { maintenance.expireDue(batch); }
}
