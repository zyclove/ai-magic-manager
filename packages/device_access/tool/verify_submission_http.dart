import 'dart:convert';
import 'dart:io';
import 'package:device_access/device_access.dart';

/// Isolated JVM-owned loopback protocol check. Never prints fixture credentials or child text.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError('Expected private fixture file and phase');
  }
  final fixture = jsonDecode(await File(arguments[0]).readAsString())
      as Map<String, dynamic>;
  final root = Uri.parse(fixture['apiRoot'] as String);
  if (root.scheme != 'http' ||
      root.host != '127.0.0.1' ||
      root.path != '/api/v1') throw ArgumentError('Loopback fixture required');
  final transport = DeviceAccessTransport(
      apiRoot: root,
      credential: () async => fixture['credential'] as String,
      allowLoopbackHttp: true);
  void require(bool valid, String label) {
    if (!valid) throw StateError(label);
  }

  try {
    final context = await transport.context();
    context.requireIdentity(
        tenantId: fixture['tenantId'],
        deviceId: fixture['deviceId'],
        registrationId: fixture['registrationId']);
    require(context.subjectId == fixture['subjectId'],
        'Authenticated subject mismatch');
    final resultFile = File(fixture['resultFile'] as String);
    if (arguments[1] == 'submit') {
      final options = await transport.submissionOptions();
      require(
          options.items.any((o) =>
              o.id == fixture['policyId'] &&
              o.applications.any((a) => a.id == fixture['applicationId'])),
          'Eligible option missing');
      final input = AccessSubmissionInput(
          policyId: fixture['policyId'],
          baseVersionId: fixture['baseVersionId'],
          applicationId: fixture['applicationId'],
          ruleIds: ['reading'],
          requestedWindowSeconds: 600,
          reason: '继续阅读');
      final first = await transport.createSubmission(input,
          context: context, idempotencyKey: 'device-http-submission');
      final replay = await transport.createSubmission(input,
          context: context, idempotencyKey: 'device-http-submission');
      require(
          first.id == replay.id &&
              first.state == 'PENDING' &&
              !first.systemEnforced,
          'Create/replay mismatch');
      final page = await transport.submissions(context: context);
      require(page.items.length == 1 && page.items.single.id == first.id,
          'Device submission page mismatch');
      await resultFile.writeAsString(jsonEncode({'requestId': first.id}));
    } else if (arguments[1] == 'approved' || arguments[1] == 'revoked') {
      final result =
          jsonDecode(await resultFile.readAsString()) as Map<String, dynamic>;
      final value =
          await transport.submission(result['requestId'], context: context);
      require(
          value.state ==
              (arguments[1] == 'approved'
                  ? 'APPROVED_PENDING_DELIVERY'
                  : 'REVOKED'),
          'Decision state mismatch');
      require(
          value.absoluteNotAfter == fixture['absoluteNotAfter'] &&
              !value.systemEnforced,
          'Original deadline/enforcement mismatch');
      final delivery = await transport.list();
      require(
          delivery.items.single.requestId == value.id &&
              delivery.items.single.absoluteNotAfter == value.absoluteNotAfter,
          'Existing delivery reference mismatch');
    } else {
      throw ArgumentError('Unknown submission phase');
    }
    stdout.writeln('Device access submission HTTP ${arguments[1]}: PASS');
  } finally {
    transport.close();
  }
}
