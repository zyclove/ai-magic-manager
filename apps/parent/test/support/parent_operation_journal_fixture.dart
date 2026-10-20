import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/parent_durable_storage.dart';

const parentJournalFixtureApi = 'https://fixture.invalid/api/v1';
const parentJournalFixtureIssuer = 'https://identity.fixture.invalid/realms/parent';

/// Terminal evidence must come from a complete, correctly typed HTTP problem.
http.Response parentJournalTerminalProblem(String code) => http.Response.bytes(
    utf8.encode(jsonEncode({'status': 410, 'errorCode': code})), 410,
    headers: {'content-type': 'application/problem+json'});

/// Existing fixture maps remain a view of pending domain payloads. Native
/// envelopes and closed markers are separate, matching the production tables.
mixin ParentAtomicJournalFixture on ParentDurableStorage {
  Map<String, String> get values;
  bool get fixtureWriteMayCommitBeforeFailure => false;
  @override
  String get operationApiUrl => parentJournalFixtureApi;
  @override
  String get operationIssuer => parentJournalFixtureIssuer;
  late final ParentOperationJournalFixture operationFixture = ParentOperationJournalFixture(
      values: values,
      writePending: (key, value) => write(key: key, value: value),
      deletePending: (key) => delete(key: key),
      writeMayCommitBeforeFailure: () => fixtureWriteMayCommitBeforeFailure);
  @override
  Future<dynamic> operationJournal(String method, Map<String, dynamic> args) =>
      operationFixture.invoke(method, args);
}

class ParentJournalFixtureStorage extends ParentDurableStorage with ParentAtomicJournalFixture {
  @override
  final Map<String, String> values = {};
  final void Function()? onMutation;
  ParentJournalFixtureStorage({this.onMutation});
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    onMutation?.call();
  }
  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
    onMutation?.call();
  }
}

/// Serializes fake transactions, including barriers and fault replies. No
/// business request can observe an uncommitted reserve/CAS/finish operation.
class ParentOperationJournalFixture {
  final Map<String, String> values;
  final Future<void> Function(String key, String value) writePending;
  final Future<void> Function(String key) deletePending;
  final bool Function() writeMayCommitBeforeFailure;
  final Map<String, String> _rows = {}, _collections = {};
  final Map<String, Map<String, dynamic>> _closed = {};
  Future<void> _tail = Future<void>.value();
  ParentOperationJournalFixture({required this.values, required this.writePending,
      required this.deletePending, required this.writeMayCommitBeforeFailure});

  Future<dynamic> invoke(String method, Map<String, dynamic> args) {
    final result = Completer<dynamic>();
    _tail = _tail.then((_) async {
      try { result.complete(await _execute(method, args)); }
      catch (failure, stack) { result.completeError(failure, stack); }
    });
    return result.future;
  }

  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
  String get _prefix => 'parent.pending.v1.${base64Url.encode(utf8.encode(
      jsonEncode([parentJournalFixtureApi, parentJournalFixtureIssuer])))}.';
  String _logical(String physical) {
    if (!physical.startsWith(_prefix) || physical.length > 8192) {
      throw StateError('Fixture journal source mismatch');
    }
    final key = physical.substring(_prefix.length);
    if (!key.startsWith('parent.pending.') || key.length > 2048) {
      throw StateError('Fixture journal slot mismatch');
    }
    return key;
  }

  String _request(Map<String, dynamic> payload) {
    final id = payload['requestId'] ?? payload['idempotencyKey'] ??
        (payload['kind'] == 'cancel' ? 'cancel:${payload['jobId']}' : null);
    if (id is! String || id.trim().isEmpty || id.length > 128) {
      throw const FormatException('Fixture request descriptor is invalid');
    }
    return id;
  }
  Map<String, dynamic> _record(String wire) {
    if (utf8.encode(wire).length > 4 * 1024 * 1024) throw StateError('Fixture envelope oversized');
    final row = jsonDecode(wire);
    if (row is! Map<String, dynamic> || row.length != 5 ||
        row['schema'] is! int || row['schema'] != 1 ||
        !row.containsKey('terminal') || row['requestId'] is! String ||
        row['payload'] is! String || row['knownSuccessful'] is! bool ||
        (row['terminal'] != null && !const {'EXPIRED', 'ERASED'}.contains(row['terminal']))) {
      throw StateError('Fixture journal envelope is invalid');
    }
    final payload = jsonDecode(row['payload'] as String);
    if (payload is! Map<String, dynamic> || _request(payload) != row['requestId']) {
      throw StateError('Fixture request binding is invalid');
    }
    return row;
  }

  String? _sync(String physical) {
    final key = _logical(physical), payload = values[key];
    if (payload == null) { _rows.remove(physical); return null; }
    final before = _rows[physical];
    if (before != null && _record(before)['payload'] == payload) return before;
    // Direct map edits in legacy fixtures are explicit pre-seeding/corruption
    // injection. They do not bypass any production writer or CAS fallback.
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) throw const FormatException('Invalid fixture pending payload');
    final id = _request(decoded);
    if (_closed.containsKey('$physical:${_digest(id)}')) {
      throw StateError('Fixture cannot resurrect a closed request');
    }
    final previous = before == null ? null : _record(before);
    final sameRequest = previous?['requestId'] == id;
    final wire = jsonEncode({'schema': 1, 'requestId': id, 'payload': payload,
      'knownSuccessful': sameRequest ? previous!['knownSuccessful'] : false,
      'terminal': sameRequest ? previous!['terminal'] : null});
    _rows[physical] = wire;
    return wire;
  }

  Future<void> _persist(String physical, String wire, {String? collection}) async {
    final row = _record(wire), key = _logical(physical);
    void commit() {
      _rows[physical] = wire;
      if (collection != null) _collections[physical] = collection;
    }
    try {
      await writePending(key, row['payload'] as String);
      commit();
    } catch (_) {
      // Existing after-write failures model a committed native transaction
      // whose acknowledgement was lost. Before-write failures leave no row.
      if (writeMayCommitBeforeFailure() && values[key] == row['payload']) commit();
      rethrow;
    }
  }

  Future<dynamic> _execute(String method, Map<String, dynamic> args) async {
    final slot = args['slot'];
    if (slot is! String) throw StateError('Fixture slot missing');
    final logical = _logical(slot);
    if (method == 'digest') {
      final id = args['requestId'];
      if (id is! String || id.trim().isEmpty || id.length > 128) throw StateError('Fixture request missing');
      return _digest(id);
    }
    if (method == 'list') {
      for (final key in values.keys.toList()) {
        if (!key.startsWith('$logical.')) continue;
        final physical = '$_prefix$key';
        _sync(physical);
        _collections[physical] = slot;
      }
      final result = <String>[];
      for (final key in _collections.keys.toList()..sort()) {
        if (_collections[key] == slot) {
          final row = _sync(key);
          if (row != null) result.add(row);
        }
      }
      if (result.length > 20) throw StateError('Fixture collection capacity exceeded');
      return result;
    }
    final old = _sync(slot);
    if (method == 'read') return old;
    if (method == 'reserve') {
      final wire = args['next'];
      if (wire is! String) throw StateError('Fixture reserve missing');
      final next = _record(wire), digest = _digest(next['requestId'] as String);
      if (old != null || _closed.containsKey('$slot:$digest')) return false;
      if (next['terminal'] != null || next['knownSuccessful'] != false) throw StateError('Fixture reserve invalid');
      final collection = args['collection'];
      if (collection != null) {
        if (collection is! String || !slot.startsWith('$collection.')) throw StateError('Fixture collection mismatch');
        final group = _logical(collection);
        for (final key in values.keys.toList()) {
          if (key.startsWith('$group.')) {
            final physical = '$_prefix$key';
            _sync(physical);
            _collections[physical] = collection;
          }
        }
        final count = _collections.keys.where((key) => _collections[key] == collection && _sync(key) != null).length;
        if (count >= 20) throw StateError('Fixture collection capacity exceeded');
      }
      await _persist(slot, wire, collection: collection as String?);
      return true;
    }
    final expected = args['expected'];
    if (expected is! String) throw StateError('Fixture CAS token missing');
    final before = _record(expected);
    if (method == 'replace') {
      if (old != expected) return false;
      final wire = args['next'];
      if (wire is! String) throw StateError('Fixture next row missing');
      final next = _record(wire);
      if (next['requestId'] != before['requestId'] || next['payload'] != before['payload'] ||
          before['knownSuccessful'] == true && next['knownSuccessful'] != true ||
          before['terminal'] != null && next['terminal'] != before['terminal'] &&
              !(before['terminal'] == 'EXPIRED' && next['terminal'] == 'ERASED')) {
        throw StateError('Fixture CAS cannot rewrite an immutable request');
      }
      await _persist(slot, wire);
      return true;
    }
    if (method != 'finish') throw StateError('Unknown fixture journal method');
    final terminal = args['terminal'];
    if (terminal is! bool || terminal != (before['terminal'] != null)) throw StateError('Fixture finish reason mismatch');
    final digest = _digest(before['requestId'] as String), key = '$slot:${_digest(before['requestId'] as String)}';
    final reason = before['terminal'] ?? 'CHECKED';
    final previous = _closed[key];
    if (old == null && previous != null) {
      if (previous['reason'] != reason || previous['knownSuccessful'] != before['knownSuccessful']) {
        throw StateError('Fixture receipt mismatch');
      }
      return Map<String, dynamic>.from(previous);
    }
    if (old != expected || previous != null) throw StateError('Fixture CAS changed');
    final receipt = <String, dynamic>{'schema': 1, 'requestDigest': digest,
      'reason': reason, 'knownSuccessful': before['knownSuccessful'],
      'acknowledgedAt': DateTime.now().millisecondsSinceEpoch};
    void commit() {
      _closed[key] = receipt;
      _rows.remove(slot);
      _collections.remove(slot);
    }
    try { await deletePending(logical); commit(); }
    catch (_) {
      if (!values.containsKey(logical)) commit();
      rethrow;
    }
    return Map<String, dynamic>.from(receipt);
  }
}
