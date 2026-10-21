import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:parent/ui/pairing_qr.dart';

void main() {
  String code(
          {String tenant = 'tenant',
          String device = 'device',
          String pairing = 'A12B34C5'}) =>
      jsonEncode({
        'type': 'ai-manager-pairing-confirmation',
        'tenantId': tenant,
        'deviceId': device,
        'pairingCode': pairing,
      });
  test('confirmation QR is bound to the displayed family and claimed device',
      () {
    expect(
        readPairingConfirmation(code(), tenantId: 'tenant', deviceId: 'device'),
        'A12B34C5');
    for (final input in [
      code(tenant: 'other'),
      code(device: 'other'),
      code(pairing: '123'),
      'https://untrusted.invalid/'
    ]) {
      expect(
          () => readPairingConfirmation(input,
              tenantId: 'tenant', deviceId: 'device'),
          throwsFormatException);
    }
  });
}
