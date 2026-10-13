import 'dart:convert';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

Matcher failure(String code) =>
    isA<CleanupFailure>().having((e) => e.code, 'code', code);
void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  Future<VerifiedCleanupCommand> verify(Map<String, dynamic> changes) =>
      f.verifier.verify(f.sign(changes),
          operationId: operation, commandId: commandId, notAfter: time + 60000);

  test('valid ES256 command is bound and diagnostics redact signed content',
      () async {
    final command = await f.verified();
    expect(command.scope.registrationId, registration);
    expect(command.commandHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(command.toString(), 'VerifiedCleanupCommand(redacted)');
  });
  for (final change in <String, dynamic>{
    'schemaVersion': 2,
    'purpose': 'WIPE_DEVICE',
    'tenantId': operation,
    'deviceId': operation,
    'registrationId': operation,
    'keyThumbprint': 'B' * 43,
    'operationId': tenant,
    'commandId': tenant,
    'notAfter': time + 50000,
    'scope': 'WHOLE_DEVICE',
    'keyRemoval': 'BEFORE_SERVER_ACK',
    'actions': ['CLEAR_POLICY_CACHE', 'CLEAR_USAGE_CACHE', 'WIPE_DEVICE'],
    'extra': true
  }.entries) {
    test('signed command rejects substituted ${change.key}', () async {
      await expectLater(verify({change.key: change.value}),
          throwsA(failure('CLEANUP_COMMAND_MISMATCH')));
    });
  }
  test('wrong JOSE type is rejected despite valid signature', () async {
    await expectLater(
        f.verifier.verify(f.sign({}, 'JWT'),
            operationId: operation,
            commandId: commandId,
            notAfter: time + 60000),
        throwsA(failure('CLEANUP_SIGNATURE_INVALID')));
  });
  test('untrusted signer cannot supply a cleanup command', () async {
    await expectLater(
        f.verifier.verify(Fixture().sign(),
            operationId: operation,
            commandId: commandId,
            notAfter: time + 60000),
        throwsA(failure('CLEANUP_SIGNATURE_INVALID')));
  });
  test('expired command is rejected', () async {
    f.now = time + 60000;
    await expectLater(
        f.verified(), throwsA(failure('CLEANUP_COMMAND_EXPIRED')));
  });
  test('untrusted clock cannot authorize cleanup', () async {
    f.now = 0;
    await expectLater(f.verified(), throwsA(failure('CLOCK_UNTRUSTED')));
  });
  test('private or duplicate keys are not a trusted public ring', () {
    final ring = f.ring;
    (ring['keys'] as List).add((ring['keys'] as List).first);
    expect(
        () => CleanupCommandVerifier(
            scope: scope, trustedKeys: ring, nowMillis: () => time),
        throwsArgumentError);
    final privateRing = f.ring;
    (privateRing['keys'] as List).first['d'] = 'A' * 43;
    expect(
        () => CleanupCommandVerifier(
            scope: scope, trustedKeys: privateRing, nowMillis: () => time),
        throwsArgumentError);
  });
  for (final field in [
    'id',
    'deviceId',
    'registrationId',
    'commandId',
    'action',
    'remoteAccess',
    'issuedAt',
    'notAfter',
    'version',
    'state',
    'localEvidence',
    'reasonCode'
  ]) {
    test('cleared acknowledgement rejects invalid $field', () async {
      final receipt = CleanupReceipt(
          await f.verified(), tenant, CleanupReceiptStage.agentDataCleared);
      final value = f.ack(receipt.body)..[field] = 'invalid';
      expect(() => CleanupReceiptAck.parse(value, receipt),
          throwsA(failure('CLEANUP_ACK_INVALID')));
    });
  }
  test('receipt keeps exact body and redacts diagnostics', () async {
    final receipt = CleanupReceipt(
        await f.verified(), tenant, CleanupReceiptStage.failed,
        reasonCode: 'STORAGE_FAILURE');
    expect(
        receipt.body.keys,
        containsAll(
            ['receiptId', 'commandId', 'commandHash', 'stage', 'reasonCode']));
    expect(jsonEncode(receipt.body), isNot(contains('compactJws')));
    expect(receipt.toString(), 'CleanupReceipt(redacted)');
    expect(
        () => CleanupReceipt(
            receipt.command, tenant, CleanupReceiptStage.failed,
            reasonCode: 'private exception'),
        throwsArgumentError);
  });
}
