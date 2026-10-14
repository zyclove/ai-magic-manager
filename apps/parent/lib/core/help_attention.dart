import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:notification_client/help_attention.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
export 'package:notification_client/help_attention.dart';

HelpAttention parseHelp(Object? raw) {
  try {
    return HelpAttention.parse(raw);
  } on FormatException {
    throw const ParentApiException(502, 'INVALID_HELP_RESPONSE');
  }
}

/// One unresolved acknowledgement per workspace/actor. Only original references
/// are persisted; no nickname, help content, token or contact information.
class HelpAttentionStore {
  final ParentDurableStorage storage;
  HelpAttentionStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor) =>
      'parent.help.pending.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final raw = await storage.read(key: _key(tenant, actor));
    if (raw == null) return null;
    if (raw.length > 2048) throw const FormatException('求助恢复记录过大，请联系管理员。');
    final value = jsonDecode(raw);
    if (value is! Json ||
        value.length != 7 ||
        ['id', 'subjectId', 'deviceId', 'clientRequestId']
            .any((k) => !validHelpId(value[k])) ||
        value['version'] is! int ||
        value['version'] < 0 ||
        value['version'] >= 9007199254740991 ||
        value['createdAt'] is! int ||
        value['createdAt'] < 0 ||
        !const {'NEED_HELP', 'UNCOMFORTABLE_CONTENT', 'DEVICE_PROBLEM'}
            .contains(value['reasonCode'])) {
      throw const FormatException('求助恢复记录无效，请联系管理员。');
    }
    return value;
  }

  Future<void> save(String tenant, String actor, HelpAttention value) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对原求助记录。');
    await storage.write(
        key: _key(tenant, actor),
        value: jsonEncode({
          'id': value.id,
          'subjectId': value.subjectId,
          'deviceId': value.deviceId,
          'clientRequestId': value.clientRequestId,
          'version': value.version,
          'reasonCode': value.reasonCode,
          'createdAt': value.createdAt,
        }));
  }

  Future<void> remove(String tenant, String actor, String id) async {
    final original = await load(tenant, actor);
    if (original != null && original['id'] != id) throw StateError('待核对求助已变化。');
    await storage.delete(key: _key(tenant, actor));
  }
}

/// Preflight + durable reference + one POST. Unknown outcomes are reconciled by
/// reading the same request; no resume, refresh or query repeats a write.
class ParentHelpDetail extends ChangeNotifier {
  final ParentApi api;
  final HelpAttentionStore store;
  final String tenant, actor, id;
  final bool Function() isCurrent, foreground;
  bool busy = false, queried = false, loaded = false, _disposed = false;
  int _epoch = 0;
  HelpAttention? request;
  Json? pending;
  Object? error;
  ParentHelpDetail(
      {required this.api,
      required this.store,
      required this.tenant,
      required this.actor,
      required this.id,
      required this.isCurrent,
      required this.foreground}) {
    if (!validHelpId(id)) throw ArgumentError('Invalid help reference');
  }
  bool get available => !_disposed && isCurrent() && foreground();
  bool valid(int epoch) => available && epoch == _epoch;
  String get path => '/tenants/$tenant/help-requests/$id';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<HelpAttention> _read(int epoch) async {
    final value =
        parseHelp(await api.object(path, isCurrent: () => valid(epoch)));
    if (!valid(epoch)) throw const ParentApiException(409, 'SCOPE_DENIED');
    if (value.id != id) {
      throw const ParentApiException(502, 'INVALID_HELP_RESPONSE');
    }
    if (pending != null &&
        pending!['id'] == id &&
        (value.subjectId != pending!['subjectId'] ||
            value.deviceId != pending!['deviceId'] ||
            value.clientRequestId != pending!['clientRequestId'] ||
            value.createdAt != pending!['createdAt'] ||
            value.reasonCode != pending!['reasonCode'] ||
            value.version < pending!['version'])) {
      throw const ParentApiException(502, 'INVALID_HELP_RESPONSE');
    }
    return value;
  }

  Future<void> load() async {
    if (!available || busy) return;
    final epoch = ++_epoch;
    busy = true;
    error = null;
    request = null;
    queried = false;
    loaded = false;
    _notify();
    try {
      final saved = await store.load(tenant, actor);
      if (!valid(epoch)) return;
      pending = saved;
      final value = await _read(epoch);
      if (!valid(epoch)) return;
      request = value;
      loaded = true;
      queried = pending?['id'] == id;
    } catch (e) {
      if (valid(epoch)) {
        error = e;
        queried = pending?['id'] == id &&
            e is ParentApiException &&
            e.status == 404 &&
            e.code == 'HELP_REQUEST_UNAVAILABLE';
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> acknowledge() async {
    final before = request;
    if (!available ||
        busy ||
        !loaded ||
        pending != null ||
        before == null ||
        before.state != 'OPEN') return;
    final epoch = ++_epoch;
    busy = true;
    queried = false;
    error = null;
    _notify();
    try {
      final now = await _read(epoch);
      if (!valid(epoch)) return;
      if (!before.sameRequest(now) ||
          now.version != before.version ||
          now.state != 'OPEN') {
        request = now;
        throw const ParentApiException(409, 'HELP_REQUEST_VERSION_CHANGED');
      }
      await store.save(tenant, actor, before);
      if (!valid(epoch)) return;
      pending = await store.load(tenant, actor);
      if (!valid(epoch)) return;
      if (pending == null || pending!['id'] != id) {
        throw const ParentApiException(409, 'HELP_PENDING_CHANGED');
      }
      request = null;
      loaded = false;
      _notify();
      final value = parseHelp(await api.send('POST', '$path/acknowledge',
          version: before.version, isCurrent: () => valid(epoch)));
      if (!valid(epoch)) return;
      if (!before.sameRequest(value) ||
          value.state != 'ACKNOWLEDGED' ||
          value.version != before.version + 1) {
        throw const ParentApiException(502, 'INVALID_HELP_RESPONSE');
      }
      // The exact successful receipt is enough to finish the normal flow. Only
      // uncertain outcomes retain a visible recovery step.
      await store.remove(tenant, actor, id);
      if (!valid(epoch)) return;
      request = value;
      loaded = true;
      queried = false;
      pending = null;
    } catch (e) {
      if (valid(epoch)) {
        error = e;
        loaded = false;
        request = null;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> clearPending() async {
    if (!available || busy || !queried || pending?['id'] != id) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      await store.remove(tenant, actor, id);
      if (valid(epoch)) {
        pending = null;
        queried = false;
      }
    } catch (e) {
      if (valid(epoch)) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  void hide() {
    _epoch++;
    request = null;
    error = null;
    queried = false;
    loaded = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}
