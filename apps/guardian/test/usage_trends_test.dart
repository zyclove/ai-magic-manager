import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/usage_reports.dart';
import 'package:guardian/core/usage_trends.dart';

UsageReportBucket day(int day, int? lower, int? upper, {String zone = 'UTC'}) {
  final bounds = usageCalendarWindow(
      DateTime(2026, 10, day), DateTime(2026, 10, day), zone);
  return UsageReportBucket(
      bounds.$1,
      bounds.$2,
      lower,
      upper,
      lower == null ? 0 : bounds.$2 - bounds.$1,
      lower == null
          ? 'NO_EVIDENCE'
          : lower == upper
              ? 'REPORTED_TOTAL'
              : 'REPORTED_RANGE');
}

void main() {
  test('range subtraction does not invent certainty from overlapping bounds',
      () {
    final trend = usageTrendComparison(
        [day(1, 1000, 4000), day(2, 2000, 5000)], 'UTC', 'DAY');
    expect(trend.status, 'UNCERTAIN');
    expect(trend.lowerDeltaMillis, -2000);
    expect(trend.upperDeltaMillis, 4000);
    final rising = usageTrendComparison(
        [day(1, 1000, 2000), day(2, 4000, 6000)], 'UTC', 'DAY');
    expect(rising.status, 'INCREASE');
    expect(rising.lowerDeltaMillis, 2000);
    expect(rising.upperDeltaMillis, 5000);
    expect(
        usageTrendComparison(
                [day(1, 4000, 6000), day(2, 1000, 2000)], 'UTC', 'DAY')
            .status,
        'DECREASE');
    expect(
        usageTrendComparison([day(1, 0, 0), day(2, 0, 0)], 'UTC', 'DAY').status,
        'UNCHANGED');
  });
  test('unknown and missing periods are never treated as zero or bridged', () {
    expect(
        usageTrendComparison(
                [day(1, 1000, 1000), day(2, null, null)], 'UTC', 'DAY')
            .status,
        'NO_EVIDENCE');
    expect(usageTrendComparison([day(1, 1000, 1000)], 'UTC', 'DAY').status,
        'INSUFFICIENT_PERIODS');
    expect(
        usageTrendComparison(
                [day(1, 1000, 1000), day(3, 2000, 2000)], 'UTC', 'DAY')
            .status,
        'NOT_COMPARABLE');
  });
  test('partial final day is shown but excluded from the comparison', () {
    final partial = day(3, 100, 100);
    final trend = usageTrendComparison([
      day(1, 1000, 1000),
      day(2, 2000, 2000),
      UsageReportBucket(partial.start, partial.start + 3600000, 100, 100,
          3600000, 'REPORTED_TOTAL')
    ], 'UTC', 'DAY');
    expect(trend.status, 'INCREASE');
    expect(trend.current!.start, day(2, 0, 0).start);
    expect(trend.partialPeriods, 1);
  });
  test('DST days of unequal duration are not compared as equivalent periods',
      () {
    final first = usageCalendarWindow(
        DateTime(2026, 3, 7), DateTime(2026, 3, 7), 'America/New_York');
    final second = usageCalendarWindow(
        DateTime(2026, 3, 8), DateTime(2026, 3, 8), 'America/New_York');
    final trend = usageTrendComparison([
      UsageReportBucket(first.$1, first.$2, 1000, 1000, first.$2 - first.$1,
          'REPORTED_TOTAL'),
      UsageReportBucket(second.$1, second.$2, 2000, 2000, second.$2 - second.$1,
          'REPORTED_TOTAL')
    ], 'America/New_York', 'DAY');
    expect(trend.status, 'NOT_COMPARABLE');
  });
  test('week comparison requires complete Monday boundaries', () {
    final first = usageCalendarWindow(
        DateTime(2026, 9, 28), DateTime(2026, 10, 4), 'UTC');
    final second = usageCalendarWindow(
        DateTime(2026, 10, 5), DateTime(2026, 10, 11), 'UTC');
    expect(
        usageTrendComparison([
          UsageReportBucket(first.$1, first.$2, 1000, 1000, first.$2 - first.$1,
              'REPORTED_TOTAL'),
          UsageReportBucket(second.$1, second.$2, 2000, 2000,
              second.$2 - second.$1, 'REPORTED_TOTAL')
        ], 'UTC', 'WEEK')
            .status,
        'INCREASE');
    expect(
        usageTrendComparison(
                [day(1, 1000, 1000), day(2, 2000, 2000)], 'UTC', 'WEEK')
            .status,
        'INSUFFICIENT_PERIODS');
  });
  test('signed difference labels round outward rather than hiding uncertainty',
      () {
    expect(usageDeltaRange(-1501, 2501), '−2 至 +3 秒');
    expect(usageDeltaRange(0, 0), '0 秒');
    expect(usageDeltaRange(1000, 1000), '+1 秒');
    expect(usageDeltaRange(1000, 60000), '+1 秒 至 +1 分钟');
  });
}
