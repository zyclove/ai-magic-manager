import '../../lib/core/api.dart';
import 'diagnostic.dart' as diagnostic;
export 'diagnostic.dart' show tenant, device, registration;

const recipient = 'support-recipient',
    owner = 'customer-owner',
    pairingId = '88888888-8888-8888-8888-888888888888',
    grantId = '99999999-9999-9999-9999-999999999999';
final code = List.filled(43, 'a').join();
Json pairingFixture({int? now}) {
  final created = now ?? DateTime.now().millisecondsSinceEpoch;
  return {
    'id': pairingId,
    'recipientActorId': recipient,
    'displayName': '技术支持接收人',
    'verifiedEmail': 'recipient@example.test',
    'state': 'PENDING',
    'version': 0,
    'createdAt': created,
    'expiresAt': created + 600000
  };
}

Json grantFixture({List<String> types = const ['DEVICE_STATUS'], int? now}) {
  final created = now ?? DateTime.now().millisecondsSinceEpoch;
  return {
    'id': grantId,
    'tenantId': diagnostic.tenant,
    'deviceId': diagnostic.device,
    'registrationId': diagnostic.registration,
    'creatorActorId': owner,
    'recipientActorId': recipient,
    'recipientDisplayName': '技术支持接收人',
    'recipientVerifiedEmail': 'recipient@example.test',
    'diagnosticTypes': types,
    'state': 'ACTIVE',
    'version': 0,
    'createdAt': created,
    'expiresAt': created + 3600000
  };
}

Json supportDiagnosticFixture({List<String> types = const ['DEVICE_STATUS']}) {
  final value = diagnostic.fixture();
  value.addAll({
    'grantId': grantId,
    'grantExpiresAt': diagnostic.now + 3600000,
    'diagnosticTypes': types
  });
  if (!types.contains('DEVICE_STATUS')) {
    value['device'] = null;
    value['versions'] = null;
  }
  if (!types.contains('CAPABILITIES')) {
    value['capabilities'] = null;
    value['omittedCapabilityCount'] = null;
  }
  if (!types.contains('CONFIGURATION_METADATA')) value['configurations'] = null;
  return value;
}
