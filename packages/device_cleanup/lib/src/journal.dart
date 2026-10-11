import 'dart:convert';
import 'package:device_identity/device_identity.dart'
    show validUuid, safeInteger;
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'receipt.dart';
import 'verifier.dart';

/// The host must provide one atomic, durable, encrypted record per original
/// registration. A plaintext preference store or silent reset is not safe.
abstract interface class CleanupRecordStore {
  Future<String?> read();
  Future<void> write(String record);
}

class CleanupJournalView {
  final bool receivedAcknowledged,
      failureAcknowledged,
      localDataCleared,
      cleanupAcknowledged;
  final CleanupReceipt? pending;
  const CleanupJournalView(this.receivedAcknowledged, this.failureAcknowledged,
      this.localDataCleared, this.cleanupAcknowledged, this.pending);
}

/// One owner per registration. A new command cannot silently replace a
/// previous pending receipt, and restoration requires a freshly verified
/// command with the same original scope and hash.
class CleanupReceiptJournal {
  final CleanupScope scope;
  final CleanupRecordStore store;
  final int Function() nowMillis;
  _Record? _record;
  bool _busy = false;
  CleanupReceiptJournal(
      {required this.scope, required this.store, required this.nowMillis});

  /// Recovery after the server accepted a cleared receipt but the app died
  /// before original-key removal. The command may already be expired, so it
  /// cannot be refetched. Trust only the authenticated app-private journal
  /// bound to the independently persisted cleanupPending identity state.
  /// This never authorizes a new clear or receipt, only final key deletion.
  static Future<bool> finalKeyRemovalReady(
      {required CleanupScope scope,
      required String commandHash,
      required CleanupRecordStore store}) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(commandHash)) {
      throw const CleanupFailure('CLEANUP_JOURNAL_INVALID');
    }
    String? raw;
    try {
      raw = await store.read();
    } catch (_) {
      throw const CleanupFailure('CLEANUP_JOURNAL_UNAVAILABLE');
    }
    if (raw == null) return false;
    try {
      if (utf8.encode(raw).length > 4096) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value.length != 15 ||
          !const {
            'schemaVersion',
            'tenantId',
            'deviceId',
            'registrationId',
            'keyThumbprint',
            'operationId',
            'commandId',
            'commandHash',
            'issuedAt',
            'notAfter',
            'accepted',
            'localDataCleared',
            'pendingId',
            'pendingStage',
            'pendingReason'
          }.containsAll(value.keys) ||
          value['schemaVersion'] != 1 ||
          value['tenantId'] != scope.tenantId ||
          value['deviceId'] != scope.deviceId ||
          value['registrationId'] != scope.registrationId ||
          value['keyThumbprint'] != scope.keyThumbprint ||
          value['commandHash'] != commandHash ||
          !validUuid(value['operationId']) ||
          !validUuid(value['commandId']) ||
          !safeInteger(value['issuedAt'], minimum: 1) ||
          !safeInteger(value['notAfter'], minimum: 1) ||
          value['notAfter'] <= value['issuedAt'] ||
          value['notAfter'] - value['issuedAt'] > 7 * 86400000 ||
          value['localDataCleared'] is! bool ||
          value['accepted'] != null &&
              !const {'RECEIVED', 'FAILED', 'AGENT_DATA_CLEARED'}
                  .contains(value['accepted']) ||
          value['pendingId'] != null && !validUuid(value['pendingId']) ||
          value['pendingStage'] != null &&
              !const {'RECEIVED', 'FAILED', 'AGENT_DATA_CLEARED'}
                  .contains(value['pendingStage']) ||
          (value['pendingId'] == null) != (value['pendingStage'] == null) ||
          value['pendingReason'] != null &&
              !const {
                'STORAGE_FAILURE',
                'KEY_UNAVAILABLE',
                'UNSUPPORTED_AGENT',
                'USER_ACTION_REQUIRED'
              }.contains(value['pendingReason'])) {
        throw const FormatException();
      }
      return value['accepted'] == 'AGENT_DATA_CLEARED' &&
          value['localDataCleared'] == true &&
          value['pendingId'] == null &&
          value['pendingStage'] == null &&
          value['pendingReason'] == null;
    } catch (_) {
      throw const CleanupFailure('CLEANUP_JOURNAL_INVALID');
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() work) async {
    if (_busy) throw const CleanupFailure('CLEANUP_JOURNAL_BUSY');
    _busy = true;
    try {
      return await work();
    } finally {
      _busy = false;
    }
  }

  Future<CleanupJournalView> load(VerifiedCleanupCommand command) =>
      _exclusive(() async {
        _checkCommand(command);
        _record = null;
        String? raw;
        try {
          raw = await store.read();
        } catch (_) {
          throw const CleanupFailure('CLEANUP_JOURNAL_UNAVAILABLE');
        }
        if (raw == null) {
          _record = _Record(command);
          await _save();
        } else {
          try {
            if (utf8.encode(raw).length > 4096) throw const FormatException();
            final decoded = jsonDecode(raw);
            if (decoded is! Map<String, dynamic>) {
              throw const FormatException();
            }
            _record = _Record.restore(command, decoded);
          } on CleanupFailure {
            rethrow;
          } catch (_) {
            throw const CleanupFailure('CLEANUP_JOURNAL_INVALID');
          }
        }
        return _view();
      });

  CleanupJournalView get view => _view();
  CleanupJournalView _view() {
    final record = _require();
    return CleanupJournalView(
        record.accepted != null,
        record.accepted == 'FAILED',
        record.localDataCleared,
        record.accepted == 'AGENT_DATA_CLEARED',
        record.pendingReceipt());
  }

  /// The stable ID/body is durably written before this returns. If a previous
  /// send has unknown outcome, this returns its original receipt unchanged.
  Future<CleanupReceipt> prepare(CleanupReceiptStage stage,
          {String? reasonCode}) =>
      _exclusive(() async {
        final record = _require();
        final existing = record.pendingReceipt();
        if (existing != null) {
          if (existing.stage != stage || existing.reasonCode != reasonCode) {
            throw const CleanupFailure('CLEANUP_RECEIPT_PENDING');
          }
          return existing;
        }
        _requireActive(record.command);
        if (stage == CleanupReceiptStage.received && record.accepted != null ||
            stage == CleanupReceiptStage.agentDataCleared &&
                (!record.localDataCleared ||
                    record.accepted != 'RECEIVED' &&
                        record.accepted != 'FAILED') ||
            stage == CleanupReceiptStage.failed &&
                (record.accepted != 'RECEIVED' || record.localDataCleared)) {
          throw const CleanupFailure('CLEANUP_STAGE_INVALID');
        }
        // The ID is stable even if the encrypted record is unexpectedly lost.
        // A changed FAILED reason then conflicts on the server instead of
        // silently creating a second receipt for the same command/stage.
        final stageName = switch (stage) {
          CleanupReceiptStage.received => 'RECEIVED',
          CleanupReceiptStage.agentDataCleared => 'AGENT_DATA_CLEARED',
          CleanupReceiptStage.failed => 'FAILED'
        };
        final receiptId = const Uuid().v5(
            '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
            'aimanager-cleanup-v1/${record.command.operationId}/'
                '${record.command.commandHash}/$stageName');
        final receipt = CleanupReceipt(record.command, receiptId, stage,
            reasonCode: reasonCode);
        record.pendingId = receipt.receiptId;
        record.pendingStage = receipt.wireStage;
        record.pendingReason = reasonCode;
        await _save();
        return receipt;
      });

  /// Invoke only after an idempotent cleaner has actually removed this app's
  /// own caches and ordinary bearer. Do not remove the original signing key.
  Future<void> markLocalDataCleared() => _exclusive(() async {
        final record = _require();
        _requireActive(record.command);
        if (record.pendingId != null ||
            record.accepted != 'RECEIVED' && record.accepted != 'FAILED') {
          throw const CleanupFailure('CLEANUP_STAGE_INVALID');
        }
        if (record.localDataCleared) return;
        record.localDataCleared = true;
        await _save();
      });

  /// A strict 200 acknowledgement is saved before the caller can advance to
  /// local clear or final key removal. A stale or different receipt is ignored.
  Future<CleanupJournalView> acknowledge(
          CleanupReceipt receipt, CleanupReceiptAck ack) =>
      _exclusive(() async {
        final record = _require();
        if (record.pendingId != receipt.receiptId ||
            record.pendingStage != receipt.wireStage ||
            record.pendingReason != receipt.reasonCode ||
            receipt.command.commandHash != record.command.commandHash ||
            ack.operationId != record.command.operationId ||
            ack.receiptId != receipt.receiptId) {
          throw const CleanupFailure('CLEANUP_ACK_INVALID');
        }
        record.accepted = receipt.wireStage;
        record.pendingId = null;
        record.pendingStage = null;
        record.pendingReason = null;
        await _save();
        return _view();
      });

  void _checkCommand(VerifiedCleanupCommand command) {
    if (command.scope.tenantId != scope.tenantId ||
        command.scope.deviceId != scope.deviceId ||
        command.scope.registrationId != scope.registrationId ||
        command.scope.keyThumbprint != scope.keyThumbprint) {
      throw const CleanupFailure('CLEANUP_IDENTITY_CHANGED');
    }
  }

  void _requireActive(VerifiedCleanupCommand command) {
    final now = nowMillis();
    if (!safeInteger(now, minimum: 1)) {
      throw const CleanupFailure('CLOCK_UNTRUSTED');
    }
    if (now + 300000 < command.issuedAt) {
      throw const CleanupFailure('CLOCK_UNTRUSTED');
    }
    if (now >= command.notAfter) {
      throw const CleanupFailure('CLEANUP_COMMAND_EXPIRED');
    }
  }

  _Record _require() =>
      _record ?? (throw const CleanupFailure('CLEANUP_JOURNAL_NOT_LOADED'));
  Future<void> _save() async {
    final raw = jsonEncode(_require().toJson());
    if (utf8.encode(raw).length > 4096) {
      _record = null;
      throw const CleanupFailure('CLEANUP_JOURNAL_INVALID');
    }
    try {
      await store.write(raw);
    } catch (_) {
      // A failed write can still have reached durable storage. Discard memory
      // and require a fresh read before creating or resending any receipt.
      _record = null;
      throw const CleanupFailure('CLEANUP_JOURNAL_UNAVAILABLE');
    }
  }
}

class _Record {
  final VerifiedCleanupCommand command;
  String? accepted, pendingId, pendingStage, pendingReason;
  bool localDataCleared = false;
  _Record(this.command);

  static _Record restore(
      VerifiedCleanupCommand command, Map<String, dynamic> json) {
    const fields = {
      'schemaVersion',
      'tenantId',
      'deviceId',
      'registrationId',
      'keyThumbprint',
      'operationId',
      'commandId',
      'commandHash',
      'issuedAt',
      'notAfter',
      'accepted',
      'localDataCleared',
      'pendingId',
      'pendingStage',
      'pendingReason'
    };
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != 1 ||
        json['tenantId'] != command.scope.tenantId ||
        json['deviceId'] != command.scope.deviceId ||
        json['registrationId'] != command.scope.registrationId ||
        json['keyThumbprint'] != command.scope.keyThumbprint ||
        json['operationId'] != command.operationId ||
        json['commandId'] != command.commandId ||
        json['commandHash'] != command.commandHash ||
        json['issuedAt'] != command.issuedAt ||
        json['notAfter'] != command.notAfter ||
        json['localDataCleared'] is! bool ||
        json['accepted'] != null &&
            !const {'RECEIVED', 'FAILED', 'AGENT_DATA_CLEARED'}
                .contains(json['accepted']) ||
        (json['pendingId'] != null && !validUuid(json['pendingId'])) ||
        (json['pendingStage'] != null &&
            !const {'RECEIVED', 'FAILED', 'AGENT_DATA_CLEARED'}
                .contains(json['pendingStage'])) ||
        (json['pendingId'] == null) != (json['pendingStage'] == null) ||
        (json['pendingReason'] != null) != (json['pendingStage'] == 'FAILED') ||
        (json['pendingReason'] != null &&
            !const {
              'STORAGE_FAILURE',
              'KEY_UNAVAILABLE',
              'UNSUPPORTED_AGENT',
              'USER_ACTION_REQUIRED'
            }.contains(json['pendingReason'])) ||
        json['accepted'] == 'AGENT_DATA_CLEARED' &&
            json['localDataCleared'] != true ||
        json['accepted'] == 'AGENT_DATA_CLEARED' && json['pendingId'] != null ||
        json['accepted'] == null && json['localDataCleared'] == true ||
        json['pendingStage'] == 'RECEIVED' && json['accepted'] != null ||
        json['pendingStage'] == 'FAILED' &&
            (json['accepted'] != 'RECEIVED' ||
                json['localDataCleared'] == true) ||
        json['pendingStage'] == 'AGENT_DATA_CLEARED' &&
            (json['localDataCleared'] != true ||
                json['accepted'] != 'RECEIVED' &&
                    json['accepted'] != 'FAILED')) {
      throw const CleanupFailure('CLEANUP_JOURNAL_INVALID');
    }
    final record = _Record(command)
      ..accepted = json['accepted']
      ..localDataCleared = json['localDataCleared']
      ..pendingId = json['pendingId']
      ..pendingStage = json['pendingStage']
      ..pendingReason = json['pendingReason'];
    return record;
  }

  CleanupReceipt? pendingReceipt() {
    if (pendingId == null) return null;
    final stage = switch (pendingStage) {
      'RECEIVED' => CleanupReceiptStage.received,
      'AGENT_DATA_CLEARED' => CleanupReceiptStage.agentDataCleared,
      'FAILED' => CleanupReceiptStage.failed,
      _ => throw const CleanupFailure('CLEANUP_JOURNAL_INVALID')
    };
    return CleanupReceipt(command, pendingId!, stage,
        reasonCode: pendingReason);
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'tenantId': command.scope.tenantId,
        'deviceId': command.scope.deviceId,
        'registrationId': command.scope.registrationId,
        'keyThumbprint': command.scope.keyThumbprint,
        'operationId': command.operationId,
        'commandId': command.commandId,
        'commandHash': command.commandHash,
        'issuedAt': command.issuedAt,
        'notAfter': command.notAfter,
        'accepted': accepted,
        'localDataCleared': localDataCleared,
        'pendingId': pendingId,
        'pendingStage': pendingStage,
        'pendingReason': pendingReason
      };
}
