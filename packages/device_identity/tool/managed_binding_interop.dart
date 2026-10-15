import 'dart:convert';
import 'dart:io';
import 'package:device_identity/device_identity.dart';

/// Local cryptographic interop fixture only. No production identity or secrets.
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('Expected fixture and result paths');
  }
  final input = jsonDecode(await File(args[0]).readAsString());
  final challenge = ManagedAgentChallenge.fromJson(
      Map<String, dynamic>.from(input['challenge']));
  const keys = JoseDeviceEnrollmentKeys();
  final handle = await keys.generateHandle();
  final proof =
      await keys.managedBindingProof(handle, challenge, input['nowMillis']);
  final publicKey = Map<String, dynamic>.from(jsonDecode(handle))..remove('d');
  publicKey['key_ops'] = ['verify'];
  await File(args[1]).writeAsString(
      jsonEncode(
          {'publicKeyJwk': jsonEncode(publicKey), 'proof': proof.compact}),
      flush: true);
  stdout.writeln('PASS: generated ephemeral managed binding proof');
}
