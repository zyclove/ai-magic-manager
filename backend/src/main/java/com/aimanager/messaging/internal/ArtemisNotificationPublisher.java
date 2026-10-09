package com.aimanager.messaging.internal;

import com.aimanager.delivery.ConfigurationChangedNotice;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.jms.ConnectionFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.jms.core.JmsTemplate;
import org.springframework.scheduling.annotation.Async;
import org.springframework.transaction.event.TransactionalEventListener;
import org.springframework.stereotype.Component;

/** Persistent text notifications. Broker MQTT mapping, ACL, TLS and device credentials require separate qualification. */
@Component
@ConditionalOnProperty(prefix = "manager.messaging.artemis", name = "enabled", havingValue = "true")
class ArtemisNotificationPublisher {
    private static final Logger LOG = LoggerFactory.getLogger(ArtemisNotificationPublisher.class);
    private final JmsTemplate jms;
    private final ObjectMapper mapper;
    private final MeterRegistry metrics;
    ArtemisNotificationPublisher(ConnectionFactory connections, ObjectMapper mapper, MeterRegistry metrics) {
        this.jms = new JmsTemplate(connections); this.jms.setPubSubDomain(true);
        this.jms.setExplicitQosEnabled(true); this.jms.setDeliveryPersistent(true); this.jms.setTimeToLive(60000);
        this.mapper = mapper; this.metrics = metrics;
    }
    @Async("applicationTaskExecutor")
    @TransactionalEventListener
    public void on(ConfigurationChangedNotice notice) {
        try {
            String topic = "manager/tenants/" + notice.tenantId() + "/registrations/" + notice.registrationId() + "/configuration";
            jms.convertAndSend(topic, mapper.writeValueAsString(notice));
            metrics.counter("manager.notification.published", "channel", "artemis").increment();
        } catch (Exception failure) {
            metrics.counter("manager.notification.failures", "channel", "artemis").increment();
            LOG.warn("notification not acknowledged channel=artemis eventId={} correlationId={}", notice.eventId(), notice.correlationId());
            throw new IllegalStateException("Artemis notification not acknowledged");
        }
    }
}
