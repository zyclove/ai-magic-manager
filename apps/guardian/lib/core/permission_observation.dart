import 'package:device_operations/permission_observation_view.dart';
export 'package:device_operations/permission_observation_view.dart';
import 'api.dart';
import 'observation.dart' show validObservationReason;

final _package = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$');
final _id = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false);
Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_PERMISSION_OBSERVATION_RESPONSE');

T _decode<T>(T Function() parse) {
  try {
    return parse();
  } on PermissionViewException {
    _invalid();
  }
}

PermissionObservationSettings _settings(
        dynamic raw, String device, String registration) =>
    _decode(
        () => PermissionObservationSettings.parse(raw, device, registration));
PermissionInventory _inventory(
        dynamic raw, String device, String registration) =>
    _decode(() => PermissionInventory.parse(raw, device, registration));
PermissionObservationResult _result(
        dynamic raw, String device, String registration, String package) =>
    _decode(() =>
        PermissionObservationResult.parse(raw, device, registration, package));

class PermissionObservationRepository {
  final Api api;
  final String root, deviceId, registrationId;
  final bool Function() current;
  PermissionObservationRepository(
      {required this.api,
      required this.root,
      required this.deviceId,
      required this.registrationId,
      required this.current}) {
    if (!root.startsWith('/tenants/') ||
        !_id.hasMatch(root.substring(9)) ||
        !_id.hasMatch(deviceId) ||
        !_id.hasMatch(registrationId)) {
      throw ArgumentError('Invalid permission observation scope');
    }
  }
  String get _path => '$root/devices/$deviceId';
  void _current() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<dynamic> _send(String method, String path,
      {Json? body, int? version, String? key}) async {
    _current();
    try {
      final result =
          await api.send(method, path, body: body, version: version, key: key);
      _current();
      return result;
    } on ApiFailure catch (failure) {
      _current();
      if (failure.status == 404) {
        throw const ApiFailure(404, 'PERMISSION_BACKEND_UNAVAILABLE');
      }
      rethrow;
    }
  }

  Future<PermissionObservationSettings> settings() async => _settings(
      await _send('GET', '$_path/permission-observation-settings'),
      deviceId,
      registrationId);

  Future<PermissionObservationSettings> update(
      PermissionObservationSettings before,
      bool enabled,
      String reason,
      String key) async {
    if (before.deviceId != deviceId ||
        before.registrationId != registrationId ||
        !validObservationReason(reason)) {
      throw const ApiFailure(400, 'VALIDATION_FAILED');
    }
    final value = _settings(
        await _send('PUT', '$_path/permission-observation-settings',
            body: {'enabled': enabled, 'reason': reason.trim()},
            version: before.version,
            key: key),
        deviceId,
        registrationId);
    if (value.version != before.version + 1 || value.enabled != enabled) {
      _invalid();
    }
    return value;
  }

  Future<PermissionInventory> inventory() async => _inventory(
      await _send('GET', '$_path/application-inventory'),
      deviceId,
      registrationId);

  Future<PermissionObservationResult> read(String packageName) async {
    if (packageName.length > 255 || !_package.hasMatch(packageName)) {
      throw const ApiFailure(400, 'INVALID_PACKAGE_NAME');
    }
    final before = await settings();
    final raw = await _send('GET',
        '$_path/permission-observations?packageName=${Uri.encodeQueryComponent(packageName)}');
    final result = _result(raw, deviceId, registrationId, packageName);
    final after = await settings();
    if (before.version != after.version || before.enabled != after.enabled) {
      throw const ApiFailure(409, 'PERMISSION_VIEW_CHANGED');
    }
    return result;
  }
}
