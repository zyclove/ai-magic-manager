package com.aimanager.reporting.internal;

import static org.assertj.core.api.Assertions.*;

import java.time.*;
import java.util.*;
import org.junit.jupiter.api.Test;

class UsageAggregationTest {
  UsageAggregation.Sample sample(long sequence, long start, long end, long used) {
    return new UsageAggregation.Sample(
        sequence, "PRIMARY", "org.example.reader", "阅读", start, end, used);
  }

  UsageAggregation.Application only(List<UsageAggregation.Sample> samples, long from, long to) {
    return UsageAggregation.aggregate(samples, from, to, "UTC", "DAY").get(0);
  }

  @Test
  void latestIdenticalIntervalReplacesOldRatherThanAdding() {
    var app = only(List.of(sample(1, 1000, 2000, 100), sample(2, 1000, 2000, 300)), 1000, 2000);
    assertThat(app.selectedIntervals()).isEqualTo(1);
    assertThat(app.discardedOverlaps()).isEqualTo(1);
    assertThat(app.buckets().get(0).lowerMillis()).isEqualTo(300L);
    assertThat(app.buckets().get(0).upperMillis()).isEqualTo(300L);
  }

  @Test
  void overlappingIntervalsNeverBecomeAdditiveUsage() {
    var app = only(List.of(sample(2, 1500, 2500, 900), sample(1, 1000, 2000, 700)), 1000, 3000);
    var bucket = app.buckets().get(0);
    assertThat(app.discardedOverlaps()).isEqualTo(1);
    assertThat(bucket.lowerMillis()).isEqualTo(900L);
    assertThat(bucket.upperMillis()).isEqualTo(1900L);
    assertThat(bucket.coveredMillis()).isEqualTo(1000L);
    assertThat(bucket.status()).isEqualTo("REPORTED_RANGE");
  }

  @Test
  void disjointIntervalsAddAndMissingCoverageRemainsUncertain() {
    var bucket =
        only(List.of(sample(1, 1000, 1500, 100), sample(2, 2000, 2500, 200)), 1000, 3000)
            .buckets()
            .get(0);
    assertThat(bucket.lowerMillis()).isEqualTo(300L);
    assertThat(bucket.upperMillis()).isEqualTo(1300L);
    assertThat(bucket.coveredMillis()).isEqualTo(1000L);
  }

  @Test
  void crossingBoundaryDoesNotProportionallyAllocateUsage() {
    var bucket = only(List.of(sample(1, 1000, 2000, 600)), 1000, 1500).buckets().get(0);
    assertThat(bucket.lowerMillis()).isEqualTo(100L);
    assertThat(bucket.upperMillis()).isEqualTo(500L);
    assertThat(bucket.status()).isEqualTo("REPORTED_RANGE");
  }

  @Test
  void missingDayIsUnknownWhileExplicitCompleteZeroIsReportedZero() {
    long start = Instant.parse("2026-10-01T00:00:00Z").toEpochMilli(), day = 86400000;
    var app = only(List.of(sample(1, start, start + day, 0)), start, start + day * 2);
    assertThat(app.buckets().get(0).lowerMillis()).isZero();
    assertThat(app.buckets().get(0).status()).isEqualTo("REPORTED_TOTAL");
    assertThat(app.buckets().get(1).lowerMillis()).isNull();
    assertThat(app.buckets().get(1).upperMillis()).isNull();
    assertThat(app.buckets().get(1).status()).isEqualTo("NO_EVIDENCE");
    assertThat(UsageAggregation.aggregate(List.of(), start, start + day, "UTC", "DAY")).isEmpty();
  }

  @Test
  void dayBucketsRespectDstRatherThanAssumingTwentyFourHours() {
    var zone = ZoneId.of("America/New_York");
    for (var date : List.of(LocalDate.of(2026, 3, 8), LocalDate.of(2026, 11, 1))) {
      long start = date.atStartOfDay(zone).toInstant().toEpochMilli(),
          end = date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli();
      var buckets = UsageAggregation.buckets(start, end, zone, "DAY");
      assertThat(buckets).hasSize(1);
      assertThat(buckets.get(0).end() - buckets.get(0).start())
          .isEqualTo(date.getMonthValue() == 3 ? 23 * 3600000L : 25 * 3600000L);
    }
  }

  @Test
  void weekBoundsAreComputedDirectlyAndSeparateSystemProfiles() {
    long start = Instant.parse("2026-10-05T00:00:00Z").toEpochMilli(), end = start + 7 * 86400000L;
    var samples =
        List.of(
            sample(1, start, end, 3600000),
            new UsageAggregation.Sample(
                2, "WORK", "org.example.reader", "工作阅读", start, end, 7200000));
    var apps = UsageAggregation.aggregate(samples, start, end, "UTC", "WEEK");
    assertThat(apps).hasSize(2);
    assertThat(apps.get(0).buckets()).hasSize(1);
    assertThat(apps.get(0).buckets().get(0).lowerMillis()).isEqualTo(3600000L);
    assertThat(apps.get(1).buckets().get(0).lowerMillis()).isEqualTo(7200000L);
  }

  @Test
  void intervalBoundsEncloseEveryPossibleDistributionAtSmallScale() {
    // Enumerate all 8-bit foreground timelines; endpoints are milliseconds here.
    for (int mask = 0; mask < 256; mask++)
      for (int left = 0; left < 8; left++)
        for (int right = left + 1; right <= 8; right++) {
          int total = Integer.bitCount(mask), inside = 0;
          for (int bit = left; bit < right; bit++) if ((mask & (1 << bit)) != 0) inside++;
          var bucket =
              only(List.of(sample(1, 1000, 1008, total)), 1000 + left, 1000 + right)
                  .buckets()
                  .get(0);
          assertThat(bucket.lowerMillis()).isLessThanOrEqualTo((long) inside);
          assertThat(bucket.upperMillis()).isGreaterThanOrEqualTo((long) inside);
        }
  }

  @Test
  void invalidWindowsZonesAndEvidenceFailExplicitly() {
    assertThatThrownBy(() -> UsageAggregation.aggregate(List.of(), 2000, 1000, "UTC", "DAY"))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> UsageAggregation.aggregate(List.of(), 1000, 2000, "not/a/zone", "DAY"))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> UsageAggregation.aggregate(List.of(), 1000, 2000, "UTC", "MONTH"))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> only(List.of(sample(1, 1000, 2000, 1001)), 1000, 2000))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void skippedCivilDateDoesNotCreateAnEmptyOrInvalidBucket() {
    var zone = ZoneId.of("Pacific/Apia");
    long start = LocalDate.of(2011, 12, 29).atStartOfDay(zone).toInstant().toEpochMilli();
    long end = LocalDate.of(2012, 1, 1).atStartOfDay(zone).toInstant().toEpochMilli();
    var windows = UsageAggregation.buckets(start, end, zone, "DAY");
    assertThat(windows).hasSize(2);
    assertThat(windows.stream().mapToLong(w -> w.end() - w.start()).sum()).isEqualTo(end - start);
  }
}
