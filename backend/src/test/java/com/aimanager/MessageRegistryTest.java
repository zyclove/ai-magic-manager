package com.aimanager;

import com.aimanager.delivery.ConfigurationChangedNotice;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Duration;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.modulith.events.IncompleteEventPublications;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual Modulith/JDBC transaction and retry registry; the external Kafka transport is a test double. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:messages;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true",
    "manager.messaging.kafka.enabled=true", "manager.messaging.retry-seconds=3600"
})
class MessageRegistryTest {
    @Autowired ApplicationEventPublisher publisher;
    @Autowired PlatformTransactionManager transactions;
    @Autowired JdbcTemplate jdbc;
    @Autowired ObjectMapper mapper;
    @Autowired IncompleteEventPublications incomplete;
    @MockitoBean JwtDecoder decoder;
    @MockitoBean KafkaTemplate<String, String> kafka;
    private ConfigurationChangedNotice notice() {
        return new ConfigurationChangedNotice(UUID.randomUUID().toString(), UUID.randomUUID().toString(), UUID.randomUUID().toString(),
            UUID.randomUUID().toString(), UUID.randomUUID().toString(), 1, Instant.now().toEpochMilli(), UUID.randomUUID().toString());
    }
    private int outstanding(String id) {
        return jdbc.queryForObject("SELECT COUNT(*) FROM event_publication WHERE serialized_event LIKE ?", Integer.class, "%" + id + "%");
    }
    @Test void failedTransportStaysDurableAndExplicitRetryCompletesIt() throws Exception {
        var notice = notice();
        when(kafka.send(anyString(), anyString(), anyString())).thenReturn(CompletableFuture.failedFuture(new IllegalStateException("injected failure")));
        new TransactionTemplate(transactions).executeWithoutResult(status -> publisher.publishEvent(notice));
        await().atMost(Duration.ofSeconds(3)).untilAsserted(() -> verify(kafka, atLeastOnce()).send(anyString(), anyString(), anyString()));
        assertThat(outstanding(notice.eventId())).isEqualTo(1);
        when(kafka.send(anyString(), anyString(), anyString())).thenReturn(CompletableFuture.completedFuture(null));
        incomplete.resubmitIncompletePublications(p -> p.getEvent() instanceof ConfigurationChangedNotice n && n.eventId().equals(notice.eventId()));
        await().atMost(Duration.ofSeconds(3)).untilAsserted(() -> assertThat(outstanding(notice.eventId())).isZero());
        var payload = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(kafka, atLeast(2)).send(eq("manager.configuration-changes.v1"), eq(notice.tenantId() + ":" + notice.registrationId()), payload.capture());
        assertThat(mapper.readTree(payload.getValue()).get("eventId").asText()).isEqualTo(notice.eventId());
        assertThat(mapper.readTree(payload.getValue()).has("document")).isFalse();
    }
    @Test void rollbackNeverPublishesOrLeavesAnEventPublication() {
        var notice = notice();
        new TransactionTemplate(transactions).executeWithoutResult(status -> { publisher.publishEvent(notice); status.setRollbackOnly(); });
        assertThat(outstanding(notice.eventId())).isZero();
        verify(kafka, never()).send(anyString(), anyString(), anyString());
    }
}
