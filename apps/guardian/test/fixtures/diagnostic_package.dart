import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../lib/core/api.dart';
import '../../lib/core/support.dart';
import 'diagnostic.dart' as diagnostic;
import 'support.dart';
export 'support.dart'
    show owner, recipient, tenant, device, registration, grantId;

const packageId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

Json packageDocument({bool received = false, int? now, List<String>? types}) {
  final at = now ?? diagnostic.now,
      selected = types ?? (received ? ['DEVICE_STATUS'] : supportTypes);
  final value = received
      ? supportDiagnosticFixture(types: selected)
      : diagnostic.fixture();
  value['generatedAt'] = at;
  if (received) value['grantExpiresAt'] = at - 1000 + 3600000;
  return {
    'schemaVersion': 1,
    'type': 'DEVICE_DIAGNOSTIC',
    'jobId': packageId,
    'accessMode': received ? 'SUPPORT_GRANT' : 'ADMIN',
    'diagnosticTypes': selected,
    'generatedAt': at,
    'expiresAt': at - 1000 + 1800000,
    'diagnostic': value
  };
}

Uint8List documentBytes(Json value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
Json packageFixture(
    {bool received = false,
    String state = 'QUEUED',
    int? now,
    Json? document}) {
  final at = now ?? diagnostic.now,
      ready = state == 'READY',
      bytes = documentBytes(
          document ?? packageDocument(received: received, now: at));
  return {
    'id': packageId,
    'tenantId': tenant,
    'requesterActorId': received ? recipient : owner,
    'deviceId': device,
    'registrationId': registration,
    'accessMode': received ? 'SUPPORT_GRANT' : 'ADMIN',
    'grantId': received ? grantId : null,
    'diagnosticTypes': received ? ['DEVICE_STATUS'] : supportTypes,
    'state': state,
    'version': ready ? 2 : 0,
    'createdAt': at - 1000,
    'updatedAt': at,
    'expiresAt': at - 1000 + 1800000,
    'generatedAt': ready ? at : null,
    'byteCount': ready ? bytes.length : null,
    'sha256': ready ? sha256.convert(bytes).toString() : null,
    'failureCode':
        state == 'FAILED' ? 'DIAGNOSTIC_PACKAGE_ATTEMPTS_EXHAUSTED' : null
  };
}
