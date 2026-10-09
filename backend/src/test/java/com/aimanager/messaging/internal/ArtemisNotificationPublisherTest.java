package com.aimanager.messaging.internal;

import com.aimanager.delivery.ConfigurationChangedNotice;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import jakarta.jms.*;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual Spring JmsTemplate conversion/routing/QoS with a JMS test double, not an Artemis or MQTT integration test. */
class ArtemisNotificationPublisherTest {
    @Test void persistentBoundedTextNoticeUsesOneRegistrationTopic() throws Exception {
        var factory = mock(ConnectionFactory.class); var connection = mock(Connection.class); var session = mock(Session.class);
        var topic = mock(Topic.class); var producer = mock(MessageProducer.class); var message = mock(TextMessage.class);
        when(factory.createConnection()).thenReturn(connection); when(connection.createSession(anyBoolean(), anyInt())).thenReturn(session);
        when(session.createTopic(anyString())).thenReturn(topic); when(session.createProducer(any(Destination.class))).thenReturn(producer);
        when(session.createTextMessage(anyString())).thenReturn(message);
        var metrics = new SimpleMeterRegistry();
        var notice = new ConfigurationChangedNotice(UUID.randomUUID().toString(), UUID.randomUUID().toString(), UUID.randomUUID().toString(),
            UUID.randomUUID().toString(), UUID.randomUUID().toString(), 1, 1, UUID.randomUUID().toString());
        new ArtemisNotificationPublisher(factory, new ObjectMapper(), metrics).on(notice);
        verify(session).createTopic("manager/tenants/" + notice.tenantId() + "/registrations/" + notice.registrationId() + "/configuration");
        verify(producer).send(message, DeliveryMode.PERSISTENT, Message.DEFAULT_PRIORITY, 60000L);
        var encoded = org.mockito.ArgumentCaptor.forClass(String.class); verify(session).createTextMessage(encoded.capture());
        assertThat(new ObjectMapper().readTree(encoded.getValue()).has("document")).isFalse();
        assertThat(metrics.counter("manager.notification.published", "channel", "artemis").count()).isEqualTo(1);
    }
    @Test void unsafeSdkCauseIsNotAttachedToTheListenerFailure() throws Exception {
        var factory = mock(ConnectionFactory.class); when(factory.createConnection()).thenThrow(new JMSException("injected SDK detail"));
        var notice = new ConfigurationChangedNotice("event", "tenant", "device", "registration", "policy", 1, 1, "request");
        var publisher = new ArtemisNotificationPublisher(factory, new ObjectMapper(), new SimpleMeterRegistry());
        assertThatThrownBy(() -> publisher.on(notice)).isInstanceOf(java.lang.IllegalStateException.class)
            .hasMessage("Artemis notification not acknowledged").hasNoCause();
    }
}
