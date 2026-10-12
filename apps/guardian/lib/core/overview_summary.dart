import 'api.dart';

/// A bounded server projection. Nullable counts are unavailable to this role, not zero.
class OverviewSummary {
  final int? subjectCount;
  final int? activeDeviceCount;
  final int? connectionCheckCount;
  final int? policyDraftCount;
  final int pendingRequestCount;
  final List<OverviewActivity> recentActivity;

  OverviewSummary._(
      this.subjectCount,
      this.activeDeviceCount,
      this.connectionCheckCount,
      this.policyDraftCount,
      this.pendingRequestCount,
      this.recentActivity);

  static OverviewSummary parse(Object? input) {
    if (input is! Map<String, dynamic>) _invalid();
    final value = input;
    final activity = value['recentActivity'];
    if (activity is! List || activity.length > 5) _invalid();
    return OverviewSummary._(
        _count(value['subjectCount']),
        _count(value['activeDeviceCount']),
        _count(value['connectionCheckCount']),
        _count(value['policyDraftCount']),
        _count(value['pendingRequestCount'], required: true)!,
        List<OverviewActivity>.unmodifiable(
            activity.map(OverviewActivity.parse)));
  }
}

class OverviewActivity {
  final String id;
  final String action;
  final String resourceId;
  final int occurredAt;

  OverviewActivity._(this.id, this.action, this.resourceId, this.occurredAt);

  static OverviewActivity parse(Object? input) {
    if (input is! Map<String, dynamic>) _invalid();
    final row = input;
    final id = row['id'], action = row['action'], resource = row['resourceId'];
    final occurred = row['occurredAt'];
    if (id is! String ||
        id.isEmpty ||
        action is! String ||
        action.isEmpty ||
        resource is! String ||
        occurred is! int ||
        occurred < 0) _invalid();
    return OverviewActivity._(id, action, resource, occurred);
  }
}

int? _count(Object? value, {bool required = false}) {
  if (value == null && !required) return null;
  if (value is! int || value < 0) _invalid();
  return value;
}

Never _invalid() => throw const ApiFailure(502, 'INVALID_RESPONSE');
