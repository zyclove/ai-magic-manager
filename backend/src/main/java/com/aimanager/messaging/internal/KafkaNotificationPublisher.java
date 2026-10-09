package com.aimanager.messaging.internal;

import com.aimanager.delivery.ConfigurationChangedNotice;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.MeterRegistry;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Async;
import org.springframework.transaction.event.TransactionalEventListener;
import org.springframework.stereotype.Component;

/** Spring Modulith owns transactional publication/retry; Spring Kafka owns broker protocol and acknowledgements. */
@Component
@ConditionalOnProperty(prefix = "manager.messaging.kafka", name = "enabled", havingValue = "true")
class KafkaNotificationPublisher {
    private static final Logger LOG = LoggerFactory.getLogger(KafkaNotificationPublisher.class);
    private final KafkaTemplate<String, String> kafka;
    private final ObjectMapper mapper;
    private final MeterRegistry metrics;
    private final String topic;
    KafkaNotificationPublisher(KafkaTemplate<String, String> kafka, ObjectMapper mapper, MeterRegistry metrics,
                               @Value("${manager.messaging.kafka.topic:manager.configuration-changes.v1}") String topic) {
        if (!topic.matches("[a-zA-Z0-9._-]{1,249}") || topic.equals(".") || topic.equals("..")) throw new IllegalArgumentException("Invalid notification topic");
        this.kafka = kafka; this.mapper = mapper; this.metrics = metrics; this.topic = topic;
    }
    // No enclosing JDBC transaction during network I/O; Modulith persists and completes this listener's publication.
    @Async("applicationTaskExecutor")
    @TransactionalEventListener
    public void on(ConfigurationChangedNotice notice) {
        try {
            kafka.send(topic, notice.tenantId() + ":" + notice.registrationId(), mapper.writeValueAsString(notice)).get(5, TimeUnit.SECONDS);
            metrics.counter("manager.notification.published", "channel", "kafka").increment();
        } catch (Exception failure) {
            if (failure instanceof InterruptedException) Thread.currentThread().interrupt();
            metrics.counter("manager.notification.failures", "channel", "kafka").increment();
            LOG.warn("notification not acknowledged channel=kafka eventId={} correlationId={}", notice.eventId(), notice.correlationId());
            // SDK causes can contain connection/credential configuration; no unsafe cause attached.
            throw new IllegalStateException("Kafka notification not acknowledged");
        }
    }
}
