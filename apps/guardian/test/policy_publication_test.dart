import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_publication.dart';

import 'publication_test_journal.dart';

PublicationOwner owner({
  String actor = 'adult-a',
  String tenant = 'tenant-a',
  String api = 'https://fixture.invalid/api/v1',
  String issuer = 'https://identity.invalid/realms/manager',
}) =>
    PublicationOwner(
        actorId: actor, tenantId: tenant, apiBaseUrl: api, issuer: issuer);

PublicationIntent intent({
  PublicationOwner? scope,
  String policy = 'policy-a',
  String key = '11111111-1111-4111-8111-111111111111',
  String preview = '22222222-2222-4222-8222-222222222222',
  String? hash,
  int revision = 7,
  int created = 1000,
  int expiry = 2000,
}) =>
    PublicationIntent(
        owner: scope ?? owner(),
        policyId: policy,
        revision: revision,
        previewId: preview,
        previewHash: hash ?? 'a' * 64,
        previewExpiresAt: expiry,
        createdAt: created,
        idempotencyKey: key);

Map<String, Object> receipt() => {
      'id': 'publication-a',
      'versionId': 'version-a',
      'sequence': 1,
      'mode': 'CONFIGURE_ONLY',
      'state': 'CONFIGURED_NOT_ENFORCED',
      'createdAt': 1100,
    };

Matcher code(String value) =>
    isA<ApiFailure>().having((failure) => failure.code, 'code', value);

void main() {
  test(
      'past preview expiry remains representable while UNKNOWN recovery is not retryable',
      () async {
    final value = intent(created: 2000, expiry: 1000);
    expect(value.previewExpiresAt, 1000);
    expect(
        PublicationIntent.parse(jsonDecode(jsonEncode(value.toJson()))), value);
    final journal = MemoryPublicationJournal();
    final record = (await journal.reserve(value)).record;
    expect(
        PublicationPending.decode(record.encode(),
            owner: owner(), policyId: 'policy-a'),
        record);
    // A journal records intent; this expired UNKNOWN record is never retryable.
    expect((await journal.claimRetry(record)).maySubmit, isFalse);
    expect(await journal.cancelNotSubmitted(record), isFalse);
  });

  test('owner partitions exact actor tenant API and issuer without role', () {
    final value = owner();
    expect(value, owner());
    expect(value.key, owner().key);
    for (final other in [
      owner(actor: 'adult-b'),
      owner(tenant: 'tenant-b'),
      owner(api: 'https://other.invalid/api/v1'),
      owner(issuer: 'https://other.invalid/realms/manager')
    ]) {
      expect(other, isNot(value));
      expect(other.key, isNot(value.key));
    }
    expect(value.toJson().keys,
        unorderedEquals(['actorId', 'tenantId', 'apiBaseUrl', 'issuer']));
  });

  test('intent freezes only the exact non-secret publication input', () {
    final value = intent();
    expect(value.mode, 'CONFIGURE_ONLY');
    expect(value.body, {
      'previewId': value.previewId,
      'previewHash': 'a' * 64,
      'mode': 'CONFIGURE_ONLY'
    });
    expect(
        value.toJson().keys,
        unorderedEquals([
          'owner',
          'policyId',
          'revision',
          'previewId',
          'previewHash',
          'previewExpiresAt',
          'createdAt',
          'idempotencyKey',
          'mode',
        ]));
    expect(() => value.body['mode'] = 'ENFORCE', throwsUnsupportedError);
    expect(value.toJson().containsKey('accessToken'), isFalse);
    expect(value.toJson().containsKey('targets'), isFalse);
  });

  test('intent round trip does not retain a mutable source map', () {
    final raw = jsonDecode(jsonEncode(intent().toJson())) as Json;
    final value = PublicationIntent.parse(raw);
    raw['policyId'] = 'other';
    (raw['owner'] as Json)['actorId'] = 'other';
    expect(value, intent());
    expect(value.hashCode, intent().hashCode);
    expect(value.owner.actorId, 'adult-a');
  });

  test('request keys require full canonical version-four UUIDs', () {
    for (final value in [
      'a' * 48,
      '11111111-1111-1111-8111-111111111111',
      '11111111-1111-4111-7111-111111111111',
      'AAAAAAAA-1111-4111-8111-111111111111',
      '11111111-1111-4111-8111-111111111111\n'
    ]) {
      expect(() => intent(key: value),
          throwsA(code('INVALID_POLICY_PUBLICATION_INTENT')));
    }
  });

  test('preview IDs hashes and revisions follow the actual lookup contract',
      () {
    for (final value in [
      'preview-a',
      '../preview',
      '22222222-2222-4222-8222-222222222222\n'
    ]) {
      expect(() => intent(preview: value),
          throwsA(code('INVALID_POLICY_PUBLICATION_INTENT')));
    }
    for (final value in ['', 'a' * 63, 'A' * 64, '${'a' * 64}\n']) {
      expect(() => intent(hash: value),
          throwsA(code('INVALID_POLICY_PUBLICATION_INTENT')));
    }
    for (final value in [-1, 9007199254740992]) {
      expect(() => intent(revision: value),
          throwsA(code('INVALID_POLICY_PUBLICATION_INTENT')));
    }
    expect(intent(revision: 0).revision, 0);
  });

  test('policy and receipt identifiers stay bounded opaque values', () {
    expect(intent().policyId, 'policy-a');
    expect(PublicationReceipt.parse(receipt()).id, 'publication-a');
    for (final value in ['', 'a' * 201, 'policy\u0000', '..']) {
      expect(() => intent(policy: value),
          throwsA(code('INVALID_POLICY_PUBLICATION_INTENT')));
      expect(() => PublicationReceipt.parse({...receipt(), 'id': value}),
          throwsA(code('INVALID_POLICY_PUBLICATION_RESPONSE')));
    }
  });

  test('receipt accepts exactly the six committed configuration fields', () {
    final value = PublicationReceipt.parse(receipt());
    expect(value.id, 'publication-a');
    expect(value.versionId, 'version-a');
    expect(value.sequence, 1);
    expect(value.mode, 'CONFIGURE_ONLY');
    expect(value.state, 'CONFIGURED_NOT_ENFORCED');
    expect(value.createdAt, 1100);
    expect(value, PublicationReceipt.parse(receipt()));
  });

  test('receipt rejects every missing field extra fields and empty successes',
      () {
    for (final key in receipt().keys) {
      final raw = receipt()..remove(key);
      expect(() => PublicationReceipt.parse(raw),
          throwsA(code('INVALID_POLICY_PUBLICATION_RESPONSE')),
          reason: key);
    }
    for (final raw in [
      null,
      <String, Object>{},
      [],
      '',
      {...receipt(), 'token': 'private'},
      {...receipt(), 'id': null}
    ]) {
      expect(() => PublicationReceipt.parse(raw),
          throwsA(code('INVALID_POLICY_PUBLICATION_RESPONSE')));
    }
  });

  test('receipt rejects enforcement unknown states and unsafe number types',
      () {
    for (final raw in [
      {...receipt(), 'mode': 'ENFORCE'},
      {...receipt(), 'state': 'PENDING_EXECUTION'},
      {...receipt(), 'state': 'UNKNOWN'},
      {...receipt(), 'sequence': '1'},
      {...receipt(), 'sequence': 0},
      {...receipt(), 'sequence': 9007199254740992},
      {...receipt(), 'createdAt': -1},
      {...receipt(), 'createdAt': true},
      {...receipt(), 'createdAt': 9007199254740992},
    ]) {
      expect(() => PublicationReceipt.parse(raw),
          throwsA(code('INVALID_POLICY_PUBLICATION_RESPONSE')));
    }
  });

  test('pending codec preserves original intent phase and attempt fence', () {
    for (final phase in PublicationPhase.values) {
      final record =
          PublicationPending(intent: intent(), phase: phase, attempt: 3);
      final restored = PublicationPending.decode(record.encode(),
          owner: owner(), policyId: 'policy-a');
      expect(restored, record);
      expect(restored.hashCode, record.hashCode);
      expect(restored.intent.previewExpiresAt, 2000);
      expect(restored.attempt, 3);
      expect(restored.toJson()['phase'],
          phase == PublicationPhase.unknown ? 'UNKNOWN' : 'REAUTH_REQUIRED');
    }
  });

  test('pending codec never accepts a foreign owner or policy', () {
    final encoded = PublicationPending(intent: intent()).encode();
    for (final other in [
      owner(actor: 'adult-b'),
      owner(tenant: 'tenant-b'),
      owner(api: 'https://other.invalid/api/v1'),
      owner(issuer: 'https://other.invalid/realms/manager')
    ]) {
      expect(
          () => PublicationPending.decode(encoded,
              owner: other, policyId: 'policy-a'),
          throwsA(code('INVALID_POLICY_PUBLICATION_RECORD')));
    }
    expect(
        () => PublicationPending.decode(encoded,
            owner: owner(), policyId: 'policy-b'),
        throwsA(code('INVALID_POLICY_PUBLICATION_RECORD')));
  });

  test('pending codec rejects malformed extra unsupported or unsafe records',
      () {
    final record = PublicationPending(intent: intent());
    for (final raw in [
      'not-json',
      '[]',
      'null',
      'x' * 8193,
      jsonEncode({...record.toJson(), 'secret': 'never-echo'}),
      jsonEncode({...record.toJson(), 'schema': 2}),
      jsonEncode({...record.toJson(), 'phase': 'READY'}),
      jsonEncode({...record.toJson(), 'attempt': 0}),
      jsonEncode({...record.toJson(), 'attempt': 9007199254740992}),
    ]) {
      expect(
          () => PublicationPending.decode(raw,
              owner: owner(), policyId: 'policy-a'),
          throwsA(code('INVALID_POLICY_PUBLICATION_RECORD')));
    }
  });

  test('pending equality includes phase attempt and every frozen input', () {
    final record = PublicationPending(intent: intent());
    expect(record, isNot(PublicationPending(intent: intent(), attempt: 2)));
    expect(
        record,
        isNot(PublicationPending(
            intent: intent(),
            phase: PublicationPhase.reauthenticationRequired)));
    expect(record, isNot(PublicationPending(intent: intent(revision: 8))));
  });

  test('memory reserve retains the first policy key and only one winner',
      () async {
    final journal = MemoryPublicationJournal();
    final attempts = await Future.wait([
      journal.reserve(intent()),
      journal.reserve(intent(key: '33333333-3333-4333-8333-333333333333'))
    ]);
    expect(attempts.where((value) => value.maySubmit), hasLength(1));
    expect(attempts[1].record, attempts[0].record);
    expect(await journal.read(owner(), 'policy-a'), attempts[0].record);
  });

  test('memory retry advances the attempt once and rejects stale downgrade',
      () async {
    final journal = MemoryPublicationJournal();
    final first = (await journal.reserve(intent())).record;
    final denied = await journal.markReauthenticationRequired(first);
    final retries = await Future.wait(
        [journal.claimRetry(denied), journal.claimRetry(denied)]);
    expect(retries.where((value) => value.maySubmit), hasLength(1));
    final current = retries.firstWhere((value) => value.maySubmit).record;
    expect(current.attempt, 2);
    expect(current.phase, PublicationPhase.unknown);
    await expectLater(journal.markReauthenticationRequired(first),
        throwsA(code('PUBLICATION_PENDING_CHANGED')));
    expect(await journal.removeIfSame(first), isFalse);
    expect(await journal.cancelNotSubmitted(denied), isFalse);
    expect(await journal.read(owner(), 'policy-a'), current);
  });

  test('memory unknown cannot be cancelled even when its preview is expired',
      () async {
    final journal = MemoryPublicationJournal();
    final record = (await journal.reserve(intent())).record;
    expect(await journal.cancelNotSubmitted(record), isFalse);
    expect(
        (await journal
                .reserve(intent(key: '33333333-3333-4333-8333-333333333333')))
            .maySubmit,
        isFalse);
    expect(await journal.read(owner(), 'policy-a'), record);
  });

  test('memory cancellation is confined to exact known-not-submitted record',
      () async {
    final journal = MemoryPublicationJournal();
    final unknown = (await journal.reserve(intent())).record;
    final denied = await journal.markReauthenticationRequired(unknown);
    expect(await journal.cancelNotSubmitted(denied), isTrue);
    expect(await journal.read(owner(), 'policy-a'), isNull);
  });

  test('memory capacity bounds new policies but preserves existing recovery',
      () async {
    final journal = MemoryPublicationJournal();
    for (var i = 0; i < 20; i++) {
      expect((await journal.reserve(intent(policy: 'policy-$i'))).maySubmit,
          isTrue);
    }
    await expectLater(journal.reserve(intent(policy: 'policy-20')),
        throwsA(code('PUBLICATION_PENDING_CAPACITY')));
    expect(
        (await journal.reserve(intent(policy: 'policy-0'))).maySubmit, isFalse);
    expect(
        (await journal.reserve(intent(scope: owner(actor: 'adult-b'))))
            .maySubmit,
        isTrue);
  });
}
