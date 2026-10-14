import 'package:device_operations/permission_observation_view.dart';
import 'package:device_observation/device_observation.dart'
    show ObservationAuthorization, ObservationScope, ObservationFailure;
import 'package:flutter/foundation.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'parent_api.dart';

export 'package:device_operations/permission_observation_view.dart';

const permissionObservationEnabled =
    bool.fromEnvironment('PERMISSION_OBSERVATION_ENABLED', defaultValue: false);

/// Short-lived, registration-scoped views. No application or permission facts are
/// persisted. Read authorization on both sides of each projection request.
class ParentPermissionView extends ChangeNotifier {
  final ParentApi api;
  final String tenant;
  final UsageReportTarget target;
  final bool Function() isCurrent, foreground;
  bool busy = false, _disposed = false;
  int _generation = 0;
  PermissionObservationSettings? settings;
  PermissionInventory? inventory;
  PermissionObservationResult? result;
  PermissionCandidate? selected;
  Object? error;
  ParentPermissionView(
      {required this.api,
      required this.tenant,
      required this.target,
      required this.isCurrent,
      required this.foreground}) {
    if (!target.valid) throw ArgumentError('Invalid permission target');
  }
  String get root => '/tenants/$tenant/devices/${target.deviceId}';
  bool get available => !_disposed && isCurrent() && foreground();
  bool _valid(int epoch) => available && epoch == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<Json> _read(String path, int epoch) async {
    if (!_valid(epoch)) throw const ParentApiException(409, 'SCOPE_DENIED');
    late Json value;
    try {
      value = await api.object(path, isCurrent: () => _valid(epoch));
    } on ParentApiException catch (e) {
      if (e.status == 404 &&
          path.endsWith('/permission-observation-settings')) {
        throw ParentApiException(
            404, 'PERMISSION_BACKEND_UNAVAILABLE', e.correlationId);
      }
      rethrow;
    }
    if (!_valid(epoch)) throw const ParentApiException(409, 'SCOPE_DENIED');
    return value;
  }

  Future<void> _device(int epoch) async {
    final d = await _read(root, epoch);
    if (d['id'] != target.deviceId ||
        d['registrationId'] != target.registrationId ||
        d['subjectId'] != target.subjectId ||
        d['platform'] != target.platform ||
        d['state'] != 'ACTIVE') {
      throw const ParentApiException(409, 'REGISTRATION_CHANGED');
    }
  }

  Future<(PermissionObservationSettings, ObservationAuthorization)> _consents(
      int epoch) async {
    final permission = PermissionObservationSettings.parse(
        await _read('$root/permission-observation-settings', epoch),
        target.deviceId,
        target.registrationId);
    final common = ObservationAuthorization.parse(
        await _read('$root/observation-settings', epoch),
        ObservationScope(tenant, target.deviceId, target.registrationId));
    return (permission, common);
  }

  Future<void> load({PermissionCandidate? app}) async {
    if (!available || busy) return;
    if (app != null &&
        !(inventory?.applications.any((v) =>
                v.packageName == app.packageName && v.profile == app.profile) ??
            false)) {
      error = const ParentApiException(409, 'INVALID_PERMISSION_SELECTION');
      _notify();
      return;
    }
    final epoch = ++_generation;
    busy = true;
    error = null;
    result = null;
    settings = null;
    selected = app;
    inventory = null;
    _notify();
    try {
      await _device(epoch);
      final before = await _consents(epoch);
      PermissionInventory? catalog;
      PermissionObservationResult? view;
      if (before.$1.enabled && before.$2.inventoryEnabled) {
        catalog = PermissionInventory.parse(
            await _read('$root/application-inventory', epoch),
            target.deviceId,
            target.registrationId);
        if (app != null) {
          if (!catalog.applications.any((v) =>
              v.packageName == app.packageName && v.profile == app.profile)) {
            throw const ParentApiException(409, 'INVALID_PERMISSION_SELECTION');
          }
          view = PermissionObservationResult.parse(
              await _read(
                  '$root/permission-observations?packageName=${Uri.encodeQueryComponent(app.packageName)}',
                  epoch),
              target.deviceId,
              target.registrationId,
              app.packageName);
          // The endpoint is package-scoped; never assign another profile's fact to this row.
          if (view.profile != null && view.profile != app.profile) {
            throw const ParentApiException(409, 'PERMISSION_PROFILE_MISMATCH');
          }
        }
      }
      final after = await _consents(epoch);
      await _device(epoch);
      if (before.$1.version != after.$1.version ||
          before.$1.enabled != after.$1.enabled ||
          before.$2.version != after.$2.version ||
          before.$2.inventoryEnabled != after.$2.inventoryEnabled) {
        throw const ParentApiException(409, 'PERMISSION_VIEW_CHANGED');
      }
      if (!_valid(epoch)) return;
      settings = after.$1;
      inventory = catalog;
      result = view;
    } catch (e) {
      if (_valid(epoch)) {
        error = e is PermissionViewException || e is ObservationFailure
            ? const ParentApiException(
                502, 'INVALID_PERMISSION_OBSERVATION_RESPONSE')
            : e;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  void hide() {
    _generation++;
    settings = null;
    inventory = null;
    result = null;
    selected = null;
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
