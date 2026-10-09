import 'package:collection/collection.dart';
import 'package:sembast/sembast.dart';
import 'models.dart';
import 'submission.dart';

enum SubmissionOperationPhase { prepared, unknown, rejected }

/// These domain responses prove this exact attempt was not committed. Expired
/// idempotency keys, authentication failures and arbitrary HTTP text do not.
const submissionDefinitiveRejections = {
  'BASELINE_CHANGED',
  'EXCEPTION_RULE_INVALID',
  'SAFETY_BASELINE_PROTECTED',
  'EXCEPTION_KIND_UNSUPPORTED',
  'ACCESS_REQUEST_PENDING',
  'ACCESS_EXCEPTION_EXISTS',
  'ACCESS_REQUEST_COOLDOWN',
  'RESOURCE_VERSION_CONFLICT',
  'ACCESS_REQUEST_NOT_PENDING'
};

class SubmissionOperation {
  final String kind, key, applicationName;
  final int createdAt;
  final SubmissionOperationPhase phase;
  final AccessSubmissionInput? input;
  final String? requestId, rejectionCode;
  final int? version;
  const SubmissionOperation._(
      this.kind,
      this.key,
      this.applicationName,
      this.createdAt,
      this.phase,
      this.input,
      this.requestId,
      this.version,
      this.rejectionCode);
  Map<String, dynamic> _json() => {
        'schemaVersion': 1,
        'kind': kind,
        'key': key,
        'applicationName': applicationName,
        'createdAt': createdAt,
        'phase': phase.name,
        'input': input?.toJson(),
        'requestId': requestId,
        'version': version,
        'rejectionCode': rejectionCode
      };
  SubmissionOperation _with(SubmissionOperationPhase next, [String? code]) =>
      SubmissionOperation._(kind, key, applicationName, createdAt, next, input,
          requestId, version, code);
  @override
  String toString() => 'SubmissionOperation(kind=$kind, phase=${phase.name})';
}

class SubmissionCacheEntry {
  final AccessSubmission value;
  final String applicationName;
  const SubmissionCacheEntry(this.value, this.applicationName);
}

class SubmissionJournalView {
  final SubmissionOperation? pending;
  final List<SubmissionCacheEntry> entries;
  const SubmissionJournalView(this.pending, this.entries);
}

/// A single unresolved mutation, written before network I/O. The host owns and
/// encrypts the database, supplies an authenticated scope and never migrates an
/// old registration/subject namespace. This journal never grants app access.
class AccessSubmissionJournal {
  final Database database;
  final DeviceAccessScope scope;
  final int maxEntries;
  late final StoreRef<String, Map<String, Object?>> _operations, _facts;
  AccessSubmissionJournal(
      {required this.database, required this.scope, this.maxEntries = 100}) {
    if (scope.issuer.isEmpty ||
        scope.issuer.length > 2048 ||
        ![scope.tenantId, scope.subjectId, scope.deviceId, scope.registrationId]
            .every(accessId) ||
        maxEntries < 1 ||
        maxEntries > 256) {
      throw ArgumentError('Invalid request journal scope or bounds');
    }
    _operations = stringMapStoreFactory
        .store('submissions-v1-${scope.storageKey}-operation');
    _facts =
        stringMapStoreFactory.store('submissions-v1-${scope.storageKey}-facts');
  }
  void _scope(AccessSubmission value) {
    if (value.subjectId != scope.subjectId ||
        value.deviceId != scope.deviceId ||
        value.registrationId != scope.registrationId) {
      throw const AccessFailure('ACCESS_TARGET_CHANGED');
    }
  }

  static bool _key(String value) =>
      RegExp(r'^[A-Za-z0-9._-]{1,128}$').stringMatch(value) == value;
  static bool _name(Object? value) =>
      value is String && value.trim().isNotEmpty && value.length <= 100;
  Future<T> _storage<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AccessFailure {
      rethrow;
    } catch (_) {
      throw const AccessFailure('SUBMISSION_STORAGE_FAILED');
    }
  }

  SubmissionOperation _decode(Map<String, Object?> row) {
    try {
      if (row.length != 10 ||
          !{
            'schemaVersion',
            'kind',
            'key',
            'applicationName',
            'createdAt',
            'phase',
            'input',
            'requestId',
            'version',
            'rejectionCode'
          }.every(row.containsKey) ||
          row['schemaVersion'] != 1 ||
          row['key'] is! String ||
          !_key(row['key'] as String) ||
          !_name(row['applicationName']) ||
          !accessInteger(row['createdAt'], 0)) throw const FormatException();
      final phase = SubmissionOperationPhase.values
          .firstWhere((p) => p.name == row['phase']);
      final rejection = row['rejectionCode'];
      if (phase == SubmissionOperationPhase.rejected
          ? !submissionDefinitiveRejections.contains(rejection)
          : rejection != null) throw const FormatException();
      AccessSubmissionInput? input;
      final kind = row['kind'];
      if (kind == 'CREATE') {
        final raw = Map<String, dynamic>.from(row['input'] as Map);
        if (raw.length != 6 ||
            row['requestId'] != null ||
            row['version'] != null) throw const FormatException();
        input = AccessSubmissionInput(
            policyId: raw['policyId'],
            baseVersionId: raw['baseVersionId'],
            applicationId: raw['applicationId'],
            ruleIds: List<String>.from(raw['ruleIds']),
            requestedWindowSeconds: raw['requestedWindowSeconds'],
            reason: raw['reason']);
        if (!const DeepCollectionEquality().equals(input.toJson(), raw)) {
          throw const FormatException();
        }
      } else if (kind != 'CANCEL' ||
          row['input'] != null ||
          !accessId(row['requestId']) ||
          !accessInteger(row['version'], 0)) {
        throw const FormatException();
      }
      return SubmissionOperation._(
          kind as String,
          row['key'] as String,
          row['applicationName'] as String,
          row['createdAt'] as int,
          phase,
          input,
          row['requestId'] as String?,
          row['version'] as int?,
          rejection as String?);
    } catch (_) {
      throw const AccessFailure('SUBMISSION_STORAGE_FAILED');
    }
  }

  Future<SubmissionOperation?> _pending(DatabaseClient client) async {
    final row = await _operations.record('pending').get(client);
    return row == null ? null : _decode(row);
  }

  Future<SubmissionOperation> _require(
      DatabaseClient client, String key) async {
    final current = await _pending(client);
    if (current == null || current.key != key) {
      throw const AccessFailure('SUBMISSION_OPERATION_CONFLICT');
    }
    return current;
  }

  SubmissionCacheEntry _entry(Map<String, Object?> row) {
    if (row.length != 2 ||
        !_name(row['applicationName']) ||
        row['value'] is! Map) {
      throw const AccessFailure('SUBMISSION_STORAGE_FAILED');
    }
    final value = AccessSubmission.fromJson(
        Map<String, dynamic>.from(row['value'] as Map));
    _scope(value);
    return SubmissionCacheEntry(value, row['applicationName'] as String);
  }

  Future<SubmissionJournalView> inspect() =>
      _storage(() => database.transaction((txn) async {
            final pending = await _pending(txn);
            final rows =
                await _facts.find(txn, finder: Finder(limit: maxEntries + 1));
            if (rows.length > maxEntries) {
              throw const AccessFailure('SUBMISSION_STORAGE_FAILED');
            }
            final entries = rows.map((r) {
              final e = _entry(r.value);
              if (e.value.id != r.key) {
                throw const AccessFailure('SUBMISSION_STORAGE_FAILED');
              }
              return e;
            }).toList()
              ..sort((a, b) => (b.value.toJson()['createdAt'] as int)
                  .compareTo(a.value.toJson()['createdAt'] as int));
            return SubmissionJournalView(pending, List.unmodifiable(entries));
          }));
  Future<SubmissionOperation> prepareCreate(AccessSubmissionInput input,
          {required String key,
          required String applicationName,
          required int now}) =>
      _prepare(SubmissionOperation._('CREATE', key, applicationName, now,
          SubmissionOperationPhase.prepared, input, null, null, null));
  Future<SubmissionOperation> prepareCancel(AccessSubmission value,
      {required String key,
      required String applicationName,
      required int now}) {
    _scope(value);
    if (value.state != 'PENDING') {
      throw const AccessFailure('ACCESS_REQUEST_NOT_PENDING');
    }
    return _prepare(
        SubmissionOperation._(
            'CANCEL',
            key,
            applicationName,
            now,
            SubmissionOperationPhase.prepared,
            null,
            value.id,
            value.version,
            null),
        value: value);
  }

  Future<SubmissionOperation> _prepare(SubmissionOperation operation,
      {AccessSubmission? value}) {
    if (!_key(operation.key) ||
        !_name(operation.applicationName) ||
        !accessInteger(operation.createdAt, 0)) {
      throw ArgumentError('Invalid bounded operation');
    }
    return _storage(() => database.transaction((txn) async {
          final pending = await _pending(txn);
          if (pending != null) {
            final a = pending._json()
              ..remove('phase')
              ..remove('rejectionCode')
              ..remove('createdAt');
            final b = operation._json()
              ..remove('phase')
              ..remove('rejectionCode')
              ..remove('createdAt');
            if (!const DeepCollectionEquality().equals(a, b)) {
              throw const AccessFailure('SUBMISSION_OPERATION_PENDING');
            }
            return pending;
          }
          if (value != null) {
            final cached = await _facts.record(value.id).get(txn);
            if (cached != null &&
                _entry(cached).value.version != value.version) {
              throw const AccessFailure('RESOURCE_VERSION_CONFLICT');
            }
            await _record(txn, value, operation.applicationName);
          }
          await _operations.record('pending').put(txn, operation._json());
          return operation;
        }));
  }

  Future<SubmissionOperation> markSending(String key) =>
      _storage(() => database.transaction((txn) async {
            final current = await _require(txn, key);
            if (current.phase == SubmissionOperationPhase.rejected) {
              throw const AccessFailure('SUBMISSION_OPERATION_REJECTED');
            }
            final next = current._with(SubmissionOperationPhase.unknown);
            await _operations.record('pending').put(txn, next._json());
            return next;
          }));
  Future<void> reject(String key, String code) {
    if (!submissionDefinitiveRejections.contains(code)) {
      return Future.error(const AccessFailure('SUBMISSION_REJECTION_UNPROVEN'));
    }
    return _storage(() => database.transaction((txn) async {
          final current = await _require(txn, key);
          await _operations.record('pending').put(txn,
              current._with(SubmissionOperationPhase.rejected, code)._json());
        }));
  }

  Future<void> discardUnsentOrRejected(String key) =>
      _storage(() => database.transaction((txn) async {
            final current = await _require(txn, key);
            if (current.phase == SubmissionOperationPhase.unknown) {
              throw const AccessFailure('SUBMISSION_RESULT_UNKNOWN');
            }
            await _operations.record('pending').delete(txn);
          }));
  Future<void> complete(String key, AccessSubmission value) =>
      _storage(() => database.transaction((txn) async {
            final current = await _require(txn, key);
            _scope(value);
            if (current.phase != SubmissionOperationPhase.unknown ||
                (current.kind == 'CREATE'
                    ? !current.input!.matches(value)
                    : value.id != current.requestId ||
                        value.state != 'CANCELLED' ||
                        value.version <= current.version!)) {
              throw const AccessFailure('SUBMISSION_OPERATION_CONFLICT');
            }
            await _record(txn, value, current.applicationName);
            await _operations.record('pending').delete(txn);
          }));
  Future<void> record(AccessSubmission value,
          {required String applicationName}) =>
      _storage(() =>
          database.transaction((txn) => _record(txn, value, applicationName)));
  Future<void> _record(
      DatabaseClient txn, AccessSubmission value, String name) async {
    _scope(value);
    if (!_name(name)) throw const AccessFailure('SUBMISSION_STORAGE_FAILED');
    final old = await _facts.record(value.id).get(txn);
    if (old != null) {
      final prior = _entry(old).value;
      if (!AccessSubmissionInput(
                  policyId: prior.policyId,
                  baseVersionId: prior.baseVersionId,
                  applicationId: prior.applicationId,
                  ruleIds: prior.ruleIds,
                  requestedWindowSeconds: prior.requestedWindowSeconds,
                  reason: prior.reason)
              .matches(value) ||
          prior.toJson()['createdAt'] != value.toJson()['createdAt'] ||
          prior.requestExpiresAt != value.requestExpiresAt) {
        throw const AccessFailure('SUBMISSION_FACT_CONFLICT');
      }
      if (value.version < prior.version) return;
      if (value.version == prior.version &&
              !const DeepCollectionEquality()
                  .equals(value.toJson(), prior.toJson()) ||
          prior.absoluteNotAfter != null &&
              prior.absoluteNotAfter != value.absoluteNotAfter ||
          !{'PENDING', 'APPROVED_PENDING_DELIVERY'}.contains(prior.state) &&
              prior.state != value.state) {
        throw const AccessFailure('SUBMISSION_FACT_CONFLICT');
      }
    }
    await _facts
        .record(value.id)
        .put(txn, {'value': value.toJson(), 'applicationName': name});
    final rows = await _facts.find(txn,
        finder: Finder(
            sortOrders: [SortOrder('value.createdAt')], limit: maxEntries + 1));
    if (rows.length > maxEntries) {
      final evict = rows.firstWhere((r) => r.key != value.id);
      await _facts.record(evict.key).delete(txn);
    }
  }
}
