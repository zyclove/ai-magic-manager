package com.aimanager.lifecycle.internal;

import com.aimanager.lifecycle.CleanupMaintenance;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Multi-replica-safe row transitions in bounded batches through the standard Spring scheduler. */
@Component
@ConditionalOnProperty(name = "manager.lifecycle.expiry-job.enabled", havingValue = "true", matchIfMissing = true)
class CleanupExpiryJob {
    private final CleanupMaintenance maintenance;
    private final int batch;
    CleanupExpiryJob(CleanupMaintenance maintenance, @Value("${manager.lifecycle.expiry-job.batch-size:100}") int batch,
        @Value("${manager.lifecycle.expiry-job.interval-seconds:30}") long interval) {
        if (batch < 1 || batch > 1000 || interval < 5 || interval > 3600) throw new IllegalArgumentException("Invalid cleanup expiry job configuration");
        this.maintenance = maintenance; this.batch = batch;
    }
    @Scheduled(fixedDelayString = "${manager.lifecycle.expiry-job.interval-seconds:30}", timeUnit = java.util.concurrent.TimeUnit.SECONDS)
    public void tick() { maintenance.expireDue(batch); }
}
