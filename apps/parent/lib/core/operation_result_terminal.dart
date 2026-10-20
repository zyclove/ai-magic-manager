import 'package:flutter/foundation.dart';

import 'operation_journal.dart';
import 'parent_api.dart';

class ParentResultTerminal {
  final String reason;
  final bool knownSuccessful;
  const ParentResultTerminal(this.reason, this.knownSuccessful);
  bool get erased => reason == 'ERASED';
  String get title => erased ? '原结果已清理' : '原结果已过保留期';
  String get explanation => erased
      ? '原操作结果已按数据处理流程清理，无法恢复。'
      : '服务端确认原操作结果已超过 90 天保留期，无法恢复。';
}

/// Terminal evidence is permanent for this controller, even if persisting it
/// fails. Neither an old callback nor a generic 410 can authorize a replay.
mixin ParentTerminalOperation on ChangeNotifier {
  ParentOperationJournal get operationJournal;
  String get operationSlot;
  Json? get operationPayload;
  String? get operationRequestId => operationPayload?['requestId'] as String?;
  bool get operationCurrent;
  bool get operationHasSuccessfulResult;
  bool get busy;
  set busy(bool value);
  Object? get error;
  set error(Object? value);
  Future<void> load();
  void forgetOperationPayload();
  ParentResultTerminal? _observedTerminal;
  String? _observedRequestId, _successfulRequestId;
  Object? terminalStorageError;
  bool _knownSuccessful = false;

  ParentResultTerminal? get resultTerminal {
    if (_observedTerminal != null &&
        operationRequestId == _observedRequestId) return _observedTerminal;
    final row = operationJournal.snapshot(operationSlot);
    final reason = row?['terminal'];
    return reason is String
        ? ParentResultTerminal(reason, row?['knownSuccessful'] == true) : null;
  }

  bool get operationBlocked => resultTerminal != null ||
      operationJournal.changed(operationSlot);

  bool get operationKnownSuccessful {
    final row = operationJournal.snapshot(operationSlot);
    return row?['knownSuccessful'] == true || (operationPayload != null &&
        _knownSuccessful && _successfulRequestId == row?['requestId']);
  }

  Future<bool> operationBeforeWrite() async {
    if (operationKnownSuccessful) return false;
    return operationBeforeDispatch();
  }

  Future<bool> operationBeforeDispatch() async {
    if (!operationCurrent || operationBlocked) return false;
    await operationJournal.assertCurrent(operationSlot, operationPayload);
    return operationCurrent && !operationBlocked;
  }

  Future<void> recordSuccessfulOperation() async {
    if (!operationCurrent || operationPayload == null) return;
    _knownSuccessful = true;
    _successfulRequestId = operationJournal.snapshot(operationSlot)?['requestId'] as String?;
    await operationJournal.confirmed(operationSlot);
  }

  Future<void> captureResultTerminal(Object failure) async {
    final payload = operationPayload;
    if (!operationCurrent || payload == null ||
        failure is! ParentResultTerminalFailure ||
        !failure.matchesRequest(operationRequestId)) return;
    final existing = resultTerminal;
    final reason = existing?.erased == true ||
        failure.code == 'IDEMPOTENCY_RESPONSE_ERASED' ? 'ERASED' : 'EXPIRED';
    final known = (_knownSuccessful && _successfulRequestId == operationRequestId) ||
        existing?.knownSuccessful == true ||
        operationJournal.snapshot(operationSlot)?['knownSuccessful'] == true;
    _observedTerminal = ParentResultTerminal(reason, known);
    _observedRequestId = operationRequestId;
    try {
      await operationJournal.terminal(operationSlot, operationRequestId!, reason,
          knownSuccessful: known);
      final persisted = operationJournal.snapshot(operationSlot)!;
      _observedTerminal = ParentResultTerminal(persisted['terminal'] as String,
          persisted['knownSuccessful'] == true);
      terminalStorageError = null;
    } catch (failure) {
      terminalStorageError = failure;
    }
  }

  /// The caller must first obtain an explicit one-time user confirmation.
  /// This only closes the local check. It never creates or retries a business request.
  Future<bool> endLocalCheck() async {
    if (!operationCurrent || busy || resultTerminal == null ||
        operationPayload == null) return false;
    busy = true;
    error = null;
    notifyListeners();
    var ended = false;
    try {
      final terminal = resultTerminal!;
      await operationJournal.terminal(operationSlot,
          operationRequestId!, terminal.reason,
          knownSuccessful: terminal.knownSuccessful);
      if (!operationCurrent) return false;
      await operationJournal.finishTerminal(operationSlot);
      if (!operationCurrent) return false;
      forgetOperationPayload();
      _observedTerminal = null;
      _observedRequestId = null;
      _successfulRequestId = null;
      _knownSuccessful = false;
      terminalStorageError = null;
      ended = true;
    } catch (failure) {
      if (operationCurrent) {
        terminalStorageError = failure;
        error = failure;
      }
    } finally {
      busy = false;
      if (operationCurrent) notifyListeners();
    }
    if (ended && operationCurrent) await load();
    return ended;
  }
}
