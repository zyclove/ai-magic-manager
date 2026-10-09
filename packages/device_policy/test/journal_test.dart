import 'dart:io';
import 'package:device_policy/device_policy.dart';
import 'package:jose/jose.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:test/test.dart';
import 'fixtures.dart';
import 'verifier_test.dart' show failure;

void main() {
  late Directory dir;
  late Database db;
  late JsonWebKey key;
  late ConfigurationJournal journal;
  int clock = now;
  ConfigurationJournal create(
          {DevicePolicyScope target = scope, int capacity = 128}) =>
      ConfigurationJournal(
          database: db,
          verifier: ConfigurationVerifier(
              scope: target,
              trustedKeys: publicRing(key),
              nowMillis: () => clock),
          maxPendingReceipts: capacity);
  setUpAll(() => key = newKey());
  setUp(() async {
    clock = now;
    dir = await Directory.systemTemp.createTemp('device-policy-test-');
    db = await databaseFactoryIo.openDatabase('${dir.path}/policy.db');
    journal = create();
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  test('stored state and pending receipt survive actual close/reopen',
      () async {
    final receipt = await journal.accept(sign(key, envelope()));
    expect(receipt.toJson()['stage'], 'STORED');
    expect(receipt.toJson()['reason'], isNull);
    await db.close();
    db = await databaseFactoryIo.openDatabase('${dir.path}/policy.db');
    journal = create();
    expect(await journal.cursor(), 1);
    expect((await journal.restore())[policy]!.document!['name'], '学习时间');
    expect((await journal.pendingReceipts()).single.toJson(), receipt.toJson());
  });
  test('concurrent duplicate reception yields one immutable receipt', () async {
    final raw = sign(key, envelope());
    final receipts =
        await Future.wait(List.generate(6, (_) => journal.accept(raw)));
    expect(receipts.map((r) => r.receiptId).toSet(), hasLength(1));
    expect(await journal.pendingReceipts(), hasLength(1));
  });
  test(
      'expiry during receipt retry does not discard an already saved configuration',
      () async {
    final raw = sign(key, envelope());
    final receipt = await journal.accept(raw);
    await journal.acknowledge(receipt.receiptId);
    clock = now + 86400000;
    expect((await journal.restore()).keys, [policy]);
    expect((await journal.accept(raw)).receiptId, receipt.receiptId);
  });
  test('new transport attempt may repeat content sequence and cursor',
      () async {
    await journal.accept(sign(key, envelope()));
    final receipt = await journal.accept(sign(
        key,
        envelope({
          'deliveryId': version,
          'issuedAt': now,
          'deliveryExpiresAt': now + 120000
        })));
    expect(receipt.deliveryId, version);
    expect(await journal.cursor(), 1);
  });
  test('same immutable version cannot change content', () async {
    await journal.accept(sign(key, envelope()));
    final doc = Map<String, dynamic>.from(envelope()['document'])
      ..['name'] = 'changed';
    await expectLater(
        journal.accept(
            sign(key, envelope({'deliveryId': version, 'document': doc}))),
        throwsA(failure('OLDER_VERSION')));
    expect((await journal.restore())[policy]!.document!['name'], '学习时间');
  });
  test('same delivery ID cannot name a different signed attempt', () async {
    await journal.accept(sign(key, envelope()));
    await expectLater(
        journal.accept(sign(key,
            envelope({'issuedAt': now, 'deliveryExpiresAt': now + 120000}))),
        throwsA(failure('OLDER_VERSION')));
    expect(await journal.pendingReceipts(), hasLength(1));
  });
  test('policy stream capacity fails without advancing the cursor', () async {
    journal = ConfigurationJournal(
        database: db,
        verifier: ConfigurationVerifier(
            scope: scope, trustedKeys: publicRing(key), nowMillis: () => clock),
        maxPolicyStreams: 1);
    await journal.accept(sign(key, envelope()));
    await expectLater(
        journal.accept(sign(
            key,
            envelope({
              'policyId': registration,
              'cursor': 2,
              'deliveryId': version
            }))),
        throwsA(failure('STORAGE_FAILURE')));
    expect(await journal.cursor(), 1);
    expect((await journal.restore()).keys, [policy]);
  });
  test(
      'removal keeps tombstone so old configuration cannot revive after restart',
      () async {
    final old = sign(key, envelope());
    await journal.accept(old);
    await journal.accept(sign(
        key,
        envelope({
          'action': 'REMOVE_CONFIGURATION',
          'document': null,
          'sourceSequence': 2,
          'cursor': 2,
          'versionId': device,
          'deliveryId': version
        })));
    await db.close();
    db = await databaseFactoryIo.openDatabase('${dir.path}/policy.db');
    journal = create();
    expect(await journal.restore(), isEmpty);
    await expectLater(journal.accept(old), throwsA(failure('OLDER_VERSION')));
    expect(await journal.cursor(), 2);
  });
  test('receipt capacity prevents partially saved policy and cursor', () async {
    journal = create(capacity: 1);
    await journal.accept(sign(key, envelope()));
    final raw = sign(
        key,
        envelope({
          'sourceSequence': 2,
          'cursor': 2,
          'versionId': device,
          'deliveryId': version
        }));
    await expectLater(journal.accept(raw), throwsA(failure('STORAGE_FAILURE')));
    expect(await journal.cursor(), 1);
    expect((await journal.restore())[policy]!.sourceSequence, 1);
    final receipt = (await journal.pendingReceipts()).single;
    await journal.acknowledge(receipt.receiptId);
    await journal.accept(raw);
    expect(await journal.cursor(), 2);
  });
  test(
      'different device registration has an independent cursor and database namespace',
      () async {
    await journal.accept(sign(key, envelope()));
    final other = create(
        target: DevicePolicyScope(
            issuer: 'ai-manager',
            tenantId: tenant,
            deviceId: device,
            registrationId: policy));
    expect(await other.cursor(), 0);
    expect(await other.restore(), isEmpty);
    await expectLater(other.accept(sign(key, envelope())),
        throwsA(failure('IDENTITY_MISMATCH')));
    expect(await other.pendingReceipts(), isEmpty);
  });
  test('local clock rollback cannot make a new first delivery timely',
      () async {
    await journal.accept(sign(key, envelope()));
    clock = now - 1000;
    await expectLater(
        journal.accept(sign(
            key,
            envelope({
              'sourceSequence': 2,
              'cursor': 2,
              'versionId': device,
              'deliveryId': version
            }))),
        throwsA(failure('CLOCK_UNTRUSTED')));
    expect(await journal.cursor(), 1);
    expect((await journal.restore())[policy]!.systemEnforced, isFalse);
  });
  test('corrupt stored signed content is detected on restoration', () async {
    await journal.accept(sign(key, envelope()));
    final store = stringMapStoreFactory
        .store('device_policy.v1.${scope.storageKey}.policies');
    final row = (await store.record(policy).get(db))!;
    await store.record(policy).put(db, {...row, 'compact': 'corrupted'});
    await expectLater(journal.restore(), throwsA(failure('SIGNATURE_INVALID')));
  });
  test('revoking a public key prevents restoration without erasing old state',
      () async {
    await journal.accept(sign(key, envelope()));
    final rotated = ConfigurationJournal(
        database: db,
        verifier: ConfigurationVerifier(
            scope: scope,
            trustedKeys: publicRing(newKey('next-key')),
            nowMillis: () => clock));
    await expectLater(rotated.restore(), throwsA(failure('SIGNATURE_INVALID')));
    expect((await journal.restore()).keys, [policy]);
  });
  test('closed database produces storage failure and no stored success',
      () async {
    await db.close();
    await expectLater(journal.accept(sign(key, envelope())),
        throwsA(failure('STORAGE_FAILURE')));
    db = await databaseFactoryIo.openDatabase('${dir.path}/policy.db');
    journal = create();
    expect(await journal.cursor(), 0);
    expect(await journal.restore(), isEmpty);
  });
}
