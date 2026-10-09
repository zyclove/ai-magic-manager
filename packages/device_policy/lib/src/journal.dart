import 'package:sembast/sembast.dart';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'verifier.dart';
import 'page.dart';

/// Persisted before being exposed to a transport. Replays keep the same ID.
class StoredConfigurationReceipt {
  final String receiptId, deliveryId, envelopeHash;
  final int cursor;
  const StoredConfigurationReceipt._(
      this.receiptId, this.deliveryId, this.cursor, this.envelopeHash);
  Map<String, dynamic> toJson() => {
        'receiptId': receiptId,
        'deliveryId': deliveryId,
        'cursor': cursor,
        'envelopeHash': envelopeHash,
        'stage': 'STORED'
      };
}

/// One Sembast transaction commits the desired display configuration,
/// per-policy tombstone, global cursor and replayable STORED receipt.
/// This database is NOT hardware-protected anti-tamper storage or a credential
/// store. Hosts must restrict access and provision a trusted time source.
class ConfigurationJournal {
  final Database database;
  final ConfigurationVerifier verifier;
  final int maxPendingReceipts;
  final int maxPolicyStreams;
  late final StoreRef<String, Map<String, Object?>> _policies,
      _receipts,
      _metadata;
  ConfigurationJournal(
      {required this.database,
      required this.verifier,
      this.maxPendingReceipts = 128,
      this.maxPolicyStreams = 64}) {
    if (maxPendingReceipts < 1 ||
        maxPendingReceipts > 1024 ||
        maxPolicyStreams < 1 ||
        maxPolicyStreams > 1024) {
      throw ArgumentError('Invalid receipt capacity');
    }
    final prefix = 'device_policy.v1.${verifier.scope.storageKey}';
    _policies = stringMapStoreFactory.store('$prefix.policies');
    _receipts = stringMapStoreFactory.store('$prefix.receipts');
    _metadata = stringMapStoreFactory.store('$prefix.metadata');
  }
  Future<T> _storage<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on ConfigurationFailure {
      rethrow;
    } catch (_) {
      throw const ConfigurationFailure('STORAGE_FAILURE');
    }
  }

  Future<Map<String, Object?>> _head(DatabaseClient client) async {
    final head = await _metadata.record('head').get(client) ??
        {'after': 0, 'observedAt': 0};
    for (final name in ['after', 'observedAt']) {
      if (head[name] is! int ||
          (head[name] as int) < 0 ||
          (head[name] as int) > maxSafeInteger) {
        throw const ConfigurationFailure('STORAGE_FAILURE');
      }
    }
    return Map<String, Object?>.from(head);
  }

  StoredConfigurationReceipt _receipt(
      Map<String, Object?> json, VerifiedConfiguration value) {
    if (!validId(json['receiptId']) ||
        json['deliveryId'] != value.deliveryId ||
        json['cursor'] != value.cursor ||
        json['envelopeHash'] != value.envelopeHash ||
        json['stage'] != 'STORED') {
      throw const ConfigurationFailure('STORAGE_FAILURE');
    }
    return StoredConfigurationReceipt._(json['receiptId'] as String,
        value.deliveryId, value.cursor, value.envelopeHash);
  }

  Future<VerifiedConfiguration> _saved(Map<String, Object?> row) async {
    if (row['compact'] is! String) {
      throw const ConfigurationFailure('STORAGE_FAILURE');
    }
    final value =
        await verifier.verify(row['compact'] as String, restoration: true);
    return value;
  }

  bool _sameContent(VerifiedConfiguration a, VerifiedConfiguration b) =>
      a.versionId == b.versionId &&
      a.action == b.action &&
      const DeepCollectionEquality().equals(a.document, b.document);

  /// Do not report RECEIVED/STORED before this Future succeeds. A failed new
  /// delivery leaves the previous state and cursor intact. No APPLIED is emitted.
  Future<StoredConfigurationReceipt> accept(String compact) async {
    final value = await verifier.verify(compact, restoration: true);
    return _storage(() => database.transaction((txn) => _saveOne(txn, value)));
  }

  Future<StoredConfigurationReceipt> _saveOne(
      Transaction txn, VerifiedConfiguration value) async {
    final head = await _head(txn);
    final row = await _policies.record(value.policyId).get(txn);
    VerifiedConfiguration? previous;
    StoredConfigurationReceipt? receipt;
    if (row != null) {
      previous = await _saved(row);
      if (previous.policyId != value.policyId) {
        throw const ConfigurationFailure('STORAGE_FAILURE');
      }
      if (previous.envelopeHash == value.envelopeHash) {
        receipt =
            _receipt(Map<String, Object?>.from(row['receipt'] as Map), value);
      } else if (value.deliveryId == previous.deliveryId ||
          value.sourceSequence < previous.sourceSequence ||
          (value.sourceSequence == previous.sourceSequence &&
              (!_sameContent(value, previous) ||
                  value.cursor != previous.cursor)) ||
          (value.sourceSequence > previous.sourceSequence &&
              value.versionId == previous.versionId)) {
        throw const ConfigurationFailure('OLDER_VERSION');
      }
    }
    if (row == null && await _policies.count(txn) >= maxPolicyStreams) {
      throw const ConfigurationFailure('STORAGE_FAILURE');
    }
    if (receipt == null) {
      final time = verifier.nowMillis();
      if (time < 0 ||
          time > maxSafeInteger ||
          time < (head['observedAt'] as int)) {
        throw const ConfigurationFailure('CLOCK_UNTRUSTED');
      }
      value.requireFirstDelivery(time);
      final newVersion =
          previous == null || value.sourceSequence > previous.sourceSequence;
      if (newVersion && value.cursor <= (head['after'] as int)) {
        throw const ConfigurationFailure('OLDER_VERSION');
      }
      receipt = StoredConfigurationReceipt._(const Uuid().v4(),
          value.deliveryId, value.cursor, value.envelopeHash);
      head['after'] =
          value.cursor > (head['after'] as int) ? value.cursor : head['after'];
      head['observedAt'] = time;
    }
    final existing = await _receipts.record(receipt.receiptId).get(txn);
    if (existing == null && await _receipts.count(txn) >= maxPendingReceipts) {
      throw const ConfigurationFailure('STORAGE_FAILURE');
    }
    await _policies
        .record(value.policyId)
        .put(txn, {'compact': value.compact, 'receipt': receipt.toJson()});
    await _receipts
        .record(receipt.receiptId)
        .put(txn, {'compact': value.compact, 'receipt': receipt.toJson()});
    await _metadata.record('head').put(txn, head);
    return receipt;
  }

  Future<int> cursor() =>
      _storage(() async => (await _head(database))['after'] as int);

  /// Verification precedes the transaction; all items, receipts and the server
  /// continuation commit together. Conflicting concurrent coordinators must
  /// restart from the durable cursor rather than skipping a page.
  Future<List<StoredConfigurationReceipt>> acceptPage(
      ConfigurationPage page) async {
    final values = <VerifiedConfiguration>[];
    final policies = <String>{};
    for (final item in page.items) {
      if (item.state == 'DEVICE_REPORTED_REJECTED') {
        throw const ConfigurationFailure('SERVER_REJECTED');
      }
      final value = await verifier.verify(item.compactJws, restoration: true);
      if (item.id != value.deliveryId ||
          item.cursor != value.cursor ||
          item.deliveryExpiresAt != value.deliveryExpiresAt ||
          value.issuedAt > page.serverTime ||
          !policies.add(value.policyId)) {
        throw const ConfigurationFailure('TRANSPORT_MISMATCH');
      }
      values.add(value);
    }
    return _storage(() => database.transaction((txn) async {
          final initial = await _head(txn);
          if (initial['after'] != page.requestedAfter) {
            throw const ConfigurationFailure('SYNC_CONFLICT');
          }
          final receipts = <StoredConfigurationReceipt>[];
          for (final value in values) {
            receipts.add(await _saveOne(txn, value));
          }
          final head = await _head(txn);
          final now = verifier.nowMillis();
          if (now < (head['observedAt'] as int) ||
              now < 0 ||
              now > maxSafeInteger) {
            throw const ConfigurationFailure('CLOCK_UNTRUSTED');
          }
          head['after'] = page.nextAfter;
          head['observedAt'] = now;
          await _metadata.record('head').put(txn, head);
          return List<StoredConfigurationReceipt>.unmodifiable(receipts);
        }));
  }

  /// Revalidates the original signature against the CURRENT trust ring on every
  /// restoration. Delivery TTL is not configuration lifetime. Removal remains
  /// stored as a tombstone, though it is omitted from the returned active map.
  Future<Map<String, VerifiedConfiguration>> restore() =>
      _storage(() => database.transaction((txn) async {
            final head = await _head(txn);
            final result = <String, VerifiedConfiguration>{};
            for (final row in await _policies.find(txn)) {
              final value = await _saved(row.value);
              if (row.key != value.policyId ||
                  value.cursor > (head['after'] as int)) {
                throw const ConfigurationFailure('STORAGE_FAILURE');
              }
              _receipt(Map<String, Object?>.from(row.value['receipt'] as Map),
                  value);
              if (value.action == 'UPSERT_CONFIGURATION') {
                result[value.policyId] = value;
              }
            }
            return Map<String, VerifiedConfiguration>.unmodifiable(result);
          }));
  Future<List<StoredConfigurationReceipt>> pendingReceipts() =>
      _storage(() => database.transaction((txn) async {
            final result = <StoredConfigurationReceipt>[];
            for (final row in await _receipts.find(txn)) {
              final value = await _saved(row.value);
              final receipt = _receipt(
                  Map<String, Object?>.from(row.value['receipt'] as Map),
                  value);
              if (row.key != receipt.receiptId) {
                throw const ConfigurationFailure('STORAGE_FAILURE');
              }
              result.add(receipt);
            }
            result.sort((a, b) => a.cursor.compareTo(b.cursor));
            return List<StoredConfigurationReceipt>.unmodifiable(result);
          }));

  /// Call only after the authenticated server accepts this exact receipt ID.
  /// Unknown/duplicate acknowledgement is harmless and cannot clear newer IDs.
  Future<void> acknowledge(String receiptId) async {
    if (!validId(receiptId)) {
      throw ArgumentError('Invalid receipt ID');
    }
    await _storage(() => _receipts.record(receiptId).delete(database));
  }
}
