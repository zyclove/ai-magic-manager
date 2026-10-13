import 'dart:convert';
import 'dart:typed_data';

// Public certificate bytes only; no private key or trust bypass.
Uint8List cleanupTestCertificatePem(String certificateDerBase64) {
  final der = base64Decode(certificateDerBase64);
  if (der.isEmpty || der.length > 16384) {
    throw const FormatException('Invalid public test certificate size');
  }
  final canonical = base64Encode(der);
  final lines = <String>[];
  for (var start = 0; start < canonical.length; start += 64) {
    final end = start + 64 < canonical.length ? start + 64 : canonical.length;
    lines.add(canonical.substring(start, end));
  }
  return Uint8List.fromList(utf8.encode(
      '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n'));
}
