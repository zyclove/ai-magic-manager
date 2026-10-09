package com.aimanager.messaging.internal;

import com.aimanager.delivery.ConfigurationChangedNotice;
import java.time.Clock;
import java.time.Duration;
import java.util.concurrent.TimeUnit;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.AnyNestedCondition;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Conditional;
import org.springframework.modulith.events.IncompleteEventPublications;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Multi-replica retries may duplicate hints; clients always pull authoritative, versioned state. */
@Component
@Conditional(NotificationRetry.Enabled.class)
class NotificationRetry {
    private final IncompleteEventPublications incomplete;
    private final Clock clock;
    private final Duration minimumAge;
    NotificationRetry(IncompleteEventPublications incomplete, Clock clock, @Value("${manager.messaging.retry-seconds:30}") long seconds) {
        if (seconds < 5 || seconds > 3600) throw new IllegalArgumentException("Invalid notification retry period");
        this.incomplete = incomplete; this.clock = clock; this.minimumAge = Duration.ofSeconds(seconds);
    }
    @Scheduled(fixedDelayString = "${manager.messaging.retry-seconds:30}", timeUnit = TimeUnit.SECONDS)
    public void retry() {
        incomplete.resubmitIncompletePublications(p -> p.getEvent() instanceof ConfigurationChangedNotice
            && p.getPublicationDate().isBefore(clock.instant().minus(minimumAge)));
    }
    static class Enabled extends AnyNestedCondition {
        Enabled() { super(ConfigurationPhase.REGISTER_BEAN); }
        @ConditionalOnProperty(prefix = "manager.messaging.kafka", name = "enabled", havingValue = "true") static class Kafka {}
        @ConditionalOnProperty(prefix = "manager.messaging.artemis", name = "enabled", havingValue = "true") static class Artemis {}
    }
}
