import 'package:flutter/foundation.dart';
import 'api.dart';
import 'subject_change.dart';

final _archiveRequestKey = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

bool _matches(RegExp pattern, Object? value) => value is String &&
    pattern.firstMatch(value)?.end == value.length;

/// One archive attempt keeps its identity and never replays an uncertain write.
class SubjectArchiveOperation extends ChangeNotifier {
  final String root, requestKey;
  late final Json subject;
  late final SubjectChangeDraft _draft;
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
      : _isCurrent = isCurrent {
    _draft = SubjectChangeDraft.archive(subject);
    this.subject = _draft.before!;
    if (!_matches(_archiveRequestKey, requestKey)) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    body = _draft.body;
    _api = api.scoped(() => current);
  }

  bool get current {
    if (_disposed || _lost) return false;
    if (!_isCurrent()) _lost = true;
    return !_lost;
  }

  bool get canSubmit => current && !busy && !uncertain && !stopped && result == null;
  bool get canQuery => current && !busy && uncertain && !stopped && result == null;

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
      if (current) result = _draft.committed(value);
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
      final snapshots = _draft.queryResult(value);
      result = snapshots.committed;
      currentSnapshot = snapshots.current;
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
