import 'package:sembast/sembast.dart';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'models.dart';
import 'verifier.dart';
import 'receipt.dart';

class AccessScanPosition {
  final String? cursor;
  final int generation;
  const AccessScanPosition.internal(this.cursor, this.generation);
}

/// A configuration journal, never an execution engine. The host supplies a
/// trusted clock and a pure synchronous check against its verified baseline.
/// Keep the database private; Sembast does not provide hardware anti-rollback.
class AccessWindowJournal {
  Future<AccessScanPosition> _scan(DatabaseClient client) async {
    final row = await _metadata.record('scan').get(client);
    if (row == null) return const AccessScanPosition.internal(null, 0);
    if (!row.containsKey('cursor') ||
        (row['cursor'] != null && !accessId(row['cursor'])) ||
        !accessInteger(row['generation'], 0)) {
      throw const AccessFailure('STORAGE_FAILURE');
    }
    return AccessScanPosition.internal(
        row['cursor'] as String?, row['generation'] as int);
  }

  Future<AccessScanPosition> scanPosition() => _storage(() => _scan(database));

  /// Commit only after every item in a page has been processed or surfaced as
  /// an explicit diagnostic. A crash replays the page. End-of-scan resets the
  /// cursor; it must never become an incremental change-feed watermark.
  Future<void> advanceScan(AccessScanPosition expected, String? nextCursor) =>
      _storage(() => database.transaction((txn) async {
            final current = await _scan(txn);
            if (current.cursor != expected.cursor ||
                current.generation != expected.generation) {
              throw const AccessFailure('SYNC_CONFLICT');
            }
            if ((nextCursor != null &&
                    (!accessId(nextCursor) ||
                        (current.cursor != null &&
                            nextCursor.compareTo(current.cursor!) <= 0))) ||
                current.generation >= accessMaxInteger) {
              throw const AccessFailure('TRANSPORT_INVALID');
            }
            await _metadata.record('scan').put(txn, {
              'cursor': nextCursor,
              'generation': nextCursor == null
                  ? current.generation + 1
                  : current.generation
            });
          }));

  /// Probes the actual writable journal and current verified baseline before
  /// spending another server attempt. This never alters the terminal receipt.
  Future<bool> prepareRetry(AccessDocument document) async {
    final value =
        await verifier.verify(document.signedDocument, restoration: true);
    document.requireMatch(value);
    if (document.deliveryState != 'REJECTED' ||
        document.deliveryAttempt >= 10 ||
        !{'BASELINE_MISSING', 'STORAGE_FAILED'}.contains(document.reasonCode) ||
        !{'WAITING', 'AVAILABLE'}.contains(document.retryStatus) ||
        document.retryAfter == null) return false;
    return _storage(() => database.transaction((txn) async {
          final time = _requireTime(await _floor(txn), _sampleTime());
          if (time < document.retryAfter!) return false;
          final row = await _requests.record(value.requestId).get(txn);
          if (row == null) throw const AccessFailure('RETRY_NOT_PREPARED');
          final previous = await _saved(row);
          _requireAdvance(previous.value, value);
          if (previous.value.compact != value.compact ||
              previous.receipt.deliveryAttempt != document.deliveryAttempt ||
              previous.receipt.phase != 'REJECTED') return false;
          if (!value.isRemoval) {
            try {
              value.requireCurrent(time);
            } on AccessFailure catch (error) {
              if (error.code == 'EXPIRED') return false;
              rethrow;
            }
            if (!_hasBaseline(value)) return false;
          }
          if (await _receipts.count(txn) >= maxPendingReceipts) return false;
          await _metadata.record('head').put(txn, {'observedAt': time});
          return true;
        }));
  }

  final Database database;
  final AccessWindowVerifier verifier;
  final bool Function(VerifiedAccessWindow) baselineMatches;
  final int maxRequests, maxPendingReceipts;
  late final StoreRef<String, Map<String, Object?>> _requests,
      _receipts,
      _metadata;
  AccessWindowJournal(
      {required this.database,
      required this.verifier,
      required this.baselineMatches,
      this.maxRequests = 256,
      this.maxPendingReceipts = 128}) {
    if (maxRequests < 1 ||
        maxRequests > 4096 ||
        maxPendingReceipts < 1 ||
        maxPendingReceipts > 1024) {
      throw ArgumentError('Invalid access journal capacity');
    }
    final prefix = 'device_access.v1.${verifier.scope.storageKey}';
    _requests = stringMapStoreFactory.store('$prefix.requests');
    _receipts = stringMapStoreFactory.store('$prefix.receipts');
    _metadata = stringMapStoreFactory.store('$prefix.metadata');
  }
  Future<T> _storage<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AccessFailure {
      rethrow;
    } catch (_) {
      throw const AccessFailure('STORAGE_FAILURE');
    }
  }

  Future<int> _floor(DatabaseClient client) async {
    final row = await _metadata.record('head').get(client);
    if (row == null) return 0;
    if (!accessInteger(row['observedAt'], 0)) {
      throw const AccessFailure('STORAGE_FAILURE');
    }
    return row['observedAt'] as int;
  }

  int? _sampleTime() {
    try {
      final time = verifier.nowMillis();
      return accessInteger(time, 0) ? time : null;
    } catch (_) {
      return null;
    }
  }

  int _requireTime(int floor, int? time) {
    if (time == null || time < floor) {
      throw const AccessFailure('CLOCK_UNTRUSTED');
    }
    return time;
  }

  bool _hasBaseline(VerifiedAccessWindow value) {
    try {
      return baselineMatches(value);
    } catch (_) {
      throw const AccessFailure('BASELINE_UNAVAILABLE');
    }
  }

  String _hash(String compact) =>
      sha256.convert(utf8.encode(compact)).toString();
  Map<String, Object?> _row(
          VerifiedAccessWindow value, AccessReceipt receipt, bool accepted) =>
      {
        'compact': value.compact,
        'hash': _hash(value.compact),
        'accepted': accepted,
        'receipt': {
          'requestId': receipt.requestId,
          'approvalVersion': receipt.approvalVersion,
          ...receipt.toJson()
        }
      };
  Future<_SavedAccess> _saved(Map<String, Object?> row) async {
    final compact = row['compact'];
    if (compact is! String ||
        compact.length > 131072 ||
        row['hash'] != _hash(compact) ||
        row['accepted'] is! bool ||
        row['receipt'] is! Map) {
      throw const AccessFailure('STORAGE_FAILURE');
    }
    final value = await verifier.verify(compact, restoration: true);
    final json = Map<String, Object?>.from(row['receipt'] as Map);
    final rejected = json['phase'] == 'REJECTED';
    if (json['documentId'] != value.documentId ||
        json['requestId'] != value.requestId ||
        json['approvalVersion'] != value.approvalVersion ||
        !accessInteger(json['deliveryAttempt'], 1) ||
        (json['deliveryAttempt'] as int) > 10 ||
        !{'STORED', 'REJECTED'}.contains(json['phase']) ||
        (rejected
            ? !accessRejectionReasons.contains(json['reasonCode'])
            : json['reasonCode'] != null) ||
        (!rejected && !value.isRemoval && row['accepted'] != true) ||
        (value.isRemoval && row['accepted'] != false)) {
      throw const AccessFailure('STORAGE_FAILURE');
    }
    return _SavedAccess(
        value,
        AccessReceipt.internal(
            value.requestId,
            value.documentId,
            value.approvalVersion,
            json['deliveryAttempt'] as int,
            json['phase'] as String,
            json['reasonCode'] as String?),
        row['accepted'] as bool);
  }

  void _requireAdvance(
      VerifiedAccessWindow previous, VerifiedAccessWindow next) {
    if (next.approvalVersion < previous.approvalVersion) {
      throw const AccessFailure('STALE_APPROVAL');
    }
    if (next.approvalVersion == previous.approvalVersion) {
      if (next.compact != previous.compact) {
        throw const AccessFailure('APPROVAL_CONFLICT');
      }
      return;
    }
    if (next.documentId == previous.documentId ||
        next.documentIssuedAt < previous.documentIssuedAt ||
        (previous.isRemoval && !next.isRemoval)) {
      throw const AccessFailure('APPROVAL_CONFLICT');
    }
    for (final field in _grantIdentity) {
      if (!const DeepCollectionEquality()
          .equals(next.fields[field], previous.fields[field])) {
        throw const AccessFailure('GRANT_CHANGED');
      }
    }
  }

  void _requireTerminalMatch(AccessDocument document, AccessReceipt receipt) {
    if ((document.deliveryState == 'STORED' && receipt.phase != 'STORED') ||
        (document.deliveryState == 'REJECTED' &&
            (receipt.phase != 'REJECTED' ||
                receipt.reasonCode != document.reasonCode))) {
      throw const AccessFailure('DELIVERY_CONFLICT');
    }
  }

  Future<void> _enqueue(
      Transaction txn, Map<String, Object?> row, AccessReceipt receipt) async {
    final existing = await _receipts.record(receipt.key).get(txn);
    if (existing == null) {
      if (await _receipts.count(txn) >= maxPendingReceipts) {
        throw const AccessFailure('STORAGE_CAPACITY');
      }
    } else {
      final saved = await _saved(existing);
      if (saved.receipt.key != receipt.key ||
          !const DeepCollectionEquality().equals(existing, row)) {
        throw const AccessFailure('STORAGE_FAILURE');
      }
    }
    await _receipts.record(receipt.key).put(txn, row);
  }

  /// Only return or send the receipt after this Future succeeds. A rejection
  /// has its own durable receipt; thrown failures are LOCAL diagnostics and
  /// must never be blindly converted to REJECTED transport messages.
  Future<AccessReceipt> accept(AccessDocument document) async {
    final value =
        await verifier.verify(document.signedDocument, restoration: true);
    document.requireMatch(value);
    return _storage(() => database.transaction((txn) async {
          final floor = await _floor(txn);
          final row = await _requests.record(value.requestId).get(txn);
          _SavedAccess? previous;
          if (row != null) {
            previous = await _saved(row);
            if (previous.value.requestId != value.requestId) {
              throw const AccessFailure('STORAGE_FAILURE');
            }
            _requireAdvance(previous.value, value);
            if (value.approvalVersion == previous.value.approvalVersion) {
              if (document.deliveryAttempt < previous.receipt.deliveryAttempt) {
                throw const AccessFailure('STALE_ATTEMPT');
              }
              if (document.deliveryAttempt ==
                  previous.receipt.deliveryAttempt) {
                _requireTerminalMatch(document, previous.receipt);
                await _enqueue(txn, row, previous.receipt);
                return previous.receipt;
              }
            }
          } else if (await _requests.count(txn) >= maxRequests) {
            throw const AccessFailure('STORAGE_CAPACITY');
          }
          final time = _sampleTime();
          String? reason =
              document.deliveryState == 'REJECTED' ? document.reasonCode : null;
          if (!value.isRemoval && reason == null) {
            final current = _requireTime(floor, time);
            try {
              value.requireCurrent(current);
            } on AccessFailure catch (error) {
              if (error.code != 'EXPIRED') rethrow;
              reason = 'EXPIRED';
            }
            if (reason == null && !_hasBaseline(value)) {
              reason = 'BASELINE_MISSING';
            }
            if (reason != null && document.deliveryState == 'STORED') {
              throw AccessFailure(reason);
            }
          }
          final receipt = AccessReceipt.internal(
              value.requestId,
              value.documentId,
              value.approvalVersion,
              document.deliveryAttempt,
              reason == null ? 'STORED' : 'REJECTED',
              reason);
          final accepted = !value.isRemoval &&
              (reason == null ||
                  (previous?.value.compact == value.compact &&
                      previous!.accepted));
          final saved = _row(value, receipt, accepted);
          await _enqueue(txn, saved, receipt);
          await _requests.record(value.requestId).put(txn, saved);
          await _metadata.record('head').put(
              txn, {'observedAt': time != null && time > floor ? time : floor});
          return receipt;
        }));
  }

  /// Revalidates current trust, baseline and original absolute expiry. The
  /// caller must fail closed on errors and refresh at expiry, never cache a
  /// returned configuration indefinitely. No system access is granted here.
  Future<Map<String, VerifiedAccessWindow>> restore() =>
      _storage(() => database.transaction((txn) async {
            final floor = await _floor(txn);
            final current = _requireTime(floor, _sampleTime());
            final records = await _requests.find(txn);
            if (records.length > maxRequests) {
              throw const AccessFailure('STORAGE_CAPACITY');
            }
            final active = <String, VerifiedAccessWindow>{};
            for (final record in records) {
              final saved = await _saved(record.value);
              final value = saved.value;
              if (record.key != value.requestId) {
                throw const AccessFailure('STORAGE_FAILURE');
              }
              if (value.isRemoval || !saved.accepted) continue;
              try {
                value.requireCurrent(current);
              } on AccessFailure catch (error) {
                if (error.code == 'EXPIRED') continue;
                rethrow;
              }
              if (_hasBaseline(value)) active[value.requestId] = value;
            }
            await _metadata.record('head').put(txn, {'observedAt': current});
            return Map<String, VerifiedAccessWindow>.unmodifiable(active);
          }));

  /// Explain durable terminal/current states without turning expired or removed
  /// documents into active access. Reverify every signed row and pending receipt.
  Future<List<AccessJournalEntry>> inspect() =>
      _storage(() => database.transaction((txn) async {
            final current = _requireTime(await _floor(txn), _sampleTime());
            final records = await _requests.find(txn);
            final pending = await _receipts.find(txn);
            if (records.length > maxRequests ||
                pending.length > maxPendingReceipts) {
              throw const AccessFailure('STORAGE_CAPACITY');
            }
            final keys = <String>{};
            for (final record in pending) {
              final saved = await _saved(record.value);
              if (record.key != saved.receipt.key) {
                throw const AccessFailure('STORAGE_FAILURE');
              }
              keys.add(record.key);
            }
            final entries = <AccessJournalEntry>[];
            for (final record in records) {
              final saved = await _saved(record.value), value = saved.value;
              if (record.key != value.requestId) {
                throw const AccessFailure('STORAGE_FAILURE');
              }
              var state = value.isRemoval
                  ? AccessEntryState.removed
                  : !saved.accepted
                      ? AccessEntryState.rejected
                      : AccessEntryState.stored;
              if (state == AccessEntryState.stored) {
                try {
                  value.requireCurrent(current);
                } on AccessFailure catch (error) {
                  if (error.code != 'EXPIRED') rethrow;
                  state = AccessEntryState.expired;
                }
                if (state == AccessEntryState.stored && !_hasBaseline(value)) {
                  state = AccessEntryState.baselineMissing;
                }
              }
              entries.add(AccessJournalEntry(value, state,
                  pendingAcknowledgement: keys.contains(saved.receipt.key),
                  reasonCode: saved.receipt.reasonCode));
            }
            await _metadata.record('head').put(txn, {'observedAt': current});
            return List<AccessJournalEntry>.unmodifiable(entries);
          }));

  Future<List<AccessReceipt>> pendingReceipts() =>
      _storage(() => database.transaction((txn) async {
            final records = await _receipts.find(txn);
            if (records.length > maxPendingReceipts) {
              throw const AccessFailure('STORAGE_CAPACITY');
            }
            final result = <AccessReceipt>[];
            for (final record in records) {
              final saved = await _saved(record.value);
              if (record.key != saved.receipt.key) {
                throw const AccessFailure('STORAGE_FAILURE');
              }
              result.add(saved.receipt);
            }
            return List<AccessReceipt>.unmodifiable(result);
          }));

  /// The ACK must be obtained over the authenticated transport. Historical
  /// current=false responses may clear exactly their own queued receipt.
  Future<bool> acknowledge(AccessReceiptAcknowledgement acknowledgement) =>
      _storage(() => database.transaction((txn) async {
            final row = await _receipts.record(acknowledgement.key).get(txn);
            if (row == null) return false;
            final saved = await _saved(row);
            if (saved.receipt.key != acknowledgement.key ||
                !acknowledgement.matches(saved.receipt)) {
              throw const AccessFailure('ACK_MISMATCH');
            }
            await _receipts.record(acknowledgement.key).delete(txn);
            return true;
          }));
}

class _SavedAccess {
  final VerifiedAccessWindow value;
  final AccessReceipt receipt;
  final bool accepted;
  const _SavedAccess(this.value, this.receipt, this.accepted);
}

const _grantIdentity = [
  'issuer',
  'tenantId',
  'subjectId',
  'deviceId',
  'registrationId',
  'requestId',
  'policyId',
  'baseVersionId',
  'applicationId',
  'ruleIds',
  'grantIssuedAt',
  'absoluteNotAfter'
];
