import 'dart:convert';
import 'dart:io';
import 'package:device_policy/device_policy.dart';
import 'package:device_reports/device_reports.dart';

void require(bool valid, String message) {
  if (!valid) throw StateError(message);
}

/// Uses isolated Spring fixtures; never prints credentials or private reports.
Future<void> main(List<String> args) async {
  require(args.length == 1, 'Fixture path required');
  final file = File(args.single);
  require(await file.length() < 16384, 'Fixture exceeds limit');
  final v = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final root = Uri.parse(v['apiRoot']);
  require(
      v['testOnly'] == true &&
          root.scheme == 'http' &&
          root.host == '127.0.0.1' &&
          root.hasPort &&
          root.path == '/api/v1' &&
          !root.hasQuery &&
          !root.hasFragment,
      'Loopback fixture required');
  final transport = DeviceConfigurationTransport(
      apiRoot: root,
      credential: () async => v['deviceToken'],
      allowLoopbackHttp: true);
  final reader = DeviceUsageReportClient(
      transport: transport,
      target: UsageReportTarget(
          v['deviceId'], v['registrationId'], v['subjectId'], '本设备',
          platform: 'ANDROID'),
      current: () => true);
  try {
    if (v['deviceExpectedStatus'] == 401) {
      try {
        await reader.load(from: v['from'], to: v['to'], timeZone: 'UTC');
        throw StateError('Revoked credential unexpectedly accepted');
      } on DeviceTransportFailure catch (error) {
        require(
            error.status == 401 && !error.retryable && !error.outcomeUnknown,
            'Revocation was not terminal');
      }
      print('PASS device usage report revoked HTTP');
      return;
    }
    final report =
        await reader.load(from: v['from'], to: v['to'], timeZone: 'UTC');
    final device = report.devices.single;
    require(
        report.scope.kind == 'DEVICES' &&
            device.deviceId == v['deviceId'] &&
            device.registrationId == v['registrationId'] &&
            device.subjectId == v['subjectId'],
        'Authenticated binding mismatch');
    require(
        device.status == 'OBSERVED' &&
            device.applications.single.buckets.first.lowerMillis == 2000,
        'Real aggregation missing');
    require(
        device.configurationState.configurations.single.rules.single.kind ==
            'USAGE_REMINDER',
        'Real configuration missing');
    print('PASS device usage report HTTP');
  } finally {
    reader.dispose();
    transport.close();
  }
}
