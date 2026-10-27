import 'package:flutter/foundation.dart';
import 'api.dart';

final _subjectId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _archiveRequestKey = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
const _maxVersion = 9007199254740991;

bool _matches(RegExp pattern, Object? value) => value is String &&
    pattern.firstMatch(value)?.end == value.length;

Json _snapshot(Object? value) {
  if (value is! Map ||
      !_matches(_subjectId, value['id']) ||
      value['nickname'] is! String ||
      (value['nickname'] as String).trim().isEmpty ||
      !const {'UNDER_7', 'AGE_7_12', 'AGE_13_17'}.contains(value['ageBand']) ||
      value['version'] is! int ||
      (value['version'] as int) < 0 ||
      (value['version'] as int) > _maxVersion ||
      !const {'ACTIVE', 'ARCHIVED'}.contains(value['state'])) {
    throw const ApiFailure(502, 'INVALID_RESPONSE');
  }
  return Map<String, dynamic>.unmodifiable({
    for (final key in ['id', 'nickname', 'ageBand', 'version', 'state'])
      key: value[key],
  });
}

/// One archive attempt keeps its identity and never replays an uncertain write.
class SubjectArchiveOperation extends ChangeNotifier {
  final String root, requestKey;
  final Json subject;
  final bool Function() _isCurrent;
  final VoidCallback? onSubmitAttempt;
  late final Json body;
  late final Api _api;
  bool busy = false, attempted = false, uncertain = false, stopped = false;
  bool _disposed = false, _lost = false;
  Object? error;
  Json? result, currentSnapshot;

  SubjectArchiveOperation({required Api api, required this.root,
      required this.requestKey, required Json subject,
      required bool Function() isCurrent, this.onSubmitAttempt})
      : subject = _snapshot(subject), _isCurrent = isCurrent {
    if (this.subject['state'] != 'ACTIVE' ||
        (this.subject['version'] as int) >= _maxVersion ||
        !_matches(_archiveRequestKey, requestKey)) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    body = Map<String, dynamic>.unmodifiable({
      'operation': 'ARCHIVE',
      'subjectId': this.subject['id'],
      'version': this.subject['version'],
    });
    _api = api.scoped(() => current);
  }

  bool get current {
    if (_disposed || _lost) return false;
    if (!_isCurrent()) _lost = true;
    return !_lost;
  }

  bool get canSubmit => current && !busy && !uncertain && !stopped && result == null;
  bool get canQuery => current && !busy && uncertain && !stopped && result == null;

  Json _committed(Object? value) {
    final snapshot = _snapshot(value);
    if (snapshot['id'] != subject['id'] || snapshot['state'] != 'ARCHIVED' ||
        snapshot['version'] != (subject['version'] as int) + 1 ||
        snapshot['nickname'] != subject['nickname'] ||
        snapshot['ageBand'] != subject['ageBand']) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    return snapshot;
  }

  bool _terminal(Object failure) => failure is ApiFailure &&
      (failure.status == 412 || isUnavailableOperationResult(failure));

  bool _unknown(Object failure) => failure is! ApiFailure ||
      failure.status == 0 || failure.status == 408 || failure.status >= 500 ||
      failure.code == 'PENDING_OPERATION_UNCHANGED';

  void _start() {
    busy = true;
    error = null;
    notifyListeners();
  }

  void _finish() {
    busy = false;
    if (current) notifyListeners();
  }

  Future<void> submit() async {
    if (!canSubmit) return;
    _start();
    try {
      if (!current) return;
      attempted = true;
      onSubmitAttempt?.call();
      final value = await _api.send('POST', '$root/subjects/changes',
          key: requestKey, body: body);
      if (current) result = _committed(value);
    } catch (failure) {
      if (!current) return;
      error = failure;
      if (_terminal(failure)) stopped = true;
      if (_unknown(failure)) uncertain = true;
    } finally {
      _finish();
    }
  }

  Future<void> query() async {
    if (!canQuery) return;
    _start();
    try {
      final value = await _api.send('POST',
          '$root/subjects/operation-results/$requestKey/query', body: body);
      if (!current) return;
      if (value is! Map || value['operation'] != 'ARCHIVE') {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      final committed = _committed(value['committed']);
      final latest = _snapshot(value['current']);
      if (latest['id'] != subject['id'] || latest['state'] != 'ARCHIVED' ||
          (latest['version'] as int) < (committed['version'] as int)) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      result = committed;
      currentSnapshot = latest;
    } catch (failure) {
      if (!current) return;
      error = failure;
      if (_terminal(failure)) stopped = true;
    } finally {
      _finish();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
