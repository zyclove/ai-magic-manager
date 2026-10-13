import 'package:usage_reporting/usage_reporting.dart';
import 'parent_api.dart';

/// Explicit, bounded targets retain their original registration while paging.
UsageReportTarget? parentReportTarget(Json value) {
  if (value['state'] != 'ACTIVE' ||
      ['id', 'registrationId', 'subjectId', 'displayName', 'platform']
          .any((k) => value[k] is! String)) return null;
  final target = UsageReportTarget(value['id'], value['registrationId'],
      value['subjectId'], value['displayName'],
      platform: value['platform']);
  return target.valid ? target : null;
}

class ParentReportSelection {
  static const limit = 20;
  final _selected = <String, UsageReportTarget>{};
  List<UsageReportTarget> get targets => List.unmodifiable(_selected.values);
  int get length => _selected.length;
  bool contains(String id) => _selected.containsKey(id);
  void remove(String id) => _selected.remove(id);
  void clear() => _selected.clear();

  /// All-or-nothing selection; never silently take the first twenty devices.
  void add(Iterable<UsageReportTarget> targets) {
    final next = {..._selected};
    for (final target in targets) {
      if (!target.valid) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      final before = next[target.deviceId];
      if (before != null &&
          (before.registrationId != target.registrationId ||
              before.subjectId != target.subjectId ||
              before.platform != target.platform)) {
        throw const ParentApiException(409, 'REGISTRATION_CHANGED');
      }
      next[target.deviceId] = target;
    }
    if (next.length > limit) {
      throw const FormatException('即时报告最多选择 20 台，请缩小范围或逐项选择。');
    }
    _selected
      ..clear()
      ..addAll(next);
  }
}
