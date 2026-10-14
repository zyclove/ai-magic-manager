import 'package:flutter/foundation.dart';
import 'api.dart';

enum DeviceManagementSection { overview, capabilities, applications }

const _maximumInteger = 9007199254740991;
final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _control = RegExp(r'[\x00-\x1f\x7f-\x9f]');
Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_DEVICE_MANAGEMENT_RESPONSE');
Json _object(Object? value, Set<String> fields) {
  if (value is! Json ||
      value.length != fields.length ||
      !value.keys.every(fields.contains)) _invalid();
  return value;
}

String _text(Object? value, {int maximum = 100}) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maximum ||
      _control.hasMatch(value)) _invalid();
  return value;
}

String _id(Object? value) {
  final text = _text(value, maximum: 36);
  if (!_uuid.hasMatch(text)) _invalid();
  return text;
}

String _choice(Object? value, Set<String> choices) {
  if (value is! String || !choices.contains(value)) _invalid();
  return value;
}

String _code(Object? value) {
  final text = _text(value, maximum: 100);
  if (!RegExp(r'^[A-Z][A-Z0-9_]{0,99}$').hasMatch(text)) _invalid();
  return text;
}

int _integer(Object? value) {
  if (value is! int || value < 0 || value > _maximumInteger) _invalid();
  return value;
}

int? _instant(Object? value) => value == null ? null : _integer(value);
bool _boolean(Object? value) {
  if (value is! bool) _invalid();
  return value;
}

class DeviceManagementRecord {
  final String id, subjectId, registrationId, displayName, platform, osVersion;
  final String state,
      managementMode,
      controlLevel,
      observationStatus,
      keyThumbprint;
  final int version;
  final int? lastHeartbeatAt;
  const DeviceManagementRecord(
      {required this.id,
      required this.subjectId,
      required this.registrationId,
      required this.displayName,
      required this.platform,
      required this.osVersion,
      required this.state,
      required this.managementMode,
      required this.controlLevel,
      required this.observationStatus,
      required this.keyThumbprint,
      required this.version,
      this.lastHeartbeatAt});

  factory DeviceManagementRecord.fromJson(Object? value,
      {required String deviceId}) {
    final json = _object(value, {
      'id',
      'subjectId',
      'registrationId',
      'displayName',
      'platform',
      'osVersion',
      'state',
      'managementMode',
      'controlLevel',
      'observationStatus',
      'keyThumbprint',
      'version',
      'lastHeartbeatAt'
    });
    final id = _id(json['id']);
    if (id != deviceId) _invalid();
    final state =
        _choice(json['state'], {'AWAITING_CONFIRMATION', 'ACTIVE', 'REVOKED'});
    final mode = _choice(json['managementMode'], {'UNVERIFIED', 'BYOD'});
    final control = _choice(json['controlLevel'], {'NONE', 'LIMITED'});
    final observation = _choice(
        json['observationStatus'], {'UNKNOWN', 'RECENT', 'STALE', 'REVOKED'});
    if (mode != (state == 'AWAITING_CONFIRMATION' ? 'UNVERIFIED' : 'BYOD') ||
        control != (state == 'ACTIVE' ? 'LIMITED' : 'NONE') ||
        (state == 'REVOKED') != (observation == 'REVOKED')) _invalid();
    final thumb = _text(json['keyThumbprint'], maximum: 43);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(thumb)) _invalid();
    return DeviceManagementRecord(
        id: id,
        subjectId: _id(json['subjectId']),
        registrationId: _id(json['registrationId']),
        displayName: _text(json['displayName']),
        platform: _choice(json['platform'], {'ANDROID', 'ANDROID_TV'}),
        osVersion: _text(json['osVersion']),
        state: state,
        managementMode: mode,
        controlLevel: control,
        observationStatus: observation,
        keyThumbprint: thumb,
        version: _integer(json['version']),
        lastHeartbeatAt: _instant(json['lastHeartbeatAt']));
  }

  Json toJson() => {
        'id': id,
        'subjectId': subjectId,
        'registrationId': registrationId,
        'displayName': displayName,
        'platform': platform,
        'osVersion': osVersion,
        'state': state,
        'managementMode': managementMode,
        'controlLevel': controlLevel,
        'observationStatus': observationStatus,
        'keyThumbprint': keyThumbprint,
        'version': version,
        'lastHeartbeatAt': lastHeartbeatAt
      };
}

class DeviceManagementCapability {
  final String key, status, grantStatus, evidenceSource, limitationCode;
  final bool reportedSupported, effectiveSupported;
  final int? checkedAt;
  const DeviceManagementCapability(
      {required this.key,
      required this.status,
      required this.grantStatus,
      required this.evidenceSource,
      required this.limitationCode,
      required this.reportedSupported,
      required this.effectiveSupported,
      this.checkedAt});
}

class DeviceManagementCapabilities {
  final List<DeviceManagementCapability> items;
  DeviceManagementCapabilities(Iterable<DeviceManagementCapability> items)
      : items = List.unmodifiable(items);
  factory DeviceManagementCapabilities.fromJson(Object? value) {
    final json = _object(value, {'items'}), raw = json['items'];
    if (raw is! List || raw.length > 128) _invalid();
    final keys = <String>{};
    final items = <DeviceManagementCapability>[];
    for (final item in raw) {
      final entry = _object(item, {
        'key',
        'status',
        'grantStatus',
        'evidenceSource',
        'limitationCode',
        'reportedSupported',
        'effectiveSupported',
        'checkedAt'
      });
      final key = _text(entry['key']);
      if (!RegExp(r'^[a-z][a-z0-9_.]{1,99}$').hasMatch(key) || !keys.add(key)) {
        _invalid();
      }
      final status = _choice(
          entry['status'], {'UNSUPPORTED', 'STALE', 'UNVERIFIED', 'UNKNOWN'});
      final effective = _boolean(entry['effectiveSupported']);
      // This endpoint describes ordinary agent registrations. None of its
      // observations certifies effective operating-system control.
      if (effective) _invalid();
      items.add(DeviceManagementCapability(
          key: key,
          status: status,
          grantStatus: _code(entry['grantStatus']),
          evidenceSource: _code(entry['evidenceSource']),
          limitationCode: _code(entry['limitationCode']),
          reportedSupported: _boolean(entry['reportedSupported']),
          effectiveSupported: effective,
          checkedAt: _instant(entry['checkedAt'])));
    }
    return DeviceManagementCapabilities(items);
  }
  int get effectiveCount =>
      items.where((item) => item.effectiveSupported).length;
}

class DeviceManagementApplication {
  final String packageName, displayName, profile;
  final List<String> signingDigests;
  final int versionCode;
  final bool systemApplication;
  DeviceManagementApplication(
      {required this.packageName,
      required this.displayName,
      required this.profile,
      required Iterable<String> signingDigests,
      required this.versionCode,
      required this.systemApplication})
      : signingDigests = List.unmodifiable(signingDigests);
}

class DeviceManagementInventory {
  final String deviceId,
      registrationId,
      visibility,
      observationStatus,
      evidenceStatus;
  final int sequence;
  final int? receivedAt;
  final List<DeviceManagementApplication> applications;
  DeviceManagementInventory(
      {required this.deviceId,
      required this.registrationId,
      required this.visibility,
      required this.observationStatus,
      required this.evidenceStatus,
      required this.sequence,
      this.receivedAt,
      required Iterable<DeviceManagementApplication> applications})
      : applications = List.unmodifiable(applications);
  factory DeviceManagementInventory.fromJson(Object? value,
      {required String deviceId, required String registrationId}) {
    final json = _object(value, {
      'deviceId',
      'registrationId',
      'visibility',
      'observationStatus',
      'evidenceStatus',
      'sequence',
      'receivedAt',
      'applications'
    });
    if (_id(json['deviceId']) != deviceId ||
        _id(json['registrationId']) != registrationId) _invalid();
    final raw = json['applications'];
    if (raw is! List || raw.length > 500) _invalid();
    final visibility =
        _choice(json['visibility'], {'UNKNOWN', 'VISIBLE_PACKAGES'});
    final observed = _choice(json['observationStatus'],
        {'UNKNOWN', 'NOT_AUTHORIZED', 'RECENT', 'STALE', 'REVOKED'});
    final received = _instant(json['receivedAt']);
    if ((visibility == 'UNKNOWN' || observed == 'NOT_AUTHORIZED') &&
        raw.isNotEmpty) _invalid();
    if (raw.isNotEmpty && received == null) _invalid();
    final apps = <DeviceManagementApplication>[];
    final identities = <String>{};
    for (final item in raw) {
      final entry = _object(item, {
        'packageName',
        'displayName',
        'profile',
        'signingDigests',
        'versionCode',
        'systemApplication'
      });
      final package = _text(entry['packageName'], maximum: 255);
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
          .hasMatch(package)) _invalid();
      final profile = _choice(
          entry['profile'], {'PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'});
      if (!identities.add('$profile/$package')) _invalid();
      final rawDigests = entry['signingDigests'];
      if (rawDigests is! List || rawDigests.length > 8) _invalid();
      final digests = <String>{};
      for (final digest in rawDigests) {
        if (digest is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
            !digests.add(digest)) _invalid();
      }
      apps.add(DeviceManagementApplication(
          packageName: package,
          displayName: _text(entry['displayName']),
          profile: profile,
          signingDigests: digests,
          versionCode: _integer(entry['versionCode']),
          systemApplication: _boolean(entry['systemApplication'])));
    }
    return DeviceManagementInventory(
        deviceId: deviceId,
        registrationId: registrationId,
        visibility: visibility,
        observationStatus: observed,
        evidenceStatus:
            _choice(json['evidenceStatus'], {'AGENT_REPORTED_UNVERIFIED'}),
        sequence: _integer(json['sequence']),
        receivedAt: received,
        applications: apps);
  }
}

class DeviceManagementRepository {
  final Api api;
  final String root, deviceId;
  final bool Function() current;
  DeviceManagementRepository(
      {required this.api,
      required this.root,
      required this.deviceId,
      required this.current}) {
    if (!RegExp(r'^/tenants/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(root) ||
        !_uuid.hasMatch(deviceId)) {
      throw const ApiFailure(400, 'INVALID_DEVICE_ID');
    }
  }
  late final Api _bound = api.scoped(current);
  Future<DeviceManagementRecord> loadDevice(
          {bool Function()? isCurrent}) async =>
      DeviceManagementRecord.fromJson(
          await _bound.send('GET', '$root/devices/$deviceId',
              isCurrent: isCurrent),
          deviceId: deviceId);
  Future<DeviceManagementCapabilities> loadCapabilities(
      DeviceManagementRecord device,
      {bool Function()? isCurrent}) async {
    _target(device);
    return DeviceManagementCapabilities.fromJson(await _bound.send(
        'GET', '$root/devices/$deviceId/capabilities',
        isCurrent: isCurrent));
  }

  Future<DeviceManagementInventory> loadApplications(
      DeviceManagementRecord device,
      {bool Function()? isCurrent}) async {
    _target(device);
    return DeviceManagementInventory.fromJson(
        await _bound.send(
            'GET', '$root/devices/$deviceId/application-inventory',
            isCurrent: isCurrent),
        deviceId: deviceId,
        registrationId: device.registrationId);
  }

  Future<void> revoke(DeviceManagementRecord device,
      {bool Function()? isCurrent}) async {
    _target(device);
    if (device.state != 'ACTIVE') {
      throw const ApiFailure(409, 'DEVICE_NOT_ACTIVE');
    }
    final response = await _bound.send('POST', '$root/devices/$deviceId/revoke',
        isCurrent: isCurrent);
    if (response != null) _invalid();
  }

  void _target(DeviceManagementRecord device) {
    if (device.id != deviceId) _invalid();
  }
}

class DeviceManagementController extends ChangeNotifier {
  final DeviceManagementRepository repository;
  final bool canWrite, canReadApplications;
  DeviceManagementController(
      {required this.repository,
      required this.canWrite,
      required this.canReadApplications});
  DeviceManagementRecord? _device;
  (String, String, String, String)? _identity;
  DeviceManagementCapabilities? _capabilities;
  DeviceManagementInventory? _inventory;
  DeviceManagementSection _section = DeviceManagementSection.overview;
  Object? _error;
  DateTime? _updatedAt, _capabilitiesAt, _inventoryAt;
  bool _busy = false,
      _writeBusy = false,
      _scopeLost = false,
      _readDenied = false,
      _disposed = false;
  bool _revokeUnknown = false, _revokeAccepted = false;
  int _generation = 0;
  DeviceManagementRecord? get device => _device;
  DeviceManagementCapabilities? get capabilities => _capabilities;
  DeviceManagementInventory? get inventory => _inventory;
  DeviceManagementSection get section => _section;
  Object? get error => _error;
  DateTime? get updatedAt => _updatedAt;
  DateTime? get sectionUpdatedAt => switch (_section) {
        DeviceManagementSection.overview => _updatedAt,
        DeviceManagementSection.capabilities => _capabilitiesAt,
        DeviceManagementSection.applications => _inventoryAt
      };
  bool get busy => _busy;
  bool get writeBusy => _writeBusy;
  bool get hasAccess =>
      !_disposed && !_scopeLost && !_readDenied && repository.current();
  bool get revokeResultUnknown => _revokeUnknown;
  bool get revokeAcceptedAwaitingRead => _revokeAccepted;
  bool get canRevoke =>
      hasAccess &&
      canWrite &&
      !_busy &&
      !_revokeUnknown &&
      !_revokeAccepted &&
      _device?.state == 'ACTIVE';
  Future<void> initialize() => refresh();
  bool _current(int generation) => hasAccess && _generation == generation;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _clear({bool forgetIdentity = false}) {
    if (forgetIdentity) _identity = null;
    _device = null;
    _capabilities = null;
    _inventory = null;
    _updatedAt = null;
    _capabilitiesAt = null;
    _inventoryAt = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _clear(forgetIdentity: true);
    super.dispose();
  }

  void checkScope() {
    if (_disposed) return;
    if (!repository.current() && !_scopeLost) {
      _scopeLost = true;
      _generation++;
      _clear(forgetIdentity: true);
      _busy = false;
      _writeBusy = false;
      _error = const ApiFailure(409, 'WORKSPACE_CHANGED');
      _changed();
    }
  }

  void _readFailure(Object failure) {
    _error = failure;
    if (failure is ApiFailure) {
      if (failure.code == 'WORKSPACE_CHANGED') {
        checkScope();
      }
      if (failure.status == 401 || failure.status == 403) {
        _readDenied = true;
        _clear(forgetIdentity: true);
      }
      if (failure.code == 'INVALID_DEVICE_MANAGEMENT_RESPONSE') _clear();
    }
  }

  Future<void> _load(int generation) async {
    final next =
        await repository.loadDevice(isCurrent: () => _current(generation));
    if (!_current(generation)) return;
    final identity = (
      next.registrationId,
      next.subjectId,
      next.platform,
      next.keyThumbprint
    );
    if (_identity != null && _identity != identity) _invalid();
    _identity ??= identity;
    if (_device?.registrationId != next.registrationId ||
        _device?.version != next.version) {
      _capabilities = null;
      _inventory = null;
      _capabilitiesAt = null;
      _inventoryAt = null;
    }
    _device = next;
    _updatedAt = DateTime.now();
    if (next.state == 'REVOKED') {
      _revokeUnknown = false;
      _revokeAccepted = false;
    }
    switch (_section) {
      case DeviceManagementSection.overview:
        break;
      case DeviceManagementSection.capabilities:
        final result = await repository.loadCapabilities(next,
            isCurrent: () => _current(generation));
        if (!_current(generation)) return;
        _capabilities = result;
        _capabilitiesAt = DateTime.now();
        break;
      case DeviceManagementSection.applications:
        if (!canReadApplications) throw const ApiFailure(403, 'SCOPE_DENIED');
        final result = await repository.loadApplications(next,
            isCurrent: () => _current(generation));
        if (!_current(generation)) return;
        _inventory = result;
        _inventoryAt = DateTime.now();
        break;
    }
  }

  Future<void> refresh() async {
    if (_busy || !hasAccess) {
      checkScope();
      return;
    }
    final generation = ++_generation;
    _busy = true;
    _error = null;
    _changed();
    try {
      await _load(generation);
    } catch (failure) {
      if (_current(generation)) _readFailure(failure);
    } finally {
      if (!_disposed && _generation == generation) {
        _busy = false;
        _changed();
      }
    }
  }

  Future<void> selectSection(DeviceManagementSection value) async {
    if (_busy ||
        !hasAccess ||
        (value == DeviceManagementSection.applications &&
            !canReadApplications)) {
      return;
    }
    _section = value;
    await refresh();
  }

  Future<void> revoke(
      Future<bool> Function(DeviceManagementRecord) confirm) async {
    if (!canRevoke) return;
    final target = _device!, generation = ++_generation;
    bool submitted = false, accepted = false;
    _busy = true;
    _writeBusy = true;
    _error = null;
    _changed();
    try {
      if (!await confirm(target) || !_current(generation)) return;
      submitted = true;
      await repository.revoke(target, isCurrent: () => _current(generation));
      if (!_current(generation)) return;
      accepted = true;
      _revokeAccepted = true;
      await _load(generation);
    } catch (failure) {
      if (!_current(generation)) return;
      if (accepted) {
        _readFailure(failure);
      } else if (submitted &&
          (failure is! ApiFailure ||
              failure.status == 0 ||
              failure.status >= 500 ||
              failure.status == 408 ||
              failure.status == 429)) {
        _revokeUnknown = true;
        _error = const ApiFailure(0, 'DEVICE_REVOKE_RESULT_UNKNOWN');
      } else {
        _error = failure;
        if (failure is ApiFailure &&
            failure.code != 'REAUTH_REQUIRED' &&
            (failure.status == 401 || failure.status == 403)) {
          _readDenied = true;
          _clear();
        }
      }
    } finally {
      if (!_disposed && _generation == generation) {
        _busy = false;
        _writeBusy = false;
        _changed();
      }
    }
  }

  Future<void> runAction(
      Future<void> Function(DeviceManagementRecord) action) async {
    if (!hasAccess ||
        _device == null ||
        _busy ||
        _revokeUnknown ||
        _revokeAccepted) return;
    final target = _device!, generation = ++_generation;
    _busy = true;
    _error = null;
    _changed();
    try {
      await action(target);
      if (!_current(generation)) return;
      await _load(generation);
    } catch (failure) {
      if (_current(generation)) {
        if (failure is ApiFailure && failure.code == 'REAUTH_REQUIRED') {
          _error = failure;
        } else {
          _readFailure(failure);
        }
      }
    } finally {
      if (!_disposed && _generation == generation) {
        _busy = false;
        _changed();
      }
    }
  }
}
