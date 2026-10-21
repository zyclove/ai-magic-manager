import 'dart:convert';
import 'package:device_identity/device_identity.dart';
import 'package:device_policy/device_policy.dart' show validId;
import 'package:http/http.dart' as http;

class AssistedExecutionReporter {
  final DeviceIdentityManager identity;
  final Uri apiRoot;
  final http.Client? client;
  final int Function() nowMillis;
  final Future<void> Function()? onCredentialRejected;
  AssistedExecutionReporter(
      {required this.identity,
      required this.apiRoot,
      this.client,
      this.onCredentialRejected,
      int Function()? nowMillis})
      : nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);
  Future<bool> upload(Map<String, dynamic> snapshot) async {
    if (!_valid(snapshot)) return false;
    http.Client? owned;
    try {
      final before = await identity.view();
      if (!_sameScope(before, snapshot)) return false;
      final credential = await identity.activeCredential();
      final current = await identity.view();
      if (credential == null || !_sameScope(current, snapshot)) return false;
      final request = http.Request(
          'POST',
          apiRoot.replace(
              path:
                  '${apiRoot.path}/device-api/family/assisted-execution-reports'))
        ..followRedirects = false
        ..headers.addAll({
          'authorization': 'Bearer $credential',
          'content-type': 'application/json'
        })
        ..body = jsonEncode({
          for (final key in [..._fields, ..._nativeModel])
            if (snapshot.containsKey(key)) key: snapshot[key]
        });
      final connection = client ?? (owned = http.Client());
      final response =
          await connection.send(request).timeout(const Duration(seconds: 5));
      if (response.statusCode == 401) {
        final rejected = await identity.recordCredentialRejection(
            scope: current, rejectedCredential: credential);
        if (rejected) await onCredentialRejected?.call();
        return false;
      }
      if (response.statusCode != 200) return false;
      final bytes = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 5))) {
        if (bytes.length + chunk.length > 4096) return false;
        bytes.addAll(chunk);
      }
      final result = jsonDecode(utf8.decode(bytes));
      return result is Map &&
          result['accepted'] == true &&
          result['evidenceStatus'] == 'AGENT_REPORTED_UNVERIFIED';
    } catch (_) {
      return false;
    } finally {
      owned?.close();
    }
  }

  bool _sameScope(DeviceIdentityView view, Map<String, dynamic> snapshot) =>
      !view.cloudAuthenticationBlocked &&
      view.phase == IdentityPhase.active &&
      view.tenantId == snapshot['tenantId'] &&
      view.deviceId == snapshot['deviceId'] &&
      view.registrationId == snapshot['registrationId'];

  bool _valid(Map<String, dynamic> snapshot) {
    final time = snapshot['observedAt'];
    if (time is! int ||
        time < nowMillis() - 300000 ||
        time > nowMillis() + 30000 ||
        snapshot['systemEnforced'] != false ||
        !['tenantId', 'deviceId', 'registrationId', 'policyId', 'versionId']
            .every((key) => validId(snapshot[key])) ||
        !['sourceSequence', 'reportSequence'].every((key) =>
            snapshot[key] is int &&
            (snapshot[key] as int) > 0 &&
            (snapshot[key] as int) <= 9007199254740991) ||
        !['optedIn', 'usageGranted', 'accessibilityConnected']
            .every((key) => snapshot[key] is bool) ||
        snapshot['reason'] is! String ||
        (snapshot['reason'] as String).length > 100 ||
        !_health.contains(snapshot['health']) ||
        !{'ALLOW', 'RESTRICT', 'UNKNOWN'}.contains(snapshot['limitStatus'])) {
      return false;
    }
    final remaining = snapshot['remainingSeconds'];
    if (remaining != null &&
        (remaining is! int || remaining < 0 || remaining > 86400)) return false;
    if (_nativeModel.any(snapshot.containsKey) &&
        (snapshot['manufacturer'] is! String ||
            (snapshot['manufacturer'] as String).isEmpty ||
            (snapshot['manufacturer'] as String).length > 100 ||
            snapshot['model'] is! String ||
            (snapshot['model'] as String).isEmpty ||
            (snapshot['model'] as String).length > 100 ||
            snapshot['apiLevel'] is! int ||
            (snapshot['apiLevel'] as int) < 24 ||
            (snapshot['apiLevel'] as int) > 100 ||
            !{'NOT_REQUIRED', 'HOME_RETURNED', 'ACTION_FAILED'}
                .contains(snapshot['interventionStatus']))) return false;
    return snapshot['health'] != 'ACTIVE' ||
        (snapshot['optedIn'] == true &&
            snapshot['usageGranted'] == true &&
            snapshot['accessibilityConnected'] == true &&
            remaining is int);
  }

  static const _fields = [
    'tenantId',
    'deviceId',
    'registrationId',
    'policyId',
    'versionId',
    'sourceSequence',
    'reportSequence',
    'observedAt',
    'health',
    'limitStatus',
    'reason',
    'remainingSeconds',
    'optedIn',
    'usageGranted',
    'accessibilityConnected',
    'systemEnforced'
  ];
  static const _nativeModel = [
    'manufacturer',
    'model',
    'apiLevel',
    'interventionStatus'
  ];
  static const _health = {
    'ACTIVE',
    'CONSENT_REQUIRED',
    'PERMISSION_MISSING',
    'CONFIGURATION_UNAVAILABLE',
    'NATIVE_OBSERVATION_UNAVAILABLE',
    'INITIALIZING',
    'CLOCK_ANOMALY',
    'EXPIRED',
    'FOREGROUND_UNAVAILABLE',
    'STORAGE_FAILURE',
    'CONFIGURATION_INVALID',
    'DISABLED'
  };
}
