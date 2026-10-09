import 'dart:convert';
import 'dart:io';
import 'package:device_policy/device_policy.dart';

/// Reads only a test fixture produced with NimbusConfigurationFixture.java.
/// Expected registration IDs are independent of the received signed body.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('Provide the public fixture file');
  }
  final data = jsonDecode(await File(arguments.single).readAsString());
  final verifier = ConfigurationVerifier(
      scope: const DevicePolicyScope(
          issuer: 'ai-manager',
          tenantId: '11111111-1111-4111-8111-111111111111',
          deviceId: '22222222-2222-4222-8222-222222222222',
          registrationId: '33333333-3333-4333-8333-333333333333'),
      trustedKeys: Map<String, dynamic>.from(data['publicKeys']),
      nowMillis: () => 1791528000000);
  final result = await verifier.verify(data['compactJws']);
  if (result.cursor != 1 ||
      result.policyId != '44444444-4444-4444-8444-444444444444' ||
      result.document!['name'] != 'Nimbus 互操作学习计划' ||
      result.systemEnforced) {
    throw StateError('Interoperability assertions failed');
  }
  stdout.writeln(
      'Nimbus backend -> Dart JOSE: PASS (public fixture; no execution claim)');
}
