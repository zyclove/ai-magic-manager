import 'api.dart';

const _safeInteger = 9007199254740991;
const _capabilityKeys = {
  'managed.app_policy',
  'app.install_policy',
  'app.launch_block',
  'permission.runtime',
  'device.lock_task',
  'usage.shared_quota_enforced',
  'usage.report',
  'network.domain_filter'
};
Never _invalid() => throw const ApiFailure(502, 'INVALID_DIAGNOSTIC_RESPONSE');
Json _object(Object? value) => value is Json ? value : _invalid();
String _choice(Object? value, Set<String> allowed) =>
    value is String && allowed.contains(value) ? value : _invalid();
String _id(Object? value) => value is String &&
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(value)
    ? value
    : _invalid();
int _integer(Object? value, int minimum, int maximum) =>
    value is int && value >= minimum && value <= maximum ? value : _invalid();
int? _time(Object? value, [int maximum = _safeInteger]) =>
    value == null ? null : _integer(value, 0, maximum);
String? _hash(Object? value) => value == null
    ? null
    : value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value)
        ? value
        : _invalid();
List<dynamic> _list(Object? value, int maximum) =>
    value is List && value.length <= maximum ? value : _invalid();

typedef DiagnosticVersion = ({String? value, String status});
typedef DiagnosticCapability = ({
  String key,
  bool reportedSupported,
  String grantStatus,
  String evidenceSource,
  int? checkedAt,
  String status,
  String limitationCode
});
typedef DiagnosticConfiguration = ({
  String id,
  String policyId,
  String versionId,
  int sourceSequence,
  String action,
  String deliveryState,
  String? policyHash,
  String? configurationHash,
  int? issuedAt,
  int? deliveryExpiresAt,
  int? receivedReportedAt,
  int? storedReportedAt,
  String? rejectionCode
});

DiagnosticVersion _version(Object? input) {
  final object = _object(input);
  final status =
      _choice(object['status'], {'REPORTED', 'UNREPORTED', 'REDACTED'});
  final value = object['value'];
  if (status == 'REPORTED') {
    if (value is! String ||
        !RegExp(r'^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$').hasMatch(value)) _invalid();
    return (value: value, status: status);
  }
  if (value != null) _invalid();
  return (value: null, status: status);
}

DiagnosticCapability _capability(Object? input, int generatedAt) {
  final object = _object(input);
  final reported = object['reportedSupported'];
  if (reported is! bool) _invalid();
  return (
    key: _choice(object['key'], _capabilityKeys),
    reportedSupported: reported,
    grantStatus: _choice(object['grantStatus'], {
      'GRANTED',
      'DENIED',
      'NOT_REQUESTED',
      'REVOKED',
      'NOT_APPLICABLE',
      'UNKNOWN'
    }),
    evidenceSource: _choice(object['evidenceSource'],
        {'AGENT_REPORT', 'REGISTRATION_MODE', 'UNKNOWN'}),
    checkedAt: _time(object['checkedAt'], generatedAt + 30000),
    status: _choice(
        object['status'], {'UNSUPPORTED', 'UNVERIFIED', 'STALE', 'UNKNOWN'}),
    limitationCode: _choice(object['limitationCode'],
        {'MANAGED_REGISTRATION_REQUIRED', 'EVIDENCE_NOT_CERTIFIED', 'UNKNOWN'}),
  );
}

DiagnosticConfiguration _configuration(Object? input, int generatedAt) {
  final object = _object(input);
  return (
    id: _id(object['id']),
    policyId: _id(object['policyId']),
    versionId: _id(object['versionId']),
    sourceSequence: _integer(object['sourceSequence'], 1, _safeInteger),
    action: _choice(object['action'],
        {'UPSERT_CONFIGURATION', 'REMOVE_CONFIGURATION', 'UNKNOWN'}),
    deliveryState: _choice(object['deliveryState'], {
      'PENDING_SIGNATURE',
      'READY',
      'SERVED',
      'DEVICE_REPORTED_RECEIVED',
      'DEVICE_REPORTED_STORED',
      'DEVICE_REPORTED_REJECTED',
      'EXPIRED_AWAITING_PULL',
      'UNKNOWN'
    }),
    policyHash: _hash(object['policyHash']),
    configurationHash: _hash(object['configurationHash']),
    issuedAt: _time(object['issuedAt'], generatedAt + 30000),
    deliveryExpiresAt: _time(object['deliveryExpiresAt']),
    receivedReportedAt:
        _time(object['receivedReportedAt'], generatedAt + 30000),
    storedReportedAt: _time(object['storedReportedAt'], generatedAt + 30000),
    rejectionCode: object['rejectionCode'] == null
        ? null
        : _choice(object['rejectionCode'], {
            'UNSUPPORTED_SCHEMA',
            'SIGNATURE_INVALID',
            'IDENTITY_MISMATCH',
            'UNSUPPORTED_RULES',
            'STORAGE_FAILURE',
            'EXPIRED',
            'OLDER_VERSION',
            'UNKNOWN_REJECTION'
          }),
  );
}

// Shared allowlist parsers for explicitly authorized support sections.
DiagnosticVersion parseDiagnosticVersion(Object? value) => _version(value);
DiagnosticCapability parseDiagnosticCapability(
        Object? value, int generatedAt) =>
    _capability(value, generatedAt);
DiagnosticConfiguration parseDiagnosticConfiguration(
        Object? value, int generatedAt) =>
    _configuration(value, generatedAt);

typedef DiagnosticDeviceState = ({
  String platform,
  String state,
  String managementMode,
  String controlLevel,
  String observationStatus,
  int? lastHeartbeatAt
});
DiagnosticDeviceState parseDiagnosticDeviceState(
    Object? value, int generatedAt) {
  final device = _object(value);
  return (
    platform: _choice(device['platform'], {'ANDROID', 'ANDROID_TV'}),
    state: _choice(
        device['state'], {'AWAITING_CONFIRMATION', 'ACTIVE', 'REVOKED'}),
    managementMode: _choice(device['managementMode'], {
      'BYOD',
      'WORK_PROFILE',
      'FULLY_MANAGED',
      'DEDICATED',
      'UNVERIFIED',
      'UNKNOWN'
    }),
    controlLevel:
        _choice(device['controlLevel'], {'LIMITED', 'NONE', 'UNKNOWN'}),
    observationStatus: _choice(
        device['observationStatus'], {'RECENT', 'STALE', 'REVOKED', 'UNKNOWN'}),
    lastHeartbeatAt: _time(device['lastHeartbeatAt'], generatedAt + 30000),
  );
}

/// Only validated, typed fields survive parsing. Extra server fields are never retained.
class DeviceDiagnostic {
  final String tenantId, deviceId, registrationId, correlationId;
  final int generatedAt, omittedCapabilityCount;
  final DiagnosticVersion os, agent, server;
  final String platform, state, managementMode, controlLevel, observationStatus;
  final int? lastHeartbeatAt;
  final List<DiagnosticCapability> capabilities;
  final List<DiagnosticConfiguration> configurations;

  DeviceDiagnostic._(
      {required this.tenantId,
      required this.deviceId,
      required this.registrationId,
      required this.correlationId,
      required this.generatedAt,
      required this.omittedCapabilityCount,
      required this.os,
      required this.agent,
      required this.server,
      required this.platform,
      required this.state,
      required this.managementMode,
      required this.controlLevel,
      required this.observationStatus,
      required this.lastHeartbeatAt,
      required List<DiagnosticCapability> capabilities,
      required List<DiagnosticConfiguration> configurations})
      : capabilities = List.unmodifiable(capabilities),
        configurations = List.unmodifiable(configurations);

  static DeviceDiagnostic parse(Object? input,
      {required String tenantId,
      required String deviceId,
      required String registrationId}) {
    final object = _object(input), scope = _object(object['scope']);
    if (object['schemaVersion'] != 1 ||
        object['evidenceStatus'] != 'DEVICE_REPORTS_NOT_EXECUTION_PROOF')
      _invalid();
    if (_id(scope['tenantId']) != tenantId ||
        _id(scope['deviceId']) != deviceId ||
        _id(scope['registrationId']) != registrationId) _invalid();
    final generatedAt =
        _integer(object['generatedAt'], 0, _safeInteger - 30000);
    final versions = _object(object['versions']),
        device = _object(object['device']);
    final capabilities = _list(object['capabilities'], 8)
        .map((value) => _capability(value, generatedAt))
        .toList();
    if (capabilities.map((value) => value.key).toSet().length !=
        capabilities.length) _invalid();
    final configurations = _list(object['configurations'], 100)
        .map((value) => _configuration(value, generatedAt))
        .toList();
    if (configurations.map((value) => value.id).toSet().length !=
            configurations.length ||
        configurations.map((value) => value.policyId).toSet().length !=
            configurations.length) _invalid();
    return DeviceDiagnostic._(
      tenantId: tenantId,
      deviceId: deviceId,
      registrationId: registrationId,
      correlationId: _id(object['correlationId']),
      generatedAt: generatedAt,
      omittedCapabilityCount: _integer(object['omittedCapabilityCount'], 0, 64),
      os: _version(versions['os']),
      agent: _version(versions['agent']),
      server: _version(versions['server']),
      platform: _choice(device['platform'], {'ANDROID', 'ANDROID_TV'}),
      state: _choice(
          device['state'], {'AWAITING_CONFIRMATION', 'ACTIVE', 'REVOKED'}),
      managementMode: _choice(device['managementMode'], {
        'BYOD',
        'WORK_PROFILE',
        'FULLY_MANAGED',
        'DEDICATED',
        'UNVERIFIED',
        'UNKNOWN'
      }),
      controlLevel:
          _choice(device['controlLevel'], {'LIMITED', 'NONE', 'UNKNOWN'}),
      observationStatus: _choice(device['observationStatus'],
          {'RECENT', 'STALE', 'REVOKED', 'UNKNOWN'}),
      lastHeartbeatAt: _time(device['lastHeartbeatAt'], generatedAt + 30000),
      capabilities: capabilities,
      configurations: configurations,
    );
  }
}
