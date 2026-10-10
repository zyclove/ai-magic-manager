import 'package:flutter_test/flutter_test.dart';
import '../lib/core/api.dart';
import '../lib/core/support.dart';
import '../lib/core/support_diagnostic.dart';
import 'fixtures/support.dart';
import 'fixtures/diagnostic.dart' as diagnostic;

void main() {
  final invalid = isA<ApiFailure>()
      .having((v) => v.code, 'code', 'INVALID_SUPPORT_RESPONSE');
  test('pairing code is first response only and current actor is bound', () {
    final first = CreatedSupportPairing.parse(
        {'request': pairingFixture(), 'code': code}, recipient);
    expect(first.code, code);
    expect(first.request.recipientLabel, '技术支持接收人');
    expect(
        CreatedSupportPairing.parse(
                {'request': pairingFixture(), 'code': null}, recipient)
            .code,
        isNull);
    expect(
        () => CreatedSupportPairing.parse(
            {'request': pairingFixture(), 'code': code}, owner),
        throwsA(invalid));
    expect(
        () => CreatedSupportPairing.parse(
            {'request': pairingFixture()..['state'] = 'CONSUMED', 'code': code},
            recipient),
        throwsA(invalid));
  });
  test('models reject malformed state, identity, times and types', () {
    for (final entry in {
      'id': 'wrong',
      'recipientActorId': '\nsecret',
      'state': 'unknown',
      'expiresAt': 1
    }.entries) {
      expect(
          () =>
              SupportPairing.parse(pairingFixture()..[entry.key] = entry.value),
          throwsA(invalid));
    }
    for (final entry in {
      'diagnosticTypes': ['DEVICE_STATUS', 'DEVICE_STATUS'],
      'state': 'unknown',
      'version': -1,
      'expiresAt': 1
    }.entries) {
      expect(
          () => SupportGrant.parse(grantFixture()..[entry.key] = entry.value),
          throwsA(invalid));
    }
    expect(() => SupportGrant.parse(grantFixture(), tenant: registration),
        throwsA(invalid));
    expect(() => SupportGrant.parse(grantFixture(), recipient: owner),
        throwsA(invalid));
  });
  test('grant types immutable and draft input frozen across retries', () {
    final types = ['CAPABILITIES', 'DEVICE_STATUS'];
    final draft = SupportGrantDraft(
        tenantId: tenant,
        deviceId: device,
        registrationId: registration,
        recipientActorId: recipient,
        pairingCode: code,
        deviceVersion: 2,
        durationMinutes: 60,
        diagnosticTypes: types);
    types.clear();
    expect(draft.diagnosticTypes, ['DEVICE_STATUS', 'CAPABILITIES']);
    expect(() => draft.diagnosticTypes.add('RAW_LOGS'), throwsUnsupportedError);
    expect(draft.body['pairingCode'], code);
    expect(draft.key, isNotEmpty);
  });
  test('pages reject duplicates, unordered values, unsafe continuation', () {
    SupportPage<SupportGrant> parse(Json o) => SupportPage.parse(
        o, (v) => SupportGrant.parse(v, recipient: recipient), (v) => v.id);
    expect(
        parse({
          'items': [grantFixture()],
          'nextCursor': null
        }).items,
        hasLength(1));
    expect(
        () => parse({
              'items': [grantFixture(), grantFixture()],
              'nextCursor': null
            }),
        throwsA(invalid));
    expect(
        () => parse({
              'items': [grantFixture()],
              'nextCursor': grantId
            }),
        throwsA(invalid));
    expect(() => parse({'items': [], 'nextCursor': grantId}), throwsA(invalid));
  });
  test('all seven diagnostic combinations preserve exactly selected sections',
      () {
    for (int mask = 1; mask < 8; mask++) {
      final types = [
        for (int i = 0; i < 3; i++)
          if (mask & (1 << i) != 0) supportTypes[i]
      ];
      final grant =
          SupportGrant.parse(grantFixture(types: types, now: diagnostic.now));
      final result = SupportDiagnostic.parse(
          supportDiagnosticFixture(types: types), grant);
      expect(result.device != null, mask & 1 != 0);
      expect(result.capabilities != null, mask & 2 != 0);
      expect(result.configurations != null, mask & 4 != 0);
    }
  });
  test('ungranted sections and changed identity or expiry are rejected', () {
    final grant = SupportGrant.parse(grantFixture(now: diagnostic.now));
    for (final entry in {
      'capabilities': [],
      'configurations': [],
      'omittedCapabilityCount': 0,
      'grantId': pairingId,
      'grantExpiresAt': 1,
      'generatedAt': grant.expiresAt
    }.entries) {
      expect(
          () => SupportDiagnostic.parse(
              supportDiagnosticFixture()..[entry.key] = entry.value, grant),
          throwsA(invalid));
    }
    expect(
        () => SupportDiagnostic.parse(
            supportDiagnosticFixture()
              ..['scope'] = {
                'tenantId': tenant,
                'deviceId': device,
                'registrationId': device
              },
            grant),
        throwsA(invalid));
  });
}
