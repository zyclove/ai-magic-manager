import 'dart:convert';

import 'parent_api.dart';
import 'parent_durable_storage.dart';

/// The native journal owns the compare-and-swap transaction and encrypted data.
/// A Dart cache is only an expected-version token, never an atomicity boundary.
class ParentOperationJournal {
  final ParentDurableStorage storage;
  final Map<String, String?> _snapshots = {};
  final Set<String> _changed = {};
  ParentOperationJournal(this.storage);

  String physicalSlot(String logical) {
    final api = Uri.tryParse(storage.operationApiUrl);
    final issuer = Uri.tryParse(storage.operationIssuer);
    bool safe(Uri? value) => value != null && value.scheme == 'https' &&
        value.host.isNotEmpty && value.userInfo.isEmpty &&
        !value.hasQuery && !value.hasFragment;
    if (!safe(api) || !safe(issuer) || !api!.path.endsWith('/api/v1') ||
        !logical.startsWith('parent.pending.') || logical.length > 2048) {
      throw StateError('本机核对存储的服务来源未配置，已停止写入。');
    }
    final identity = jsonEncode([api.toString(), issuer.toString()]);
    final slot = 'parent.pending.v1.${base64Url.encode(utf8.encode(identity))}.$logical';
    if (slot.length > 8192) throw StateError('本机核对范围过长。');
    return slot;
  }

  Future<dynamic> _call(String method, String slot, [Json args = const {}]) =>
      storage.operationJournal(method, {'slot': physicalSlot(slot), ...args});

  Json _decode(String wire) {
    final row = jsonDecode(wire);
    if (row is! Json || row.length != 5 || row['schema'] is! int || row['schema'] != 1 ||
        !const ['schema', 'requestId', 'payload', 'knownSuccessful', 'terminal'].every(row.containsKey) ||
        row['requestId'] is! String || row['payload'] is! String ||
        row['knownSuccessful'] is! bool ||
        (row['terminal'] != null &&
            !const {'EXPIRED', 'ERASED'}.contains(row['terminal']))) {
      throw StateError('本机核对记录无法校验，已停止写入。');
    }
    return row;
  }

  Json? snapshot(String slot) {
    final wire = _snapshots[slot];
    return wire == null ? null : _decode(wire);
  }

  bool changed(String slot) => _changed.contains(slot);

  Future<String?> read({required String key}) async {
    final raw = await _call('read', key);
    if (raw != null && raw is! String) throw StateError('本机核对记录不可读。');
    final wire = raw as String?;
    final row = wire == null ? null : _decode(wire);
    _snapshots[key] = wire;
    _changed.remove(key);
    return row?['payload'] as String?;
  }

  Future<void> write({required String key, required String value,
      String? collection}) async {
    final payload = jsonDecode(value);
    if (payload is! Json) throw const FormatException('本机核对内容无效。');
    final id = payload['requestId'] ?? payload['idempotencyKey'] ??
        (payload['kind'] == 'cancel' ? 'cancel:${payload['jobId']}' : null);
    if (id is! String || id.isEmpty || id.length > 128) {
      throw const FormatException('本机请求编号无效。');
    }
    final wire = jsonEncode({'schema': 1, 'requestId': id, 'payload': value,
      'knownSuccessful': false, 'terminal': null});
    if (await _call('reserve', key, {'next': wire,
        if (collection != null) 'collection': physicalSlot(collection)}) != true) {
      _changed.add(key);
      throw StateError('本机核对记录已变化，请重新打开核对；原请求不会重建。');
    }
    _snapshots[key] = wire;
    _changed.remove(key);
  }

  /// Enumerating one publication collection is read-only. Each entry still has
  /// its own immutable request, terminal state and transaction CAS token.
  Future<List<String>> readCollection(String collection,
      String Function(Json payload) keyFor) async {
    final raw = await _call('list', collection);
    if (raw is! List || raw.length > 20) throw StateError('本机发布记录无法读取。');
    final values = <String>[];
    final seen = <String>{};
    for (final wire in raw) {
      if (wire is! String) throw StateError('本机发布记录无法读取。');
      final row = _decode(wire);
      final payload = jsonDecode(row['payload'] as String);
      if (payload is! Json) throw StateError('本机发布记录无效。');
      final key = keyFor(payload);
      if (!key.startsWith('$collection.') || !seen.add(key)) {
        throw StateError('本机发布范围不匹配。');
      }
      _snapshots[key] = wire;
      _changed.remove(key);
      values.add(row['payload'] as String);
    }
    return values;
  }

  Future<void> assertCurrent(String slot, Json? payload) async {
    if (!_snapshots.containsKey(slot) || changed(slot)) {
      throw StateError('请重新读取本机核对记录。');
    }
    final expected = _snapshots[slot];
    final actual = await _call('read', slot);
    if (expected != null && actual is String && actual != expected) {
      final before = _decode(expected), now = _decode(actual);
      if (before['requestId'] == now['requestId'] &&
          before['payload'] == now['payload'] && now['terminal'] != null) {
        _snapshots[slot] = actual;
      }
    }
    if (actual != expected ||
        (expected == null ? payload != null :
          payload == null || jsonEncode(payload) != _decode(expected)['payload'])) {
      _changed.add(slot);
      throw StateError('另一窗口已处理本机核对记录，请重新打开。');
    }
    if (expected != null && _decode(expected)['terminal'] != null) {
      throw StateError('原结果已不可恢复，请查看当前记录或结束本机核对。');
    }
  }

  Future<void> _replace(String slot, Json next) async {
    final expected = _snapshots[slot];
    if (expected == null || changed(slot)) throw StateError('本机核对记录已变化。');
    final wire = jsonEncode(next);
    if (await _call('replace', slot, {'expected': expected, 'next': wire}) != true) {
      _changed.add(slot);
      throw StateError('另一窗口已处理本机核对记录，请重新打开。');
    }
    _snapshots[slot] = wire;
  }

  Future<void> confirmed(String slot) async {
    final row = snapshot(slot);
    if (row == null || row['knownSuccessful'] == true) return;
    await _replace(slot, {...row, 'knownSuccessful': true});
  }

  Future<void> terminal(String slot, String requestId, String reason,
      {bool knownSuccessful = false}) async {
    final expected = snapshot(slot);
    if (expected == null || expected['requestId'] != requestId) {
      throw StateError('本机原请求已变化，不能覆盖其他操作。');
    }
    final latest = await _call('read', slot);
    if (latest == null && expected['terminal'] != null) {
      // finish may have committed before the platform reply was lost. Only the
      // atomic finish receipt can prove this; a missing pending row alone cannot.
      return;
    }
    if (latest is! String) throw StateError('本机原请求已变化，请重新打开核对。');
    final row = _decode(latest);
    if (row['requestId'] != requestId || row['payload'] != expected['payload']) {
      _changed.add(slot);
      throw StateError('另一窗口已处理本机原请求，请重新打开核对。');
    }
    _snapshots[slot] = latest;
    _changed.remove(slot);
    final next = row['terminal'] == 'ERASED' ? 'ERASED' : reason;
    if (row['terminal'] == next &&
        (!knownSuccessful || row['knownSuccessful'] == true)) return;
    await _replace(slot, {...row, 'terminal': next,
      'knownSuccessful': knownSuccessful || row['knownSuccessful'] == true});
  }

  Future<void> _finish(String key, {required bool terminal}) async {
    final expected = _snapshots[key];
    if (expected == null || changed(key)) throw StateError('本机核对记录已变化。');
    final row = _decode(expected);
    if ((row['terminal'] != null) != terminal) {
      throw StateError('请使用原结果提示中的“结束本机核对”。');
    }
    final requestDigest = await _call('digest', key, {'requestId': row['requestId']});
    if (requestDigest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(requestDigest)) {
      throw StateError('本机请求摘要无法校验。');
    }
    final receipt = await _call('finish', key,
        {'expected': expected, 'terminal': terminal});
    if (receipt is! Map || receipt.length != 5 || receipt['schema'] is! int || receipt['schema'] != 1 ||
        receipt['reason'] != (row['terminal'] ?? 'CHECKED') ||
        receipt['knownSuccessful'] != row['knownSuccessful'] ||
        receipt['acknowledgedAt'] is! int || receipt['acknowledgedAt'] < 0 ||
        receipt['requestDigest'] != requestDigest) {
      _changed.add(key);
      throw StateError('本机结束记录尚未确认，请重新打开核对。');
    }
    _snapshots[key] = null;
  }

  Future<void> delete({required String key}) => _finish(key, terminal: false);
  Future<void> finishTerminal(String slot) => _finish(slot, terminal: true);
}
