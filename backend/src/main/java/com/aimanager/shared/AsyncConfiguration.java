package com.aimanager.shared;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

/** Bounded workers; durable publications remain retryable if an executor rejects a queued task. */
@Configuration
@EnableAsync
@EnableScheduling
class AsyncConfiguration {
    @Bean(name = "applicationTaskExecutor")
    ThreadPoolTaskExecutor taskExecutor(@Value("${manager.events.core-threads:4}") int core,
                                       @Value("${manager.events.max-threads:8}") int maximum,
                                       @Value("${manager.events.queue-capacity:1000}") int queue) {
        if (core < 1 || core > 64 || maximum < core || maximum > 128 || queue < 1 || queue > 100000)
            throw new IllegalArgumentException("Invalid event worker settings");
        var executor = new ThreadPoolTaskExecutor();
        executor.setThreadNamePrefix("manager-event-"); executor.setCorePoolSize(core); executor.setMaxPoolSize(maximum); executor.setQueueCapacity(queue);
        executor.setWaitForTasksToCompleteOnShutdown(true); executor.setAwaitTerminationSeconds(20);
        return executor;
    }
}
