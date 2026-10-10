package com.aimanager.reporting.internal;

import java.time.*;
import java.time.temporal.TemporalAdjusters;
import java.util.*;

/** Conservative bounds from self-reported aggregate intervals, never a quota ledger. */
final class UsageAggregation {
  private static final long MAX_TIME = 8640000000000000L;
  private static final Set<String> PROFILES = Set.of("PRIMARY", "WORK", "SECONDARY", "UNKNOWN");

  record Sample(
      long sequence,
      String profile,
      String packageName,
      String displayName,
      long start,
      long end,
      long foregroundMillis) {}

  record Window(long start, long end) {}

  record Bucket(
      long start,
      long end,
      Long lowerMillis,
      Long upperMillis,
      long coveredMillis,
      String status) {}

  record Application(
      String profile,
      String packageName,
      String displayName,
      int selectedIntervals,
      int discardedOverlaps,
      List<Bucket> buckets) {
    Application {
      buckets = List.copyOf(buckets);
    }
  }

  private record Key(String profile, String packageName) implements Comparable<Key> {
    @Override
    public int compareTo(Key other) {
      int profileOrder = profile.compareTo(other.profile);
      return profileOrder == 0 ? packageName.compareTo(other.packageName) : profileOrder;
    }
  }

  static List<Application> aggregate(
      List<Sample> samples, long from, long to, String timeZone, String period) {
    validateWindow(from, to);
    if (timeZone == null || !ZoneId.getAvailableZoneIds().contains(timeZone))
      throw new IllegalArgumentException("Invalid report time zone");
    var windows = buckets(from, to, ZoneId.of(timeZone), period);
    if (samples == null || samples.size() > 100000)
      throw new IllegalArgumentException("Invalid report sample count");
    var groups = new TreeMap<Key, List<Sample>>();
    for (var sample : samples) {
      validate(sample);
      if (sample.start() >= to || sample.end() <= from || sample.start() == sample.end()) continue;
      groups
          .computeIfAbsent(
              new Key(sample.profile(), sample.packageName()), ignored -> new ArrayList<>())
          .add(sample);
    }
    if (groups.size() > 2000)
      throw new IllegalArgumentException("Report has too many applications");
    var result = new ArrayList<Application>();
    for (var entry : groups.entrySet()) {
      var ordered = entry.getValue();
      ordered.sort(
          Comparator.comparingLong(Sample::sequence)
              .reversed()
              .thenComparing(Comparator.comparingLong(Sample::start).reversed())
              .thenComparing(Comparator.comparingLong(Sample::end).reversed()));
      var selected = new TreeMap<Long, Sample>();
      int discarded = 0;
      for (var sample : ordered) {
        var before = selected.floorEntry(sample.start());
        var after = selected.ceilingEntry(sample.start());
        if ((before != null && before.getValue().end() > sample.start())
            || (after != null && after.getKey() < sample.end())) {
          discarded++;
          continue;
        }
        selected.put(sample.start(), sample);
      }
      var values = new ArrayList<Bucket>();
      for (var window : windows) {
        long lower = 0, upper = 0, covered = 0;
        for (var sample : selected.values()) {
          long overlap =
              Math.max(
                  0,
                  Math.min(window.end(), sample.end()) - Math.max(window.start(), sample.start()));
          if (overlap == 0) continue;
          long outside = sample.end() - sample.start() - overlap;
          lower += Math.max(0, sample.foregroundMillis() - outside);
          upper += Math.min(sample.foregroundMillis(), overlap);
          covered += overlap;
        }
        if (covered == 0) {
          values.add(new Bucket(window.start(), window.end(), null, null, 0, "NO_EVIDENCE"));
        } else {
          upper += window.end() - window.start() - covered;
          values.add(
              new Bucket(
                  window.start(),
                  window.end(),
                  lower,
                  upper,
                  covered,
                  lower == upper ? "REPORTED_TOTAL" : "REPORTED_RANGE"));
        }
      }
      result.add(
          new Application(
              entry.getKey().profile(),
              entry.getKey().packageName(),
              ordered.get(0).displayName(),
              selected.size(),
              discarded,
              values));
    }
    return List.copyOf(result);
  }

  static List<Window> buckets(long from, long to, ZoneId zone, String period) {
    validateWindow(from, to);
    if (period == null || !Set.of("DAY", "WEEK").contains(period))
      throw new IllegalArgumentException("Invalid report period");
    var day = Instant.ofEpochMilli(from).atZone(zone).toLocalDate();
    if (period.equals("WEEK")) day = day.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY));
    var windows = new ArrayList<Window>();
    long cursor = from;
    while (cursor < to) {
      day = period.equals("WEEK") ? day.plusWeeks(1) : day.plusDays(1);
      long end = Math.min(to, day.atStartOfDay(zone).toInstant().toEpochMilli());
      // Some IANA transitions skip a whole local date (for example Apia 2011).
      // That date has no elapsed duration and must not create an empty bucket.
      if (end <= cursor) continue;
      windows.add(new Window(cursor, end));
      if (windows.size() > 33) throw new IllegalArgumentException("Too many report buckets");
      cursor = end;
    }
    return List.copyOf(windows);
  }

  static void validateWindow(long from, long to) {
    if (from <= 0 || to > MAX_TIME || from >= to || to - from > 32L * 86400000)
      throw new IllegalArgumentException("Invalid report window");
  }

  private static void validate(Sample sample) {
    if (sample == null
        || sample.sequence() <= 0
        || !PROFILES.contains(sample.profile())
        || sample.packageName() == null
        || sample.packageName().isBlank()
        || sample.packageName().length() > 255
        || sample.displayName() == null
        || sample.displayName().isBlank()
        || sample.displayName().length() > 100
        || sample.start() <= 0
        || sample.end() < sample.start()
        || sample.end() > MAX_TIME
        || sample.foregroundMillis() < 0
        || sample.foregroundMillis() > sample.end() - sample.start())
      throw new IllegalArgumentException("Invalid report evidence");
  }
}
