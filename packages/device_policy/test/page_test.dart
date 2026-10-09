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
  Map<String, dynamic> item(Map<String, dynamic> payload,
          {Map<String, dynamic> metadata = const {}}) =>
      {
        'id': payload['deliveryId'],
        'cursor': payload['cursor'],
        'compactJws': sign(key, payload),
        'deliveryExpiresAt': payload['deliveryExpiresAt'],
        'state': 'SERVED',
        ...metadata
      };
  ConfigurationPage page(List<Map<String, dynamic>> items,
          {int after = 0, int next = 10, bool more = false}) =>
      ConfigurationPage.fromJson({
        'items': items,
        'nextAfter': next,
        'hasMore': more,
        'serverTime': now
      }, after: after);
  setUpAll(() => key = newKey());
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('device-policy-page-');
    db = await databaseFactoryIo.openDatabase('${dir.path}/state.db');
    journal = ConfigurationJournal(
        database: db,
        verifier: ConfigurationVerifier(
            scope: scope, trustedKeys: publicRing(key), nowMillis: () => now));
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  test('valid terminal page persists every policy and final high-water gap',
      () async {
    final receipts = await journal.acceptPage(page([
      item(envelope()),
      item(envelope(
          {'policyId': registration, 'cursor': 3, 'deliveryId': version}))
    ]));
    expect(receipts, hasLength(2));
    expect(await journal.cursor(), 10);
    expect((await journal.restore()).keys.toSet(), {policy, registration});
  });
  test('empty terminal page can durably advance over superseded deliveries',
      () async {
    await journal.acceptPage(page([], next: 8));
    await db.close();
    db = await databaseFactoryIo.openDatabase('${dir.path}/state.db');
    journal = ConfigurationJournal(
        database: db,
        verifier: ConfigurationVerifier(
            scope: scope, trustedKeys: publicRing(key), nowMillis: () => now));
    expect(await journal.cursor(), 8);
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test(
      'invalid later signature leaves no earlier configuration, receipt or cursor',
      () async {
    final bad = item(envelope(
        {'policyId': registration, 'cursor': 2, 'deliveryId': version}));
    bad['compactJws'] = 'bad';
    await expectLater(journal.acceptPage(page([item(envelope()), bad])),
        throwsA(failure('SIGNATURE_INVALID')));
    expect(await journal.cursor(), 0);
    expect(await journal.restore(), isEmpty);
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test(
      'transport metadata must exactly match signed identity, cursor and expiry',
      () async {
    for (final metadata in [
      {'id': version},
      {'cursor': 2},
      {'deliveryExpiresAt': now + 1}
    ]) {
      await expectLater(
          journal.acceptPage(page([item(envelope(), metadata: metadata)])),
          throwsA(failure('TRANSPORT_MISMATCH')));
    }
    expect(await journal.cursor(), 0);
  });
  test('receipt capacity failure on later item rolls back the entire page',
      () async {
    journal = ConfigurationJournal(
        database: db,
        verifier: ConfigurationVerifier(
            scope: scope, trustedKeys: publicRing(key), nowMillis: () => now),
        maxPendingReceipts: 1);
    await expectLater(
        journal.acceptPage(page([
          item(envelope()),
          item(envelope(
              {'policyId': registration, 'cursor': 2, 'deliveryId': version}))
        ])),
        throwsA(failure('STORAGE_FAILURE')));
    expect(await journal.cursor(), 0);
    expect(await journal.restore(), isEmpty);
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test('concurrent stale pages cannot advance each others cursor', () async {
    final p = page([item(envelope())]);
    await journal.acceptPage(p);
    await expectLater(journal.acceptPage(p), throwsA(failure('SYNC_CONFLICT')));
    expect(await journal.pendingReceipts(), hasLength(1));
  });
  test('server-rejected attempts cannot be silently stored as new success',
      () async {
    await expectLater(
        journal.acceptPage(page([
          item(envelope(), metadata: {'state': 'DEVICE_REPORTED_REJECTED'})
        ])),
        throwsA(failure('SERVER_REJECTED')));
    expect(await journal.cursor(), 0);
  });
  test('duplicate policy streams in a single page are refused', () async {
    await expectLater(
        journal.acceptPage(page([
          item(envelope()),
          item(envelope({
            'cursor': 2,
            'sourceSequence': 2,
            'versionId': registration,
            'deliveryId': version
          }))
        ])),
        throwsA(failure('TRANSPORT_MISMATCH')));
    expect(await journal.cursor(), 0);
  });
  test('invalid paging order and endless empty continuation are rejected', () {
    for (final json in [
      {'items': [], 'hasMore': true, 'nextAfter': 10, 'serverTime': now},
      {
        'items': [
          item(envelope({'cursor': 2})),
          item(envelope())
        ],
        'hasMore': false,
        'nextAfter': 10,
        'serverTime': now
      },
      {
        'items': [item(envelope())],
        'hasMore': true,
        'nextAfter': 10,
        'serverTime': now
      },
      {
        'items': [],
        'hasMore': false,
        'nextAfter': 9007199254740992,
        'serverTime': now
      }
    ]) {
      expect(() => ConfigurationPage.fromJson(json, after: 0),
          throwsFormatException);
    }
  });
}
