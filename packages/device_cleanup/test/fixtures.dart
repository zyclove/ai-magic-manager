import 'dart:async';
import 'dart:convert';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:device_identity/device_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';

const time = 1791528000000;
const tenant = '11111111-1111-4111-8111-111111111111';
const device = '22222222-2222-4222-8222-222222222222';
const registration = '33333333-3333-4333-8333-333333333333';
const operation = '44444444-4444-4444-8444-444444444444';
const commandId = '55555555-5555-4555-8555-555555555555';
final scope = CleanupScope(tenant, device, registration, 'A' * 43);

// Explicit in-memory test store; never an encrypted platform adapter.
class MemoryStore implements CleanupRecordStore {
  String? value;
  bool failRead = false, failWrite = false, persistThenFail = false;
  int writes = 0;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('private storage cause');
    return value;
  }

  @override
  Future<void> write(String record) async {
    writes++;
    if (persistThenFail) value = record;
    if (failWrite) throw StateError('private storage cause');
    value = record;
  }
}

class Fixture {
  final CleanupScope binding;
  final key = JsonWebKey.fromJson({
    ...JsonWebKey.generate('ES256').toJson(),
    'kid': 'cleanup-test',
    'alg': 'ES256',
    'use': 'sig'
  });
  int now = time;
  Fixture([CleanupScope? binding]) : binding = binding ?? scope;
  Map<String, dynamic> get ring {
    final public = Map<String, dynamic>.from(key.toJson())..remove('d');
    // Match the server's RFC 7517 unpadded P-256 coordinate encoding.
    for (final coordinate in ['x', 'y']) {
      final encoded = public[coordinate] as String;
      final magnitude = base64Url
          .decode(base64Url.normalize(encoded))
          .skipWhile((byte) => byte == 0)
          .toList();
      if (magnitude.length > 32) throw StateError('Invalid test coordinate');
      public[coordinate] = base64Url.encode([
        ...List<int>.filled(32 - magnitude.length, 0),
        ...magnitude
      ]).replaceAll('=', '');
    }
    public['key_ops'] = ['verify'];
    return {
      'keys': [public]
    };
  }

  Map<String, dynamic> payload([Map<String, dynamic> changes = const {}]) => {
        'schemaVersion': 1,
        'purpose': 'AGENT_CLEANUP',
        'tenantId': binding.tenantId,
        'deviceId': binding.deviceId,
        'registrationId': binding.registrationId,
        'keyThumbprint': binding.keyThumbprint,
        'operationId': operation,
        'commandId': commandId,
        'issuedAt': time - 1000,
        'notAfter': time + 60000,
        'scope': 'OWN_AGENT_DATA_ONLY',
        'actions': [
          'CLEAR_POLICY_CACHE',
          'CLEAR_USAGE_CACHE',
          'CLEAR_BUSINESS_CREDENTIALS'
        ],
        'keyRemoval': 'AFTER_SERVER_ACK',
        ...changes
      };
  String sign(
      [Map<String, dynamic> changes = const {},
      String type = 'aimanager-cleanup-command+jws']) {
    final builder = JsonWebSignatureBuilder()
      ..stringContent = jsonEncode(payload(changes));
    builder.setProtectedHeader('typ', type);
    builder.addRecipient(key, algorithm: 'ES256');
    return builder.build().toCompactSerialization();
  }

  CleanupCommandVerifier get verifier => CleanupCommandVerifier(
      scope: binding, trustedKeys: ring, nowMillis: () => now);
  Future<VerifiedCleanupCommand> verified() => verifier.verify(sign(),
      operationId: operation, commandId: commandId, notAfter: time + 60000);
  CleanupReceiptJournal journal(MemoryStore store) =>
      CleanupReceiptJournal(scope: binding, store: store, nowMillis: () => now);
  Map<String, dynamic> ack(Map<String, dynamic> receipt) => {
        'id': operation,
        'deviceId': binding.deviceId,
        'registrationId': binding.registrationId,
        'commandId': commandId,
        'action': 'AGENT_UNENROLL',
        'state': switch (receipt['stage']) {
          'RECEIVED' => 'COMMAND_RECEIVED',
          'FAILED' => 'CLEANUP_FAILED',
          _ => 'CLEANUP_REPORTED'
        },
        'remoteAccess': 'REVOKED',
        'localEvidence': receipt['stage'] == 'RECEIVED'
            ? 'NONE'
            : 'DEVICE_REPORT_UNVERIFIED',
        'reasonCode': receipt['reasonCode'],
        'issuedAt': time - 1000,
        'notAfter': time + 60000,
        'version': 1
      };
  CleanupReceiptAck accepted(CleanupReceipt receipt) =>
      CleanupReceiptAck.parse(ack(receipt.body), receipt);
}

class TestServer {
  final Fixture fixture;
  late final String signed = fixture.sign();
  final receipts = <Map<String, dynamic>>[];
  int reads = 0, proofs = 0;
  String? loseStage;
  Future<void> Function(Map<String, dynamic>)? beforeAck;
  TestServer(this.fixture);
  CleanupCommandClient client() => CleanupCommandClient(
      scope: fixture.binding,
      apiRoot: Uri.parse('https://cleanup.example/api/v1'),
      nowMillis: () => fixture.now,
      proofFactory: (action, id) async {
        proofs++;
        // Transport substitute only; this fixture does not certify server proof authentication.
        final header = base64Url
            .encode(utf8.encode(jsonEncode({
              'alg': 'ES256',
              'typ': 'aimanager-cleanup-auth+jwt',
              'kid': registration
            })))
            .replaceAll('=', '');
        return CleanupProof('$header.e30.AA', fixture.binding.keyThumbprint);
      },
      client: MockClient((request) async {
        if (request.method == 'GET') {
          reads++;
          return jsonResponse(request.url.path.endsWith('signing-keys')
              ? fixture.ring
              : {
                  'operationId': operation,
                  'commandId': commandId,
                  'notAfter': time + 60000,
                  'compactJws': signed
                });
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        receipts.add(body);
        await beforeAck?.call(body);
        if (loseStage == body['stage']) {
          loseStage = null;
          throw http.ClientException('private network cause');
        }
        return jsonResponse(fixture.ack(body));
      }));
}

http.Response jsonResponse(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

class TestExecutor implements AgentCleanupExecutor {
  int clears = 0, removals = 0;
  Object? clearError, removeError;
  Completer<void>? clearGate;
  final entered = Completer<void>();
  @override
  Future<void> clearOwnData(VerifiedCleanupCommand command) async {
    clears++;
    if (!entered.isCompleted) entered.complete();
    await clearGate?.future;
    if (clearError != null) throw clearError!;
  }

  @override
  Future<void> removeOriginalKey(VerifiedCleanupCommand command) async {
    removals++;
    if (removeError != null) throw removeError!;
  }
}
