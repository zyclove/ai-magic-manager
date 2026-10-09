package com.aimanager.schedule;

import com.aimanager.shared.DomainException;
import java.time.*;
import java.util.*;

/** Calendar evaluation delegates offsets/transitions to java.time rather than a custom time-zone database. */
public final class ScheduleEngine {
    private ScheduleEngine() {}
    public static void validate(ScheduleDefinition definition) {
        try {
            if (!ZoneId.getAvailableZoneIds().contains(definition.timeZone())) throw new DateTimeException("Unknown IANA zone");
            ZoneId.of(definition.timeZone());
        } catch (DateTimeException failure) { throw DomainException.invalid("INVALID_TIME_ZONE"); }
        if (definition.exceptions().stream().map(ScheduleDefinition.DateOverride::date).distinct().count() != definition.exceptions().size())
            throw DomainException.invalid("DUPLICATE_SCHEDULE_DATE");
        if (definition.exceptions().stream().anyMatch(e -> e.date().getYear() < 1900 || e.date().getYear() > 2200))
            throw DomainException.invalid("INVALID_SCHEDULE_DATE");
        definition.weekly().forEach(w -> validateWindow(w.start(), w.end()));
        definition.exceptions().forEach(e -> e.windows().forEach(w -> validateWindow(w.start(), w.end())));
    }
    private static void validateWindow(String start, String end) {
        if (LocalTime.parse(start).equals(LocalTime.parse(end))) throw DomainException.invalid("AMBIGUOUS_SCHEDULE_WINDOW");
    }

    /** DST folds produce two disjoint intervals when appropriate; gap boundaries move to the transition instant. */
    public static List<Interval> intervals(ScheduleDefinition definition, LocalDate date) {
        ZoneId zone = ZoneId.of(definition.timeZone());
        Instant dayStart = date.atStartOfDay(zone).toInstant(), dayEnd = date.plusDays(1).atStartOfDay(zone).toInstant();
        var candidates = new ArrayList<Interval>(anchorIntervals(definition, date));
        if (override(definition, date).isEmpty()) candidates.addAll(anchorIntervals(definition, date.minusDays(1)));
        return merge(candidates.stream().map(i -> new Interval(later(i.start(), dayStart), earlier(i.end(), dayEnd)))
            .filter(i -> i.start().isBefore(i.end())).toList());
    }

    public static Decision evaluate(ScheduleDefinition definition, Instant at) {
        validate(definition);
        if (at.isBefore(Instant.parse("1900-01-01T00:00:00Z")) || !at.isBefore(Instant.parse("2201-01-01T00:00:00Z")))
            throw DomainException.invalid("INVALID_SCHEDULE_INSTANT");
        LocalDate date = at.atZone(ZoneId.of(definition.timeZone())).toLocalDate();
        var windows = new ArrayList<Interval>();
        // Bounded preview only; absence of a next window is not a claim about all future dates.
        for (int day = 0; day < 8; day++) windows.addAll(intervals(definition, date.plusDays(day)));
        for (var interval : merge(windows)) {
            if (!at.isBefore(interval.start()) && at.isBefore(interval.end()))
                return new Decision(true, interval.end(), null, definition.timeZone(), date, "WITHIN_ALLOWED_WINDOW", 8);
            if (at.isBefore(interval.start()))
                return new Decision(false, null, interval.start(), definition.timeZone(), date, "OUTSIDE_ALLOWED_WINDOW", 8);
        }
        return new Decision(false, null, null, definition.timeZone(), date, "NO_WINDOW_IN_PREVIEW_HORIZON", 8);
    }

    private static Optional<ScheduleDefinition.DateOverride> override(ScheduleDefinition definition, LocalDate date) {
        return definition.exceptions().stream().filter(e -> e.date().equals(date)).findFirst();
    }
    private static List<Interval> anchorIntervals(ScheduleDefinition definition, LocalDate date) {
        var windows = override(definition, date).map(ScheduleDefinition.DateOverride::windows).orElseGet(() -> definition.weekly().stream()
            .filter(w -> w.day() == date.getDayOfWeek()).map(w -> new ScheduleDefinition.Window(w.start(), w.end())).toList());
        var result = new ArrayList<Interval>();
        for (var window : windows) {
            LocalTime start = LocalTime.parse(window.start()), end = LocalTime.parse(window.end());
            LocalDateTime localStart = date.atTime(start), localEnd = (end.isAfter(start) ? date : date.plusDays(1)).atTime(end);
            result.addAll(mapLocalRange(localStart, localEnd, ZoneId.of(definition.timeZone())));
        }
        return result;
    }
    private static List<Interval> mapLocalRange(LocalDateTime start, LocalDateTime end, ZoneId zone) {
        var rules = zone.getRules();
        Instant cursor = start.toInstant(ZoneOffset.UTC).minus(Duration.ofDays(2));
        Instant ceiling = end.toInstant(ZoneOffset.UTC).plus(Duration.ofDays(2));
        var result = new ArrayList<Interval>();
        while (cursor.isBefore(ceiling)) {
            var offset = rules.getOffset(cursor);
            var transition = rules.nextTransition(cursor);
            Instant segmentEnd = transition == null ? ceiling : earlier(transition.getInstant(), ceiling);
            Instant from = later(start.toInstant(offset), cursor), until = earlier(end.toInstant(offset), segmentEnd);
            if (from.isBefore(until)) result.add(new Interval(from, until));
            cursor = segmentEnd;
        }
        return result;
    }
    private static List<Interval> merge(List<Interval> input) {
        var sorted = input.stream().sorted(Comparator.comparing(Interval::start)).toList();
        var output = new ArrayList<Interval>();
        for (var interval : sorted) {
            if (output.isEmpty() || output.get(output.size() - 1).end().isBefore(interval.start())) output.add(interval);
            else {
                var previous = output.remove(output.size() - 1);
                output.add(new Interval(previous.start(), later(previous.end(), interval.end())));
            }
        }
        return List.copyOf(output);
    }
    private static Instant later(Instant a, Instant b) { return a.isAfter(b) ? a : b; }
    private static Instant earlier(Instant a, Instant b) { return a.isBefore(b) ? a : b; }
    public record Interval(Instant start, Instant end) {}
    public record Decision(boolean allowed, Instant currentUntil, Instant nextAllowedAt, String timeZone,
                           LocalDate localDate, String reasonCode, int previewDays) {}
}
