import 'usage_reports.dart';
import 'usage_trends.dart';

/// A local, explainable prompt derived only from an authorized usage report.
/// It is not a diagnosis, enforcement decision, or policy change.
enum UsageInsightKind {
  reviewIncrease,
  reviewDecrease,
  checkEvidence,
  keepObserving,
}

class UsageInsight {
  final UsageInsightKind kind;
  final UsageTrendComparison comparison;
  final int comparedPeriods;
  const UsageInsight(this.kind, this.comparison, this.comparedPeriods);
}

/// Compare the last two full, contiguous periods. A positive lower bound is
/// required before suggesting an increase; overlapping ranges remain unknown.
/// Callers must not combine different apps into a unique child screen-time total.
UsageInsight usageInsightForApplication(
    List<UsageReportBucket> buckets, String zone, String period) {
  final comparison = usageTrendComparison(buckets, zone, period);
  final kind = switch (comparison.status) {
    'INCREASE' => UsageInsightKind.reviewIncrease,
    'DECREASE' => UsageInsightKind.reviewDecrease,
    'UNCHANGED' => UsageInsightKind.keepObserving,
    _ => UsageInsightKind.checkEvidence,
  };
  return UsageInsight(kind, comparison, comparison.previous == null ? 0 : 2);
}
