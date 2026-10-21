import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'family.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

Never _badDeviceAccess() =>
    throw const ParentApiException(502, 'INVALID_RESPONSE');
String _text(dynamic value) =>
    value is String && value.isNotEmpty ? value : _badDeviceAccess();
String _id(dynamic value) =>
    value is String && Uuid.isValidUUID(fromString: value)
        ? value
        : _badDeviceAccess();
int _integer(dynamic value) =>
    value is int && value >= 0 && value <= 9007199254740991
        ? value
        : _badDeviceAccess();

class FamilyAccessDevice {
  final String id,
      registrationId,
      displayName,
      subjectId,
      subjectName,
      state,
      access;
  final int createdAt;
  final bool selected, canSelect;
  FamilyAccessDevice.fromJson(Json value)
      : id = _id(value['id']),
        registrationId = _id(value['registrationId']),
        displayName = _text(value['displayName']),
        subjectId = _id(value['subjectId']),
        subjectName = _text(value['subjectName']),
        state = _text(value['state']),
        access = _text(value['access']),
        createdAt = _integer(value['createdAt']),
        selected =
            value['selected'] is bool ? value['selected'] : _badDeviceAccess(),
        canSelect = value['canSelect'] is bool
            ? value['canSelect']
            : _badDeviceAccess() {
    if (!{'ACTIVE', 'AWAITING_CONFIRMATION'}.contains(state) ||
        !{'BASIC', 'MEMBER', 'GRACE', 'RECOVERY_ONLY'}.contains(access) ||
        canSelect && state != 'ACTIVE') _badDeviceAccess();
  }
}

class FamilyDeviceAccessSnapshot {
  final String tenantId, status;
  final int version, effectiveDeviceLimit, activeCount;
  final int? graceEndsAt;
  final String? selectedDeviceId, selectedRegistrationId;
  final List<FamilyAccessDevice> devices;
  FamilyDeviceAccessSnapshot.fromJson(Json value)
      : tenantId = _text(value['tenantId']),
        status = _text(value['status']),
        version = _integer(value['version']),
        effectiveDeviceLimit = _integer(value['effectiveDeviceLimit']),
        activeCount = _integer(value['activeCount']),
        graceEndsAt = value['graceEndsAt'] == null
            ? null
            : _integer(value['graceEndsAt']),
        selectedDeviceId = value['selectedDeviceId'] == null
            ? null
            : _id(value['selectedDeviceId']),
        selectedRegistrationId = value['selectedRegistrationId'] == null
            ? null
            : _id(value['selectedRegistrationId']),
        devices = List.unmodifiable(value['devices'] is List
            ? (value['devices'] as List).map((v) =>
                FamilyAccessDevice.fromJson(v is Json ? v : _badDeviceAccess()))
            : _badDeviceAccess()) {
    if (!{'FREE', 'PAID', 'GRACE', 'EXPIRED'}.contains(status) ||
        !{1, 3}.contains(effectiveDeviceLimit) ||
        status == 'GRACE' && graceEndsAt == null ||
        (selectedDeviceId == null) != (selectedRegistrationId == null) ||
        devices.map((d) => d.id).toSet().length != devices.length ||
        devices.where((d) => d.selected).length > 1 ||
        devices.any((d) =>
            d.selected &&
            (d.id != selectedDeviceId ||
                d.registrationId != selectedRegistrationId)) ||
        selectedDeviceId != null &&
            !devices.any((d) =>
                d.id == selectedDeviceId &&
                d.registrationId == selectedRegistrationId &&
                d.selected)) {
      _badDeviceAccess();
    }
  }
  FamilyAccessDevice? get retainedDevice {
    for (final d in devices) {
      if (d.selected) return d;
    }
    return null;
  }
}

/// One original choice per actor/family. No names or bearer tokens enter the journal.
class FamilyDeviceSelectionCoordinator {
  final FamilyService service;
  final String actor;
  final ParentDurableStorage storage;
  FamilyDeviceAccessSnapshot? snapshot;
  Json? pending;
  bool loaded = false, busy = false;
  FamilyDeviceSelectionCoordinator(
      {required this.service,
      required this.actor,
      ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String get _storageKey =>
      'parent.family.device-selection.${service.tenantId}.$actor';

  Future<void> load() async {
    service.check();
    if (busy) throw StateError('正在核对设备选择，请稍候。');
    busy = true;
    loaded = false;
    snapshot = null;
    try {
      final raw = await storage.read(key: _storageKey);
      service.check();
      if (raw != null) {
        if (raw.length > 4096) throw const FormatException('原设备选择记录无法读取。');
        final value = jsonDecode(raw);
        if (value is! Json ||
            value.length != 5 ||
            value.keys.toSet().difference({
              'key',
              'deviceId',
              'registrationId',
              'version',
              'createdAt'
            }).isNotEmpty ||
            value['key'] is! String ||
            !Uuid.isValidUUID(fromString: value['key']) ||
            value['deviceId'] is! String ||
            !Uuid.isValidUUID(fromString: value['deviceId']) ||
            value['registrationId'] is! String ||
            !Uuid.isValidUUID(fromString: value['registrationId']) ||
            value['version'] is! int ||
            value['version'] < 0 ||
            value['createdAt'] is! int ||
            value['createdAt'] < 0) {
          throw const FormatException('原设备选择记录无法读取，请通过帮助入口处理。');
        }
        pending = Map<String, dynamic>.unmodifiable(value);
      } else {
        pending = null;
      }
      final state = FamilyDeviceAccessSnapshot.fromJson(
          await service.object('/family-device-access'));
      if (state.tenantId != service.tenantId) _badDeviceAccess();
      service.check();
      snapshot = state;
      loaded = true;
    } finally {
      busy = false;
    }
  }

  Future<FamilyDeviceAccessSnapshot> select(
      String deviceId, String registrationId) async {
    service.check();
    if (!loaded || busy || pending != null || snapshot == null) {
      throw StateError('请先核对当前设备和原操作。');
    }
    if (snapshot!.status == 'PAID' ||
        !snapshot!.devices.any((d) =>
            d.id == deviceId &&
            d.registrationId == registrationId &&
            d.canSelect)) {
      throw StateError('设备状态已变化，请重新读取。');
    }
    busy = true;
    try {
      final command = {
        'key': const Uuid().v4(),
        'deviceId': deviceId,
        'registrationId': registrationId,
        'version': snapshot!.version,
        'createdAt': DateTime.now().millisecondsSinceEpoch
      };
      // A failed durability barrier may still have saved the original command.
      // Invalidate the loaded state until a read proves what is on disk.
      loaded = false;
      await storage.write(key: _storageKey, value: jsonEncode(command));
      service.check();
      pending = Map<String, dynamic>.unmodifiable(command);
      loaded = true;
      return await _send();
    } finally {
      busy = false;
    }
  }

  Future<FamilyDeviceAccessSnapshot> retry() async {
    service.check();
    if (!loaded || busy || pending == null) throw StateError('请先读取并核对原选择。');
    busy = true;
    try {
      return await _send();
    } finally {
      busy = false;
    }
  }

  Future<FamilyDeviceAccessSnapshot> _send() async {
    service.check();
    final original = pending!;
    try {
      final result = FamilyDeviceAccessSnapshot.fromJson(await service.write(
          'PUT', '/family-device-access/selection',
          body: {
            'deviceId': original['deviceId'],
            'registrationId': original['registrationId']
          },
          version: original['version'],
          idempotencyKey: original['key']));
      if (result.tenantId != service.tenantId ||
          result.selectedDeviceId != original['deviceId'] ||
          result.selectedRegistrationId != original['registrationId']) {
        _badDeviceAccess();
      }
      await storage.delete(key: _storageKey);
      service.check();
      pending = null;
      snapshot = result;
      return result;
    } on ParentApiException catch (error) {
      if (error.status >= 400 &&
          error.status < 500 &&
          error.status != 401 &&
          error.status != 403 &&
          error.status != 408 &&
          !{'IDEMPOTENCY_IN_PROGRESS', 'UNAUTHENTICATED', 'SCOPE_DENIED'}
              .contains(error.code)) {
        service.check();
        await storage.delete(key: _storageKey);
        service.check();
        pending = null;
        snapshot = null;
        loaded = false;
      }
      rethrow;
    }
  }
}
