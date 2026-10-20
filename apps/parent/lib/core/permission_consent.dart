import 'dart:convert';
import 'package:device_observation/device_observation.dart';
import 'package:flutter/foundation.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
import 'operation_journal.dart';
import 'operation_result_terminal.dart';
import 'observation_settings.dart' show validConsentReason;

/// 单设备、原管理员、原租户的加密操作记录。查询从不重放授权变更。
class PermissionChangeStore {
  late final ParentOperationJournal journal = ParentOperationJournal(storage);
  final ParentDurableStorage storage;
  PermissionChangeStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor, String device) =>
      'parent.pending.permission.$tenant.$actor.$device';
  Future<Json?> load(String tenant, String actor, String device) async {
    final raw = await journal.read(key: _key(tenant, actor, device));
    if (raw == null) return null;
    if (raw.length > 8192) throw const FormatException('授权恢复记录过大。');
    final value = jsonDecode(raw);
    if (value is! Json ||
        value.length != 3 ||
        value['requestId'] is! String ||
        !Uuid.isValidUUID(fromString: value['requestId']) ||
        value['createdAt'] is! int ||
        value['createdAt'] <= 0 ||
        value['body'] is! Json) {
      throw const FormatException('授权恢复记录无效，请联系管理员。');
    }
    validatePermissionChange(value['body']);
    return value;
  }

  Future<void> save(
      String tenant, String actor, String device, Json value) async {
    if (await load(tenant, actor, device) != null) {
      throw StateError('请先核对原授权操作。');
    }
    await journal.write(
        key: _key(tenant, actor, device), value: jsonEncode(value));
  }

  Future<void> remove(
      String tenant, String actor, String device, String request) async {
    final original = await load(tenant, actor, device);
    if (original != null && original['requestId'] != request) {
      throw StateError('原操作记录已变化。');
    }
    await journal.delete(key: _key(tenant, actor, device));
  }
}

void validatePermissionChange(Json input) {
  if (input.length != 4 ||
      input['registrationId'] is! String ||
      !Uuid.isValidUUID(fromString: input['registrationId']) ||
      input['version'] is! int ||
      input['version'] < 0 ||
      input['version'] >= 9007199254740991 ||
      input['enabled'] is! bool ||
      input['reason'] is! String ||
      !validConsentReason(input['reason'])) {
    throw const FormatException('请核对设备注册、授权版本和变更原因。');
  }
}

/// MFA → 原注册和版本预检 → 安全落盘 → 单次提交 → 原结果只读查询。
/// 网络结果不确定时保留原记录；不会在重新打开、恢复前台或查询时重发写入。
class ParentPermissionConsent extends ChangeNotifier with ParentTerminalOperation {
  @override
  ParentOperationJournal get operationJournal => store.journal;
  @override
  String get operationSlot => store._key(tenant, actor, target.deviceId);
  @override
  Json? get operationPayload => pending;
  @override
  bool get operationCurrent => available;
  @override
  bool get operationHasSuccessfulResult => committed != null;
  @override
  void forgetOperationPayload() {
    pending = null;
    settings = null;
    committed = null;
    queried = false;
    loaded = false;
  }
  final ParentApi api;
  final PermissionChangeStore store;
  final String tenant, actor;
  final UsageReportTarget target;
  final bool Function() isCurrent, foreground;
  final Future<bool> Function() reauthenticate;
  bool busy = false, loaded = false, queried = false, _disposed = false;
  int _generation = 0;
  Json? pending;
  PermissionObservationAuthorization? settings, committed;
  Object? error;
  ParentPermissionConsent(
      {required this.api,
      required this.store,
      required this.tenant,
      required this.actor,
      required this.target,
      required this.isCurrent,
      required this.foreground,
      required this.reauthenticate}) {
    if (!target.valid) throw ArgumentError('Invalid observation target');
  }
  String get path =>
      '/tenants/$tenant/devices/${target.deviceId}/permission-observation-settings';
  bool get current => !_disposed && isCurrent();
  bool get available => current && foreground();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _check() {
    if (!available) throw const ParentApiException(409, 'SCOPE_DENIED');
  }

  PermissionObservationAuthorization _parse(dynamic raw,
      {String? registration}) {
    try {
      if (raw is! Json) throw const FormatException();
      return PermissionObservationAuthorization.parse(
          raw,
          ObservationScope(
              tenant, target.deviceId, registration ?? target.registrationId));
    } catch (_) {
      throw const ParentApiException(502, 'INVALID_OBSERVATION_RESPONSE');
    }
  }

  Future<void> _device() async {
    _check();
    final d = await api.object('/tenants/$tenant/devices/${target.deviceId}',
        isCurrent: () => available);
    _check();
    if (d['id'] != target.deviceId ||
        d['registrationId'] != target.registrationId ||
        d['subjectId'] != target.subjectId ||
        d['platform'] != target.platform ||
        d['state'] != 'ACTIVE') {
      throw const ParentApiException(409, 'REGISTRATION_CHANGED');
    }
  }

  Future<PermissionObservationAuthorization> _read() async {
    await _device();
    final raw = await api.send('GET', path, isCurrent: () => available);
    _check();
    return _parse(raw);
  }

  Future<void> load() async {
    if (!available || busy) return;
    final generation = ++_generation;
    busy = true;
    loaded = false;
    queried = false;
    error = null;
    settings = null;
    committed = null;
    _notify();
    try {
      final saved = await store.load(tenant, actor, target.deviceId);
      if (!available || generation != _generation) return;
      pending = saved;
      final now = await _read();
      if (available && generation == _generation) {
        settings = now;
        loaded = true;
      }
    } catch (e) {
      await captureResultTerminal(e);
      if (available && generation == _generation) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> submit({required bool enabled, required String reason}) async {
    if (operationBlocked) return;
    if (!available || busy || !loaded || pending != null || settings == null) {
      return;
    }
    final before = settings!;
    busy = true;
    error = null;
    committed = null;
    queried = false;
    _notify();
    try {
      final body = <String, dynamic>{
        'registrationId': target.registrationId,
        'version': before.version,
        'enabled': enabled,
        'reason': reason.trim()
      };
      validatePermissionChange(body);
      if (!await reauthenticate() || !available) return;
      final generation = _generation;
      final now = await _read();
      if (now.version != before.version || now.enabled != before.enabled) {
        throw const ParentApiException(412, 'RESOURCE_VERSION_CONFLICT');
      }
      _check();
      if (generation != _generation) return;
      final marker = <String, dynamic>{
        'requestId': const Uuid().v4(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'body': body
      };
      await store.save(tenant, actor, target.deviceId, marker);
      // Retain durable evidence even if access changed during the storage barrier.
      if (!available || generation != _generation) return;
      pending = marker;
      settings = null;
      loaded = false;
      _notify();
      final raw = await api.send('POST', '$path/changes',
          body: body,
          idempotencyKey: marker['requestId'],
          isCurrent: () => available && generation == _generation, beforeDispatch: operationBeforeWrite);
      if (!available || generation != _generation) return;
      committed = _validateCommitted(raw, body);
      await recordSuccessfulOperation();
      // Even a successful write response can be a historical replay. Read both facts.
      await _recover(generation);
    } catch (e) {
      await captureResultTerminal(e);
      if (available) {
        error = e;
        settings = null;
        loaded = false;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  PermissionObservationAuthorization _validateCommitted(
      dynamic raw, Json input) {
    final value = _parse(raw, registration: input['registrationId']);
    if (value.version != input['version'] + 1 ||
        value.enabled != input['enabled']) {
      throw const ParentApiException(502, 'INVALID_OBSERVATION_RESPONSE');
    }
    return value;
  }

  Future<void> _recover(int generation) async {
    final record = pending!;
    await _device();
    if (!available || generation != _generation) return;
    final raw = await api.send(
        'POST', '$path/operation-results/${record['requestId']}/query',
        body: record['body'],
        isCurrent: () => available && generation == _generation, beforeDispatch: operationBeforeDispatch);
    if (!available || generation != _generation) return;
    if (raw is! Json || raw.length != 2) {
      throw const ParentApiException(502, 'INVALID_OBSERVATION_RESPONSE');
    }
    final original = _validateCommitted(raw['committed'], record['body']);
    final now =
        _parse(raw['current'], registration: record['body']['registrationId']);
    if (now.version < original.version) {
      throw const ParentApiException(502, 'INVALID_OBSERVATION_RESPONSE');
    }
    committed = original;
    settings = now;
    queried = true;
    if (operationHasSuccessfulResult) await recordSuccessfulOperation();
  }

  Future<void> query() async {
    if (operationBlocked) return;
    if (!available || busy || pending == null) return;
    final generation = ++_generation;
    busy = true;
    error = null;
    committed = null;
    settings = null;
    queried = false;
    _notify();
    try {
      await _recover(generation);
    } on ParentApiException catch (e) {
      await captureResultTerminal(e);
      if (available && generation == _generation) {
        error = e;
        // Terminal evidence still requires explicit local acknowledgement. Never replay a 410.
        queried =
            (e.status == 404 && e.code == 'OBSERVATION_RESULT_UNAVAILABLE') ||
                (e.status == 409 &&
                    const {'REGISTRATION_CHANGED', 'DEVICE_NOT_ACTIVE'}
                        .contains(e.code));
      }
    } catch (e) {
      await captureResultTerminal(e);
      if (available && generation == _generation) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> acknowledge() async {
    if (operationBlocked) return;
    if (!available || busy || !queried || pending == null) return;
    busy = true;
    error = null;
    _notify();
    try {
      await store.remove(tenant, actor, target.deviceId, pending!['requestId']);
      if (!available) return;
      pending = null;
      committed = null;
      settings = null;
      loaded = false;
      queried = false;
    } catch (e) {
      await captureResultTerminal(e);
      if (available) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  void hide() {
    _generation++;
    settings = null;
    committed = null;
    loaded = false;
    queried = false;
    error = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
