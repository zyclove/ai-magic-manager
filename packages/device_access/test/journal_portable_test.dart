import 'package:device_access/device_access.dart';
import 'package:jose/jose.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:test/test.dart';
import 'fixtures.dart';
import 'verifier_test.dart' show failure;

void main() {
  late Database database;
  late JsonWebKey key;
  late AccessWindowJournal journal;
  late String compact;
  int clock = now;
  bool hasBase = true;
  setUpAll(() => key = newKey());
  setUp(() async {
    clock = now;
    hasBase = true;
    // The memory factory retains a named database across close/reopen, too.
    await databaseFactoryMemory.deleteDatabase('portable');
    database = await databaseFactoryMemory.openDatabase('portable');
    journal = AccessWindowJournal(
        database: database,
        verifier: AccessWindowVerifier(
            scope: scope, trustedKeys: publicRing(key), nowMillis: () => clock),
        baselineMatches: (_) => hasBase);
    compact = sign(key, envelope());
  });
  tearDown(() => database.close());
  test(
      'portable journal commits immutable configurations and correlated receipts',
      () async {
    await journal.accept(transport(compact));
    final active = await journal.restore();
    expect(active[request]!.systemEnforced, isFalse);
    expect(() => active.clear(), throwsUnsupportedError);
    final pending = await journal.pendingReceipts();
    expect(pending.single.toJson(),
        {'documentId': document, 'deliveryAttempt': 1, 'phase': 'STORED'});
    expect(() => pending.clear(), throwsUnsupportedError);
  });
  test(
      'portable temporary rejection recovers with a new attempt and unchanged expiry',
      () async {
    hasBase = false;
    expect((await journal.accept(transport(compact))).reasonCode,
        'BASELINE_MISSING');
    hasBase = true;
    expect(
        (await journal
                .accept(transport(compact, fields: {'deliveryAttempt': 2})))
            .phase,
        'STORED');
    expect((await journal.restore())[request]!.absoluteNotAfter, now + 299000);
    expect(await journal.pendingReceipts(), hasLength(2));
  });
  test(
      'portable stored metadata cannot generate contradictory expiry rejection',
      () async {
    clock = now + 299000;
    await expectLater(
        journal.accept(transport(compact, fields: {'deliveryState': 'STORED'})),
        throwsA(failure('EXPIRED')));
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test('portable removal with a rejected transport still persists revocation',
      () async {
    await journal.accept(transport(compact));
    clock = now - 10000;
    final body = envelope({
      'documentId': tenant,
      'approvalVersion': 2,
      'action': 'REMOVE_ACCESS_WINDOW',
      'approvalState': 'REVOKED'
    });
    final receipt =
        await journal.accept(transport(sign(key, body), payload: body, fields: {
      'deliveryState': 'REJECTED',
      'reasonCode': 'STORAGE_FAILED',
      'retryStatus': 'WAITING',
      'retryAfter': now + 30000
    }));
    expect(receipt.phase, 'REJECTED');
    await expectLater(journal.restore(), throwsA(failure('CLOCK_UNTRUSTED')));
    clock = now;
    expect(await journal.restore(), isEmpty);
    await expectLater(
        journal.accept(transport(compact)), throwsA(failure('STALE_APPROVAL')));
  });
  test('portable corrupted queued receipt cannot be posted', () async {
    final receipt = await journal.accept(transport(compact));
    final store = stringMapStoreFactory
        .store('device_access.v1.${scope.storageKey}.receipts');
    final row = (await store.record(receipt.key).get(database))!;
    await store.record(receipt.key).put(database, {
      ...row,
      'receipt': {
        'requestId': request,
        'documentId': document,
        'approvalVersion': 1,
        'deliveryAttempt': 11,
        'phase': 'STORED'
      }
    });
    await expectLater(
        journal.pendingReceipts(), throwsA(failure('STORAGE_FAILURE')));
  });
  test('portable corrupted compact hash fails before configuration restoration',
      () async {
    await journal.accept(transport(compact));
    final store = stringMapStoreFactory
        .store('device_access.v1.${scope.storageKey}.requests');
    final row = (await store.record(request).get(database))!;
    await store.record(request).put(database, {...row, 'hash': 'mismatch'});
    await expectLater(journal.restore(), throwsA(failure('STORAGE_FAILURE')));
  });
  test('portable failing baseline callback returns sanitized local diagnosis',
      () async {
    journal = AccessWindowJournal(
        database: database,
        verifier: journal.verifier,
        baselineMatches: (_) => throw StateError('private baseline content'));
    await expectLater(journal.accept(transport(compact)),
        throwsA(failure('BASELINE_UNAVAILABLE')));
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test('portable capacity settings are bounded', () {
    for (final capacities in [
      [0, 1],
      [1, 0],
      [4097, 1],
      [1, 1025]
    ]) {
      expect(
          () => AccessWindowJournal(
              database: database,
              verifier: journal.verifier,
              baselineMatches: (_) => true,
              maxRequests: capacities[0],
              maxPendingReceipts: capacities[1]),
          throwsArgumentError);
    }
  });
}
