package com.aimanager;

import com.aimanager.schedule.ScheduleDefinition;
import com.aimanager.schedule.ScheduleEngine;
import com.aimanager.shared.DomainException;
import java.time.*;
import java.util.List;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

/** Offset folds must not permit the intervening disallowed local minutes. */
class ScheduleTest {
    private ScheduleDefinition plan(String zone, DayOfWeek day, String start, String end) {
        return new ScheduleDefinition(zone, List.of(new ScheduleDefinition.WeeklyWindow(day, start, end)), List.of());
    }
    @Test void fallFoldMapsNarrowWindowTwiceWithoutFillingTheGap() {
        var definition = plan("America/New_York", DayOfWeek.SUNDAY, "01:10", "01:20");
        assertThat(ScheduleEngine.intervals(definition, LocalDate.parse("2026-11-01"))).containsExactly(
            new ScheduleEngine.Interval(Instant.parse("2026-11-01T05:10:00Z"), Instant.parse("2026-11-01T05:20:00Z")),
            new ScheduleEngine.Interval(Instant.parse("2026-11-01T06:10:00Z"), Instant.parse("2026-11-01T06:20:00Z")));
        assertThat(ScheduleEngine.evaluate(definition, Instant.parse("2026-11-01T05:30:00Z")).allowed()).isFalse();
        assertThat(ScheduleEngine.evaluate(definition, Instant.parse("2026-11-01T06:15:00Z")).allowed()).isTrue();
    }
    @Test void springGapStartsAtFirstValidInstantAndEntireGapIsEmpty() {
        var definition = plan("America/New_York", DayOfWeek.SUNDAY, "02:10", "03:10");
        assertThat(ScheduleEngine.intervals(definition, LocalDate.parse("2026-03-08"))).containsExactly(
            new ScheduleEngine.Interval(Instant.parse("2026-03-08T07:00:00Z"), Instant.parse("2026-03-08T07:10:00Z")));
        assertThat(ScheduleEngine.intervals(plan("America/New_York", DayOfWeek.SUNDAY, "02:10", "02:50"),
            LocalDate.parse("2026-03-08"))).isEmpty();
    }
    @Test void halfOpenEndAndCrossMidnightUseCalendarDates() {
        var definition = plan("Asia/Shanghai", DayOfWeek.MONDAY, "22:00", "01:00");
        assertThat(ScheduleEngine.evaluate(definition, Instant.parse("2026-10-05T16:30:00Z")).allowed()).isTrue();
        assertThat(ScheduleEngine.evaluate(definition, Instant.parse("2026-10-05T17:00:00Z")).allowed()).isFalse();
        assertThat(ScheduleEngine.evaluate(definition, Instant.parse("2026-10-06T14:30:00Z")).allowed()).isFalse();
    }
    @Test void closedDateOverrideSuppressesPreviousNightCarryover() {
        var definition = new ScheduleDefinition("Asia/Shanghai", plan("Asia/Shanghai", DayOfWeek.MONDAY, "22:00", "01:00").weekly(),
            List.of(new ScheduleDefinition.DateOverride(LocalDate.parse("2026-10-06"), List.of())));
        assertThat(ScheduleEngine.evaluate(definition, Instant.parse("2026-10-05T16:30:00Z")).allowed()).isFalse();
        assertThat(ScheduleEngine.evaluate(definition, Instant.parse("2026-10-05T15:59:00Z")).currentUntil())
            .isEqualTo(Instant.parse("2026-10-05T16:00:00Z"));
    }
    @Test void nonHourFoldUsesZoneRulesNotOneHourAssumption() {
        var definition = plan("Australia/Lord_Howe", DayOfWeek.SUNDAY, "01:40", "01:45");
        assertThat(ScheduleEngine.intervals(definition, LocalDate.parse("2026-04-05"))).containsExactly(
            new ScheduleEngine.Interval(Instant.parse("2026-04-04T14:40:00Z"), Instant.parse("2026-04-04T14:45:00Z")),
            new ScheduleEngine.Interval(Instant.parse("2026-04-04T15:10:00Z"), Instant.parse("2026-04-04T15:15:00Z")));
    }
    @Test void skippedDateHasNoInventedAllowedTime() {
        assertThat(ScheduleEngine.intervals(plan("Pacific/Apia", DayOfWeek.FRIDAY, "08:00", "12:00"),
            LocalDate.parse("2011-12-30"))).isEmpty();
    }
    @Test void duplicateDateEqualEndpointsAndUnknownZonesAreRejected() {
        var duplicate = new ScheduleDefinition("UTC", List.of(), List.of(
            new ScheduleDefinition.DateOverride(LocalDate.parse("2026-10-06"), List.of()),
            new ScheduleDefinition.DateOverride(LocalDate.parse("2026-10-06"), List.of())));
        assertThatThrownBy(() -> ScheduleEngine.validate(duplicate)).isInstanceOf(DomainException.class)
            .extracting("errorCode").isEqualTo("DUPLICATE_SCHEDULE_DATE");
        assertThatThrownBy(() -> ScheduleEngine.validate(plan("UTC", DayOfWeek.MONDAY, "00:00", "00:00")))
            .isInstanceOf(DomainException.class).extracting("errorCode").isEqualTo("AMBIGUOUS_SCHEDULE_WINDOW");
        assertThatThrownBy(() -> ScheduleEngine.validate(plan("UTC+99", DayOfWeek.MONDAY, "01:00", "02:00")))
            .isInstanceOf(DomainException.class).extracting("errorCode").isEqualTo("INVALID_TIME_ZONE");
    }
}
