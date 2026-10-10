import 'package:timezone/timezone.dart' as tz;
import 'usage_reports.dart';

class UsageTrendComparison {
  final String status;
  final int? lowerDeltaMillis, upperDeltaMillis;
  final UsageReportBucket? previous, current;
  final int partialPeriods;
  const UsageTrendComparison(
      this.status, this.previous, this.current, this.partialPeriods,
      [this.lowerDeltaMillis, this.upperDeltaMillis]);
}

bool isWholeUsagePeriod(UsageReportBucket bucket, String zone, String period) {
  if (period != 'DAY' && period != 'WEEK') {
    throw ArgumentError.value(period, 'period');
  }
  final location = usageLocation(zone),
      date = usageLocalTime(bucket.start, zone);
  if (period == 'WEEK' && date.weekday != DateTime.monday) return false;
  final start = tz.TZDateTime(location, date.year, date.month, date.day)
      .millisecondsSinceEpoch;
  final end = tz.TZDateTime(
          location, date.year, date.month, date.day + (period == 'DAY' ? 1 : 7))
      .millisecondsSinceEpoch;
  return bucket.start == start && bucket.end == end;
}

/// Bounds are subtracted as intervals; neither missing evidence nor partial days become zero.
UsageTrendComparison usageTrendComparison(
    List<UsageReportBucket> buckets, String zone, String period) {
  final complete =
      buckets.where((b) => isWholeUsagePeriod(b, zone, period)).toList();
  final partial = buckets.length - complete.length;
  if (complete.length < 2) {
    return UsageTrendComparison('INSUFFICIENT_PERIODS', null, null, partial);
  }
  final previous = complete[complete.length - 2], current = complete.last;
  if (previous.end != current.start ||
      previous.end - previous.start != current.end - current.start) {
    return UsageTrendComparison('NOT_COMPARABLE', previous, current, partial);
  }
  if (previous.lowerMillis == null || current.lowerMillis == null) {
    return UsageTrendComparison('NO_EVIDENCE', previous, current, partial);
  }
  final lower = current.lowerMillis! - previous.upperMillis!,
      upper = current.upperMillis! - previous.lowerMillis!;
  final status = lower > 0
      ? 'INCREASE'
      : upper < 0
          ? 'DECREASE'
          : lower == 0 && upper == 0
              ? 'UNCHANGED'
              : 'UNCERTAIN';
  return UsageTrendComparison(status, previous, current, partial, lower, upper);
}

String _signedSeconds(int value) {
  final seconds = value.abs(),
      prefix = value > 0
          ? '+'
          : value < 0
              ? '−'
              : '';
  if (seconds >= 3600 && seconds % 3600 == 0) {
    return '$prefix${seconds ~/ 3600} 小时';
  }
  if (seconds >= 60 && seconds % 60 == 0) return '$prefix${seconds ~/ 60} 分钟';
  return '$prefix$seconds 秒';
}

String usageDeltaRange(int lower, int upper) {
  if (lower > upper) throw ArgumentError('Reversed usage difference');
  final from = (lower / 1000).floor(), to = (upper / 1000).ceil();
  if (from == to) return _signedSeconds(from);
  final lowerText = _signedSeconds(from), upperText = _signedSeconds(to);
  final label = lowerText.endsWith(' 秒') && upperText.endsWith(' 秒')
      ? lowerText.substring(0, lowerText.length - 2)
      : lowerText;
  return '$label 至 $upperText';
}
