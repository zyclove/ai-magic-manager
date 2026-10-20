import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/execution_operation_journal.dart';
import '../core/managed_execution.dart';
import '../core/managed_execution_review.dart';
import '../core/managed_execution_review_repository.dart';

/// A single task's cancel/recheck coordinator. Host scope is captured before
/// construction and must permanently detect ABA; a detached instance never revives.
class ManagedExecutionReviewController extends ChangeNotifier {
  final ManagedExecutionReviewRepository requests;
  final ExecutionOperationJournal journal;
  final bool Function() viewCurrent;
  final String Function() operationId;
  final int Function() now;
  final void Function(ManagedExecution) onProgress;
  final int Function()? latestEventRevision;
  final ManagedExecution _original;

  ManagedExecution? _task;
  ExecutionOperationPending? _pending;
  ExecutionReviewEligibility? _eligibility;
  Object? _error;
  String? _notice;
  ApiFailure? _accessFailure;
  bool _attached = true, _disposed = false, _busy = false;
  bool _restored = false, _storageBlocked = false, _needsReauth = false;
  bool _detailVerified = false;
  int _epoch = 0;
  _ReviewConfirmation? _confirmation;
  _ReviewAttempt? _attempt;

  ManagedExecutionReviewController(
      {required this.requests,
      required this.journal,
      required ManagedExecution selected,
      required this.viewCurrent,
      required this.operationId,
      required this.now,
      required this.onProgress,
      this.latestEventRevision})
      : _original = selected,
        _task = selected {
    if (selected.deviceId != requests.deviceId ||
        selected.registrationId != requests.registrationId) {
      throw const ApiFailure(400, 'INVALID_EXECUTION_ID');
    }
  }

  bool get hasAccess {
    if (_disposed || !_attached) return false;
    try {
      return requests.current() && viewCurrent();
    } catch (_) {
      return false;
    }
  }

  ManagedExecution? get selected => hasAccess ? _task : null;
  ExecutionOperationPending? get pending => hasAccess ? _pending : null;
  ExecutionReviewEligibility? get eligibility =>
      hasAccess ? _eligibility : null;
  Object? get error => hasAccess ? _error : null;
  String? get notice => hasAccess ? _notice : null;
  ApiFailure? get accessFailure => _accessFailure;
  bool get busy => hasAccess && _busy;
  bool get confirming => hasAccess && _confirmation != null;
  bool get initialized => hasAccess && _restored;
  bool get storageBlocked => hasAccess && _storageBlocked;
  bool get needsReauth => hasAccess && _needsReauth;
  bool get resultUnknown =>
      hasAccess && _pending?.phase == ExecutionOperationPhase.unknown;
  bool get rejectedNotApplied =>
      hasAccess &&
      _pending?.phase == ExecutionOperationPhase.rejectedNotApplied;
  bool get canQuery => hasAccess && !_busy && _task != null;
  bool get canRecheck =>
      !_busy && _actionAllowed(ExecutionOperationKind.recheckDevice);
  bool get canCancel => !_busy && _actionAllowed(ExecutionOperationKind.cancel);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool _guard() {
    if (_disposed || !_attached) return false;
    if (hasAccess) return true;
    _revoke(const ApiFailure(409, 'WORKSPACE_CHANGED'));
    return false;
  }

  bool _current(int epoch) => _guard() && epoch == _epoch;

  /// Host calls synchronously when its captured route/session/device scope changes.
  void checkScope() {
    _guard();
  }

  void _revoke(ApiFailure failure) {
    _accessFailure = failure;
    detach();
  }

  /// Closing never awaits storage or network. Late reserve can only perform its
  /// own causal zero-send cleanup; late POST success cannot restore this UI.
  void detach() {
    if (!_attached) return;
    _attached = false;
    _epoch++;
    _attempt?._retired = true;
    _confirmation = null;
    _task = null;
    _pending = null;
    _eligibility = null;
    _error = null;
    _notice = null;
    _busy = _restored = _detailVerified = _needsReauth = false;
    _changed();
  }

  /// This is an explicit host request, not login. A true result permanently
  /// detaches first. Host closes only its OwnedDialogRoute, awaits completed,
  /// then performs step-up and constructs a new controller; never auto-repost.
  bool requestStepUp() {
    if (!_guard() || !_needsReauth) return false;
    detach();
    return true;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detach();
    super.dispose();
  }

  bool _sameIdentity(ManagedExecution a, ManagedExecution b) =>
      a.id == b.id &&
      a.publicationId == b.publicationId &&
      a.deviceId == b.deviceId &&
      a.registrationId == b.registrationId &&
      a.createdAt == b.createdAt;

  bool _sameTask(ManagedExecution a, ManagedExecution b) {
    try {
      a.requireContinuationOf(b);
      return a.revision == b.revision;
    } on ApiFailure {
      return false;
    }
  }

  void _validateRecord(ExecutionOperationPending? record) {
    if (record != null &&
        (record.intent.owner != requests.owner ||
            !_sameIdentity(record.intent.task, _original))) {
      throw const ApiFailure(409, 'INVALID_EXECUTION_OPERATION_RECORD');
    }
  }

  bool _eventsAhead(ManagedExecution task) {
    try {
      return (latestEventRevision?.call() ?? 0) > task.revision;
    } catch (_) {
      return true;
    } // Unknown timeline freshness never grants a write.
  }

  bool _actionAllowed(ExecutionOperationKind kind) {
    final task = _task;
    if (!hasAccess ||
        !_restored ||
        _storageBlocked ||
        !_detailVerified ||
        _needsReauth ||
        !requests.writable ||
        task == null ||
        task.revision >= managedExecutionMaxRevision ||
        task.cancellationRequested ||
        _pending?.phase == ExecutionOperationPhase.unknown ||
        _eventsAhead(task)) return false;
    if (kind == ExecutionOperationKind.cancel) {
      return !const {'APPLIED', 'CANCELLED'}.contains(task.state);
    }
    final eligibility = _eligibility;
    return task.state == 'NEEDS_REVIEW' &&
        eligibility != null &&
        eligibility.allowed &&
        eligibility.id == task.id &&
        eligibility.publicationId == task.publicationId &&
        eligibility.deviceId == task.deviceId &&
        eligibility.registrationId == task.registrationId &&
        eligibility.revision == task.revision;
  }

  void _storageFailure(Object failure) {
    _storageBlocked = true;
    _restored = false;
    _error = failure is ApiFailure
        ? failure
        : const ApiFailure(503, 'EXECUTION_OPERATION_STORAGE_UNAVAILABLE');
    _notice = '操作记录尚未确认，请先重新读取本地记录。';
  }

  bool _privateFailure(Object failure) {
    if (failure is! ApiFailure) return false;
    if (failure.status == 403 ||
        (failure.status == 401 && failure.code != 'REAUTH_REQUIRED') ||
        failure.code == 'WORKSPACE_CHANGED') {
      _revoke(failure);
      return true;
    }
    if (failure.status == 401 && failure.code == 'REAUTH_REQUIRED') {
      _needsReauth = true;
    }
    return false;
  }

  void _failure(Object failure) {
    if (_privateFailure(failure)) return;
    if (_storageBlocked) return;
    _error = failure is ApiFailure
        ? failure
        : const ApiFailure(503, 'EXECUTION_OPERATION_UNAVAILABLE');
    if (_pending?.phase == ExecutionOperationPhase.unknown) {
      _notice = '暂不能确认是否已受理，请查询任务进展。';
    }
  }

  /// Local read only, including explicit recovery after uncertain storage.
  Future<void> initialize() => restore();
  Future<void> restore() async {
    if (!_guard() || _busy) return;
    final epoch = ++_epoch;
    _busy = true;
    _confirmation = null;
    _error = null;
    _changed();
    try {
      final record = await journal.read(requests.owner, _original.id);
      if (!_current(epoch)) return;
      _validateRecord(record);
      _pending = record;
      _restored = true;
      _storageBlocked = false;
      _detailVerified = false;
      _eligibility = null;
      _notice = record == null
          ? null
          : record.phase == ExecutionOperationPhase.unknown
              ? '暂不能确认是否已受理，请查询任务进展。'
              : '上次操作未被受理；请刷新状态后重新确认。';
    } catch (failure) {
      if (_current(epoch)) _storageFailure(failure);
    } finally {
      if (_current(epoch)) {
        _busy = false;
        _changed();
      }
    }
  }

  /// Both commands are explicit reads. Neither runs during restore or polling.
  Future<void> refresh() => _readProgress(loadEligibility: true);
  Future<void> query() => _readProgress(loadEligibility: false);

  Future<void> _reloadLocal(int epoch) async {
    try {
      final record = await journal.read(requests.owner, _original.id);
      if (!_current(epoch)) return;
      _validateRecord(record);
      _pending = record;
      _storageBlocked = false;
      _restored = true;
    } catch (failure) {
      if (_current(epoch)) _storageFailure(failure);
      rethrow;
    }
  }

  Future<bool> _fresh(int epoch, {required bool loadEligibility}) async {
    final previous = _task!;
    final base = _pending?.intent.task ?? previous;
    final value = await requests.detail(base);
    if (!_current(epoch)) return false;
    value.requireContinuationOf(previous);
    _task = value;
    _detailVerified = true;
    _eligibility = null;
    final pending = _pending;
    if (pending != null && value.revision > pending.intent.task.revision) {
      try {
        final removed =
            await journal.removeAfterObservedProgress(pending, value);
        if (!_current(epoch)) return false;
        if (removed) {
          _pending = null;
        } else {
          await _reloadLocal(epoch);
        }
        if (!_current(epoch)) return false;
        _notice = '任务已有新进展，请查看当前状态。';
      } catch (failure) {
        if (_current(epoch)) _storageFailure(failure);
        rethrow;
      }
    }
    if (loadEligibility) {
      final eligibility = await requests.eligibility(value);
      if (!_current(epoch)) return false;
      _eligibility = eligibility;
    }
    if (!_current(epoch)) return false;
    onProgress(value);
    return _current(epoch);
  }

  Future<void> _readProgress({required bool loadEligibility}) async {
    if (!_guard() || _busy) return;
    final epoch = ++_epoch;
    _busy = true;
    _detailVerified = false;
    _eligibility = null;
    _error = null;
    _changed();
    try {
      await _fresh(epoch, loadEligibility: loadEligibility);
    } catch (failure) {
      if (_current(epoch)) _failure(failure);
    } finally {
      if (_current(epoch)) {
        _busy = false;
        _changed();
      }
    }
  }

  Future<void> requestRecheck(
          Future<bool> Function(ManagedExecution) confirm) =>
      _request(ExecutionOperationKind.recheckDevice, confirm);
  Future<void> cancel(Future<bool> Function(ManagedExecution) confirm) =>
      _request(ExecutionOperationKind.cancel, confirm);

  Future<void> _request(ExecutionOperationKind kind,
      Future<bool> Function(ManagedExecution) confirm) async {
    if (!_guard() ||
        _busy ||
        !_restored ||
        _storageBlocked ||
        _needsReauth ||
        !requests.writable ||
        _pending?.phase == ExecutionOperationPhase.unknown) return;
    final epoch = ++_epoch;
    _busy =
        true; // Before the first await, including fresh reads and confirmation.
    _detailVerified = false;
    _eligibility = null;
    _error = null;
    _notice = null;
    _changed();
    _ReviewAttempt? attempt;
    try {
      if (!await _fresh(epoch,
              loadEligibility: kind == ExecutionOperationKind.recheckDevice) ||
          !_actionAllowed(kind)) return;
      final task = _task!;
      final token = _ReviewConfirmation(epoch, task, kind, _pending);
      _confirmation = token;
      _changed();
      final approved = await confirm(task);
      if (!_current(epoch) || !identical(_confirmation, token)) return;
      _confirmation = null;
      if (!approved || !_sameTask(_task!, token.task) || !_actionAllowed(kind)) {
        return;
      }
      final intent = ExecutionOperationIntent(
          owner: requests.owner,
          task: token.task,
          kind: token.kind,
          operationId: operationId(),
          createdAt: now());
      final active = _ReviewAttempt(intent);
      attempt = active;
      _attempt = active;
      ExecutionOperationReservation reservation;
      try {
        reservation = token.rejected == null
            ? await journal.reserve(intent)
            : await journal.replaceRejected(token.rejected!, intent);
      } catch (failure) {
        if (_current(epoch)) _storageFailure(failure);
        return; // A failed call may already have persisted UNKNOWN. Never guess.
      }
      if (!_current(epoch)) {
        active._retired = true;
        await _releaseNeverDispatched(active, reservation);
        return;
      }
      try {
        _validateRecord(reservation.record);
      } catch (failure) {
        _storageFailure(failure);
        return;
      }
      _pending = reservation.record;
      if (!reservation.maySubmit) {
        _notice = '已有操作记录，请先查询任务进展。';
        return;
      }
      final expected = ExecutionOperationPending(intent: intent);
      if (reservation.record != expected) {
        _storageFailure(
            const ApiFailure(409, 'INVALID_EXECUTION_OPERATION_RECORD'));
        return;
      }
      // The stored UNKNOWN now blocks ordinary action eligibility; revalidate the
      // immutable confirmation without treating our own slot as foreign work.
      if (!_dispatchAllowed(epoch, active, token)) {
        active._retired = true;
        final removed = await _releaseNeverDispatched(active, reservation);
        if (_current(epoch)) {
          if (removed) {
            _pending = null;
          } else if (!_storageBlocked) {
            await _reloadLocal(epoch);
          }
        }
        return;
      }
      active._mayHaveDispatched =
          true; // Irreversible, immediately before call.
      final response = await requests.submit(reservation.record);
      if (!_current(epoch)) {
        return; // Detached late success is deliberately ignored.
      }
      try {
        final removed = await journal.removeAfterVerifiedReceipt(
            reservation.record, response);
        if (!_current(epoch)) return;
        if (removed) {
          _pending = null;
        } else {
          await _reloadLocal(epoch);
        }
      } catch (failure) {
        if (_current(epoch)) _storageFailure(failure);
        return;
      }
      if (!_current(epoch)) return;
      _task = response;
      _eligibility = null;
      _detailVerified = true;
      _notice = kind == ExecutionOperationKind.recheckDevice
          ? '已申请重新核实，等待设备反馈。'
          : '已登记取消，请核对设备现状。';
      onProgress(response);
    } on ExecutionOperationDenied catch (proof) {
      if (attempt == null ||
          !attempt._mayHaveDispatched ||
          proof.record != ExecutionOperationPending(intent: attempt.intent)) {
        if (_current(epoch)) {
          _failure(const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE'));
        }
        return;
      }
      // The repository formed this exact physical refusal while its scope was
      // valid. Detach after that fact does not erase the original slot's proof.
      // UI changes are current-epoch only; CAS never gains new-owner authority.
      if (_current(epoch)) {
        final hidden = _privateFailure(proof.failure);
        if (!hidden) {
          _error = proof.failure;
        }
      }
      try {
        final rejected = await journal.markRejected(proof);
        if (_current(epoch)) {
          _pending = rejected;
          _notice = '本次操作未被受理，请读取最新状态后重新确认。';
        }
      } catch (failure) {
        if (_current(epoch)) _storageFailure(failure);
      }
    } catch (failure) {
      if (_current(epoch)) _failure(failure);
    } finally {
      attempt?._retired = true;
      if (identical(_attempt, attempt)) _attempt = null;
      if (_current(epoch)) {
        _confirmation = null;
        _busy = false;
        _changed();
      }
    }
  }

  bool _dispatchAllowed(
      int epoch, _ReviewAttempt attempt, _ReviewConfirmation token) {
    final task = _task;
    if (!_current(epoch) ||
        attempt._retired ||
        attempt._mayHaveDispatched ||
        token.epoch != epoch ||
        task == null ||
        !_sameTask(task, token.task) ||
        !requests.writable ||
        _needsReauth ||
        !_restored ||
        _storageBlocked ||
        task.cancellationRequested ||
        task.revision >= managedExecutionMaxRevision ||
        _eventsAhead(task)) return false;
    if (token.kind == ExecutionOperationKind.cancel) {
      return !const {'APPLIED', 'CANCELLED'}.contains(task.state);
    }
    final eligibility = _eligibility;
    return task.state == 'NEEDS_REVIEW' &&
        eligibility != null &&
        eligibility.allowed &&
        eligibility.revision == task.revision &&
        eligibility.id == task.id &&
        eligibility.publicationId == task.publicationId &&
        eligibility.deviceId == task.deviceId &&
        eligibility.registrationId == task.registrationId;
  }

  Future<bool> _releaseNeverDispatched(
      _ReviewAttempt attempt, ExecutionOperationReservation reservation) async {
    if (!attempt._retired ||
        attempt._mayHaveDispatched ||
        !reservation.maySubmit ||
        reservation.record != ExecutionOperationPending(intent: attempt.intent)) {
      return false;
    }
    try {
      return await journal
          .removeAfterControllerProvedNeverDispatched(reservation.record);
    } catch (failure) {
      if (_guard()) _storageFailure(failure);
      return false;
    }
  }
}

/// Only this library can own/retire the confirmation and irreversible dispatch
/// latch. A fresh attempt never resets or repurposes an older attempt's latch.
final class _ReviewAttempt {
  final ExecutionOperationIntent intent;
  bool _mayHaveDispatched = false;
  bool _retired = false;
  _ReviewAttempt(this.intent);
}

final class _ReviewConfirmation {
  final int epoch;
  final ManagedExecution task;
  final ExecutionOperationKind kind;
  final ExecutionOperationPending? rejected;
  _ReviewConfirmation(this.epoch, this.task, this.kind, this.rejected);
}
