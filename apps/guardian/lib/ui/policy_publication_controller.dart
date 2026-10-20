import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/policy_publication.dart';
import '../core/policy_publication_repository.dart';
import '../core/publication_journal.dart';

enum PublicationViewPhase {
  fresh,
  confirming,
  submitting,
  unknown,
  querying,
  reauthenticationRequired,
  retryableNotSubmitted,
  queryReauthenticationRequired,
  recorded,
  cleanupPending,
  storageBlocked,
  loadingLocal,
  cancelling,
  previewInvalid,
  resultExpired,
  resultErased,
  clearingTerminal,
  terminalAcknowledged,
  revoked,
}

/// One explicitly operated CONFIGURE_ONLY journey in a fixed authority scope.
/// Local restoration never queries the network and UNKNOWN never permits POST.
class PolicyPublicationController extends ChangeNotifier {
  final PublicationRequests repository;
  final PublicationJournal journal;
  final bool Function() current;
  final Listenable? accessChanges;
  final DateTime Function() clock;
  final Future<void> Function()? preflight;
  final PublicationOwner _owner;
  final String _policyId;
  late final PublicationRequests _requests =
      repository.scoped(_requestCurrent, onDenied: _onDenied);

  PublicationIntent? _intent;
  PublicationPending? _pending;
  PublicationReceipt? _receipt;
  Object? _error;
  PublicationPending? _terminalOriginal;
  bool _terminalDurable = false;
  late PublicationViewPhase _phase;
  bool _active = true, _disposed = false;
  int _generation = 0, _actionEpoch = 0;
  Timer? _expiryTimer;

  PolicyPublicationController({
    required this.repository,
    required this.journal,
    required PublicationIntent intent,
    PublicationPending? pending,
    required this.current,
    this.accessChanges,
    DateTime Function()? clock,
    this.preflight,
  })  : clock = clock ?? DateTime.now,
        _owner = intent.owner,
        _policyId = intent.policyId,
        _intent = intent,
        _pending = pending {
    if (pending != null && pending.intent != intent) {
      throw const ApiFailure(400, 'INVALID_POLICY_PUBLICATION_INTENT');
    }
    _phase =
        pending == null ? PublicationViewPhase.fresh : _restoredPhase(pending);
    _terminalDurable = pending?.phase.terminal == true;
    accessChanges?.addListener(_accessChanged);
    _accessCurrent();
    _scheduleExpiry();
  }

  PublicationIntent get intent => _intent ??
      (throw const ApiFailure(409, 'PUBLICATION_RESULT_TERMINAL'));
  PublicationPending? get pending => hasAccess ? _pending : null;
  PublicationReceipt? get receipt => hasAccess ? _receipt : null;
  Object? get error => _error;
  int get actionEpoch => _actionEpoch;

  PublicationViewPhase get phase {
    _accessCurrent();
    return _phase;
  }

  bool get hasAccess => _accessCurrent();
  bool get previewFresh =>
      (_intent?.previewExpiresAt ?? 0) > clock().millisecondsSinceEpoch;
  PublicationTerminalReason? get terminalReason => !hasAccess ? null :
      switch (_pending?.phase) {
        PublicationPhase.resultExpired => PublicationTerminalReason.expired,
        PublicationPhase.resultErased => PublicationTerminalReason.erased,
        _ => null,
      };
  bool get confirmedSuccess => hasAccess &&
      (_receipt != null || _pending?.confirmedSuccess == true);
  bool get canReviewTerminal => hasAccess && !busy && terminalReason != null;
  bool get canAcknowledgeTerminal => canReviewTerminal;
  bool get busy =>
      hasAccess &&
      const {
        PublicationViewPhase.submitting,
        PublicationViewPhase.querying,
        PublicationViewPhase.loadingLocal,
        PublicationViewPhase.cancelling,
        PublicationViewPhase.clearingTerminal,
      }.contains(_phase);

  bool get canConfirm =>
      hasAccess &&
      !busy &&
      terminalReason == null &&
      _phase != PublicationViewPhase.terminalAcknowledged &&
      previewFresh &&
      const {
        PublicationViewPhase.fresh,
        PublicationViewPhase.retryableNotSubmitted,
      }.contains(_phase);

  bool get canSubmit =>
      hasAccess &&
      !busy &&
      previewFresh &&
      _phase == PublicationViewPhase.confirming;

  bool get canCheck =>
      hasAccess &&
      !busy &&
      _pending != null &&
      const {
        PublicationViewPhase.unknown,
        PublicationViewPhase.cleanupPending,
      }.contains(_phase);

  bool get needsReauth =>
      hasAccess &&
      const {
        PublicationViewPhase.reauthenticationRequired,
        PublicationViewPhase.queryReauthenticationRequired,
      }.contains(_phase);

  bool get canReloadPending =>
      hasAccess && !busy && _phase == PublicationViewPhase.storageBlocked;

  bool get canCancelNotSubmitted =>
      hasAccess &&
      !busy &&
      _pending?.phase == PublicationPhase.reauthenticationRequired &&
      _receipt == null;

  bool get canRepreview =>
      hasAccess &&
      !busy &&
      terminalReason == null &&
      _phase != PublicationViewPhase.terminalAcknowledged &&
      (_phase == PublicationViewPhase.previewInvalid || !previewFresh) &&
      (_pending == null || canCancelNotSubmitted);

  PublicationViewPhase _restoredPhase(PublicationPending value) =>
      switch (value.phase) {
        PublicationPhase.reauthenticationRequired =>
          PublicationViewPhase.retryableNotSubmitted,
        PublicationPhase.resultExpired => PublicationViewPhase.resultExpired,
        PublicationPhase.resultErased => PublicationViewPhase.resultErased,
        PublicationPhase.unknown => PublicationViewPhase.unknown,
      };

  bool _accessCurrent() {
    if (_disposed || !_active) return false;
    if (!current() || !repository.isCurrent) {
      _revoke();
      return false;
    }
    return true;
  }

  // The repository retains this guard through authenticated-client acquisition,
  // OAuth refresh, physical transport and private response body consumption.
  bool _requestCurrent() => _accessCurrent();

  void _accessChanged() => _accessCurrent();

  void _onDenied(ApiFailure failure) {
    if (_hardDenial(failure)) _revoke();
  }

  bool _hardDenial(ApiFailure failure) =>
      failure.status == 403 ||
      (failure.status == 401 && failure.code != 'REAUTH_REQUIRED') ||
      failure.code == 'WORKSPACE_CHANGED';

  void _revoke() {
    if (_disposed || !_active) return;
    _active = false;
    _generation++;
    _actionEpoch++;
    _phase = PublicationViewPhase.revoked;
    _pending = null;
    _receipt = null;
    _terminalOriginal = null;
    _error = const ApiFailure(409, 'WORKSPACE_CHANGED');
    _expiryTimer?.cancel();
    _expiryTimer = null;
    accessChanges?.removeListener(_accessChanged);
    notifyListeners();
  }

  void invalidate() => _revoke();

  bool beginConfirmation() {
    if (!hasAccess ||
        busy ||
        !const {
          PublicationViewPhase.fresh,
          PublicationViewPhase.retryableNotSubmitted,
        }.contains(_phase)) return false;
    if (!previewFresh) {
      _previewInvalid(const ApiFailure(409, 'PREVIEW_EXPIRED'));
      return false;
    }
    _error = null;
    _phase = PublicationViewPhase.confirming;
    _emit();
    return true;
  }

  void cancelConfirmation() {
    if (!hasAccess || busy || _phase != PublicationViewPhase.confirming) return;
    _error = null;
    _phase = _pending == null
        ? PublicationViewPhase.fresh
        : _restoredPhase(_pending!);
    _emit();
  }

  void _requireFresh() {
    if (!previewFresh) throw const ApiFailure(409, 'PREVIEW_EXPIRED');
  }

  void _requireCurrent(int generation) {
    if (!_canComplete(generation)) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
  }

  bool _canComplete(int generation) =>
      !_disposed && generation == _generation && _requestCurrent();

  int _start(PublicationViewPhase phase) {
    final generation = ++_generation;
    _phase = phase;
    _error = null;
    _emit();
    return generation;
  }

  void _adopt(PublicationPending record) {
    if (record.intent.owner != _owner || record.intent.policyId != _policyId) {
      throw const ApiFailure(409, 'INVALID_POLICY_PUBLICATION_RECORD');
    }
    _intent = record.intent;
    _pending = record;
    _terminalDurable = record.phase.terminal;
    if (_terminalDurable) _terminalOriginal = null;
  }

  Future<void> submit() async {
    if (!hasAccess || busy || _phase != PublicationViewPhase.confirming) return;
    final before = _pending;
    final originalIntent = intent;
    final generation = _start(PublicationViewPhase.submitting);
    var reserving = false, publicationInvoked = false;
    try {
      _requireFresh();
      await preflight?.call();
      _requireCurrent(generation);
      _requireFresh();
      reserving = true;
      final reservation = before == null
          ? await journal.reserve(originalIntent)
          : await journal.claimRetry(before);
      _requireCurrent(generation);
      _adopt(reservation.record);
      if (!reservation.maySubmit) {
        _phase = _restoredPhase(reservation.record);
        _emit();
        return;
      }
      if (reservation.record.intent != originalIntent ||
          reservation.record.phase != PublicationPhase.unknown ||
          (before != null &&
              reservation.record.attempt != before.attempt + 1)) {
        throw const ApiFailure(409, 'INVALID_POLICY_PUBLICATION_RECORD');
      }
      // A committed UNKNOWN marker is kept if the original preview expires in
      // this small write-ahead/dispatch gap. It must never be silently erased.
      _requireFresh();
      _requireCurrent(generation);
      reserving = false;
      publicationInvoked = true;
      final receipt = await _requests.publish(reservation.record);
      if (_canComplete(generation)) {
        await _acceptReceipt(generation, reservation.record, receipt);
      }
    } on PublicationResultTerminal catch (failure) {
      if (_canComplete(generation)) {
        if (!publicationInvoked || failure.record != _pending) {
          _requestFailed(const ApiFailure(502, 'INVALID_POLICY_PUBLICATION_RESPONSE'));
        } else {
          await _acceptTerminal(generation, failure);
        }
      }
    } on PublicationReauthenticationRequired catch (failure) {
      if (_canComplete(generation)) {
        final attempt = _pending;
        if (!publicationInvoked ||
            attempt == null ||
            failure.record != attempt ||
            attempt.phase != PublicationPhase.unknown) {
          _requestFailed(failure);
        } else {
          try {
            final retryable =
                await journal.markReauthenticationRequired(attempt);
            if (_canComplete(generation)) {
              if (retryable.intent != attempt.intent ||
                  retryable.attempt != attempt.attempt ||
                  retryable.phase !=
                      PublicationPhase.reauthenticationRequired) {
                throw const ApiFailure(
                    409, 'INVALID_POLICY_PUBLICATION_RECORD');
              }
              _adopt(retryable);
              _phase = PublicationViewPhase.reauthenticationRequired;
              _error = const ApiFailure(401, 'REAUTH_REQUIRED');
              _emit();
            }
          } catch (storageFailure) {
            if (_canComplete(generation)) {
              _phase = PublicationViewPhase.storageBlocked;
              _error = storageFailure;
              _emit();
            }
          }
        }
      }
    } catch (failure) {
      if (_canComplete(generation)) {
        if (failure is ApiFailure && _hardDenial(failure)) {
          _revoke();
        } else if (!reserving && !publicationInvoked) {
          if (failure is ApiFailure &&
              failure.status == 401 &&
              failure.code == 'REAUTH_REQUIRED') {
            _phase = PublicationViewPhase.reauthenticationRequired;
            _error = failure;
            _emit();
          } else if (failure is ApiFailure &&
              const {'PREVIEW_EXPIRED', 'POLICY_GROUP_CHANGED'}
                  .contains(failure.code)) {
            _previewInvalid(failure);
          } else {
            _phase = before == null
                ? PublicationViewPhase.fresh
                : _restoredPhase(before);
            _error = failure;
            _emit();
          }
        } else if (reserving && _pending == before) {
          _phase = PublicationViewPhase.storageBlocked;
          _error = failure;
          _emit();
        } else if (_pending != null) {
          _requestFailed(failure);
        } else {
          _phase = PublicationViewPhase.storageBlocked;
          _error = failure;
          _emit();
        }
      }
    }
  }

  void _requestFailed(Object failure) {
    if (failure is ApiFailure && _hardDenial(failure)) {
      _revoke();
      return;
    }
    _error = failure;
    _phase = failure is ApiFailure &&
            failure.status == 401 &&
            failure.code == 'REAUTH_REQUIRED'
        ? PublicationViewPhase.queryReauthenticationRequired
        : _receipt != null
            ? PublicationViewPhase.cleanupPending
            : PublicationViewPhase.unknown;
    _emit();
  }

  Future<void> check() async {
    if (!canCheck) return;
    final original = _pending!;
    final generation = _start(PublicationViewPhase.querying);
    try {
      final receipt = await _requests.lookup(original);
      if (!_canComplete(generation)) return;
      if (receipt == null) {
        _requestFailed(
            const ApiFailure(404, 'POLICY_PUBLICATION_RESULT_UNAVAILABLE'));
      } else {
        await _acceptReceipt(generation, original, receipt);
      }
    } on PublicationResultTerminal catch (failure) {
      if (_canComplete(generation)) {
        if (failure.record != original) {
          _requestFailed(const ApiFailure(502, 'INVALID_POLICY_PUBLICATION_RESPONSE'));
        } else {
          await _acceptTerminal(generation, failure);
        }
      }
    } catch (failure) {
      if (_canComplete(generation)) _requestFailed(failure);
    }
  }

  Future<void> _acceptTerminal(int generation,
      PublicationResultTerminal failure) async {
    _requireCurrent(generation);
    final original = failure.record;
    _terminalOriginal = original;
    _terminalDurable = false;
    _pending = PublicationPending(intent: original.intent,
        phase: failure.reason.phase, attempt: original.attempt,
        confirmedSuccess: _receipt != null || original.confirmedSuccess);
    _phase = PublicationViewPhase.clearingTerminal;
    _emit();
    try {
      await _persistTerminal(generation);
      if (!_canComplete(generation)) return;
      _error = null;
    } catch (failure) {
      if (!_canComplete(generation)) return;
      _error = failure;
    }
    _phase = _restoredPhase(_pending!);
    _emit();
  }

  Future<void> _persistTerminal(int generation) async {
    if (_terminalDurable) return;
    final original = _terminalOriginal, terminal = _pending;
    if (original == null || terminal == null || !terminal.phase.terminal) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
    }
    final persisted = await journal.markResultTerminalIfSame(original,
        terminal.phase == PublicationPhase.resultExpired
            ? PublicationTerminalReason.expired : PublicationTerminalReason.erased,
        confirmedSuccess: terminal.confirmedSuccess,
        isCurrent: () => _canComplete(generation));
    _requireCurrent(generation);
    if (persisted.intent != terminal.intent ||
        !(persisted.phase == terminal.phase ||
          (terminal.phase == PublicationPhase.resultExpired &&
           persisted.phase == PublicationPhase.resultErased)) ||
        persisted.attempt != terminal.attempt ||
        (terminal.confirmedSuccess && !persisted.confirmedSuccess)) {
      throw const ApiFailure(409, 'INVALID_POLICY_PUBLICATION_RECORD');
    }
    _adopt(persisted);
    _terminalDurable = true;
    _terminalOriginal = null;
  }

  /// User-confirmed local cleanup; never calls the network or creates a key.
  Future<bool> acknowledgeTerminal() async {
    if (!canAcknowledgeTerminal) return false;
    final expectedBefore = _pending!;
    final generation = _start(PublicationViewPhase.clearingTerminal);
    try {
      await _persistTerminal(generation);
      _requireCurrent(generation);
      final original = _pending!;
      final marker = await journal.acknowledgeTerminalIfSame(original,
          acknowledgedAt: clock().millisecondsSinceEpoch,
          isCurrent: () => _canComplete(generation));
      if (!_canComplete(generation)) return false;
      if (marker.ownerKey != _owner.key || marker.policyId != _policyId ||
          marker.requestDigest != publicationRequestDigest(original.intent) ||
          marker.reason.phase != original.phase ||
          (original.confirmedSuccess && !marker.confirmedSuccess)) {
        throw const ApiFailure(409, 'INVALID_POLICY_PUBLICATION_RECORD');
      }
      _pending = null;
      _intent = null;
      _receipt = null;
      _terminalOriginal = null;
      _error = null;
      _phase = PublicationViewPhase.terminalAcknowledged;
      _emit();
      return true;
    } catch (failure) {
      if (_canComplete(generation)) {
        if (failure is ApiFailure && failure.code == 'PUBLICATION_PENDING_CHANGED') {
          try {
            final current = await journal.read(_owner, _policyId);
            if (!_canComplete(generation)) return false;
            if (current != null) {
              if (current.intent != expectedBefore.intent) _receipt = null;
              _adopt(current);
            } else {
              // Another tab may already have acknowledged this original. The
              // next explicit local attempt must verify its minimal marker.
              _terminalDurable = false;
              _terminalOriginal = expectedBefore;
            }
          } catch (_) {
            if (!_canComplete(generation)) return false;
          }
        }
        _phase = _restoredPhase(_pending!);
        _error = failure;
        _emit();
      }
      return false;
    }
  }

  Future<void> _acceptReceipt(int generation, PublicationPending original,
      PublicationReceipt receipt) async {
    _requireCurrent(generation);
    _receipt = receipt;
    try {
      final removed = await journal.removeIfSame(original);
      if (!_canComplete(generation)) return;
      if (removed) {
        _pending = null;
        _phase = PublicationViewPhase.recorded;
        _error = null;
      } else {
        _phase = PublicationViewPhase.cleanupPending;
        _error = const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
      }
    } catch (failure) {
      if (!_canComplete(generation)) return;
      _phase = PublicationViewPhase.cleanupPending;
      _error = failure;
    }
    _emit();
  }

  Future<void> reloadPending() async {
    if (!canReloadPending) return;
    final generation = _start(PublicationViewPhase.loadingLocal);
    try {
      final record = await journal.read(_owner, _policyId);
      if (!_canComplete(generation)) return;
      _receipt = null;
      _pending = null;
      _terminalOriginal = null;
      _terminalDurable = record?.phase.terminal == true;
      if (record == null) {
        _phase = previewFresh
            ? PublicationViewPhase.fresh
            : PublicationViewPhase.previewInvalid;
      } else {
        _adopt(record);
        _phase = _restoredPhase(record);
      }
      _error = null;
      _emit();
    } catch (failure) {
      if (!_canComplete(generation)) return;
      _phase = PublicationViewPhase.storageBlocked;
      _error = failure;
      _emit();
    }
  }

  Future<bool> cancelNotSubmitted() async {
    if (!canCancelNotSubmitted) return false;
    final original = _pending!;
    final generation = _start(PublicationViewPhase.cancelling);
    try {
      final removed = await journal.cancelNotSubmitted(original);
      if (!_canComplete(generation)) return false;
      if (!removed) {
        _phase = PublicationViewPhase.storageBlocked;
        _error = const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
        _emit();
        return false;
      }
      _pending = null;
      _receipt = null;
      _phase = PublicationViewPhase.previewInvalid;
      _error = null;
      _emit();
      return true;
    } catch (failure) {
      if (_canComplete(generation)) {
        _phase = PublicationViewPhase.storageBlocked;
        _error = failure;
        _emit();
      }
      return false;
    }
  }

  void _previewInvalid(Object failure) {
    _phase = PublicationViewPhase.previewInvalid;
    _error = failure;
    _emit();
  }

  void _emit() {
    if (_disposed) return;
    _actionEpoch++;
    _scheduleExpiry();
    notifyListeners();
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_disposed ||
        !_active ||
        !const {
          PublicationViewPhase.fresh,
          PublicationViewPhase.confirming,
          PublicationViewPhase.retryableNotSubmitted,
        }.contains(_phase)) return;
    final remaining = intent.previewExpiresAt - clock().millisecondsSinceEpoch;
    if (remaining <= 0) {
      _phase = PublicationViewPhase.previewInvalid;
      _error = const ApiFailure(409, 'PREVIEW_EXPIRED');
      return;
    }
    _expiryTimer = Timer(
        Duration(
            milliseconds:
                remaining.clamp(1, Duration.millisecondsPerDay).toInt()), () {
      _expiryTimer = null;
      if (!_accessCurrent()) return;
      if (!previewFresh) {
        _previewInvalid(const ApiFailure(409, 'PREVIEW_EXPIRED'));
      } else {
        _scheduleExpiry();
      }
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _active = false;
    _generation++;
    _actionEpoch++;
    _phase = PublicationViewPhase.revoked;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    accessChanges?.removeListener(_accessChanged);
    _pending = null;
    _receipt = null;
    _terminalOriginal = null;
    _intent = null;
    _error = null;
    super.dispose();
  }
}
