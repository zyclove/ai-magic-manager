@TestOn('vm')
library;

import 'dart:io';
import 'package:device_access/device_access.dart';
import 'package:jose/jose.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:test/test.dart';
import 'fixtures.dart';
import 'verifier_test.dart' show failure;

AccessReceiptAcknowledgement ack(AccessReceipt receipt,
        [Map<String, dynamic> changes = const {}]) =>
    AccessReceiptAcknowledgement.fromJson({
      'documentId': receipt.documentId,
      'approvalVersion': receipt.approvalVersion,
      'deliveryAttempt': receipt.deliveryAttempt,
      'phase': receipt.phase,
      'receivedAt': now,
      'current': true,
      'evidenceStatus': 'DEVICE_REPORT_UNVERIFIED',
      'executionState': 'NOT_ENFORCED',
      ...changes
    });

void main() {
  late Directory dir;
  late Database db;
  late JsonWebKey key;
  late AccessWindowJournal journal;
  late String compact;
  int clock = now;
  bool hasBase = true;
  bool clockWorks = true;
  AccessWindowJournal create(
          {DeviceAccessScope target = scope,
          int capacity = 128,
          int requests = 256,
          JsonWebKey? trust}) =>
      AccessWindowJournal(
          database: db,
          verifier: AccessWindowVerifier(
              scope: target,
              trustedKeys: publicRing(trust ?? key),
              nowMillis: () {
                if (!clockWorks) throw StateError('clock unavailable');
                return clock;
              }),
          baselineMatches: (_) => hasBase,
          maxRequests: requests,
          maxPendingReceipts: capacity);
  AccessDocument input(
          {int attempt = 1, Map<String, dynamic> fields = const {}}) =>
      transport(compact, fields: {'deliveryAttempt': attempt, ...fields});
  AccessDocument removal({Map<String, dynamic> changes = const {}}) {
    final body = envelope({
      'documentId': policy,
      'approvalVersion': 2,
      'action': 'REMOVE_ACCESS_WINDOW',
      'approvalState': 'REVOKED',
      'documentIssuedAt': now,
      ...changes
    });
    return transport(sign(key, body), payload: body);
  }

  Future<void> reopen() async {
    await db.close();
    db = await databaseFactoryIo.openDatabase('${dir.path}/access.db');
    journal = create();
  }

  setUpAll(() => key = newKey());
  setUp(() async {
    clock = now;
    hasBase = true;
    clockWorks = true;
    dir = await Directory.systemTemp.createTemp('device-access-test-');
    db = await databaseFactoryIo.openDatabase('${dir.path}/access.db');
    journal = create();
    compact = sign(key, envelope());
  });
  tearDown(() async {
    await db.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final actual = await dir.resolveSymbolicLinks();
    if (!actual.toLowerCase().startsWith(
        '$root${Platform.pathSeparator}device-access-test-'.toLowerCase())) {
      throw StateError('Unexpected temporary directory');
    }
    await Directory(actual).delete(recursive: true);
  });
  test('commit and terminal receipt survive file database close and reopen',
      () async {
    final receipt = await journal.accept(input());
    expect(receipt.toJson(),
        {'documentId': document, 'deliveryAttempt': 1, 'phase': 'STORED'});
    await reopen();
    expect((await journal.restore())[request]!.systemEnforced, isFalse);
    expect((await journal.pendingReceipts()).single.toJson(), receipt.toJson());
  });
  test('six concurrent duplicates produce one durable terminal receipt',
      () async {
    final receipts =
        await Future.wait(List.generate(6, (_) => journal.accept(input())));
    expect(receipts.map((r) => r.key).toSet(), hasLength(1));
    expect(await journal.pendingReceipts(), hasLength(1));
  });
  test('same attempt rejection remains terminal; a new attempt can recover',
      () async {
    hasBase = false;
    final first = await journal.accept(input());
    expect(first.reasonCode, 'BASELINE_MISSING');
    expect(await journal.restore(), isEmpty);
    hasBase = true;
    expect((await journal.accept(input())).phase, 'REJECTED');
    expect(await journal.restore(), isEmpty);
    final second = await journal.accept(input(attempt: 2));
    expect(second.phase, 'STORED');
    expect((await journal.restore())[request]!.absoluteNotAfter, now + 299000);
    expect(await journal.pendingReceipts(), hasLength(2));
    await expectLater(
        journal.accept(input()), throwsA(failure('STALE_ATTEMPT')));
  });
  test(
      'historical ACK clears only its own attempt; wrong version clears nothing',
      () async {
    hasBase = false;
    final first = await journal.accept(input());
    hasBase = true;
    final second = await journal.accept(input(attempt: 2));
    await expectLater(journal.acknowledge(ack(second, {'approvalVersion': 3})),
        throwsA(failure('ACK_MISMATCH')));
    expect(await journal.pendingReceipts(), hasLength(2));
    expect(await journal.acknowledge(ack(first, {'current': false})), isTrue);
    expect((await journal.pendingReceipts()).single.key, second.key);
    expect(await journal.acknowledge(ack(first)), isFalse);
  });
  test(
      'acknowledged duplicate requeues original receipt without reviving expired grant',
      () async {
    final first = await journal.accept(input());
    await journal.acknowledge(ack(first));
    clock = now + 299000;
    expect(await journal.restore(), isEmpty);
    expect((await journal.accept(input())).toJson(), first.toJson());
    expect(await journal.restore(), isEmpty);
    expect(await journal.pendingReceipts(), hasLength(1));
  });
  test(
      'first expired document yields durable EXPIRED; observed expiry prevents rollback',
      () async {
    clock = now + 299000;
    expect((await journal.accept(input())).reasonCode, 'EXPIRED');
    await reopen();
    clock = now;
    await expectLater(journal.restore(), throwsA(failure('CLOCK_UNTRUSTED')));
  });
  test('restoration records a time floor before an expired window is omitted',
      () async {
    await journal.accept(input());
    clock = now + 299000;
    expect(await journal.restore(), isEmpty);
    await reopen();
    clock = now;
    await expectLater(journal.restore(), throwsA(failure('CLOCK_UNTRUSTED')));
  });
  test('higher removal survives restart and rejects old approved document',
      () async {
    await journal.accept(input());
    clock = now + 86400000;
    final receipt = await journal.accept(removal());
    expect(receipt.phase, 'STORED');
    await reopen();
    expect(await journal.restore(), isEmpty);
    await expectLater(
        journal.accept(input()), throwsA(failure('STALE_APPROVAL')));
  });
  test('removal is persisted even when clock rolls back or is unavailable',
      () async {
    await journal.accept(input());
    clock = now - 10000;
    clockWorks = false;
    expect((await journal.accept(removal())).phase, 'STORED');
    clockWorks = true;
    clock = now;
    await reopen();
    expect(await journal.restore(), isEmpty);
  });
  test('same approval version cannot replace the signed document', () async {
    await journal.accept(input());
    final changed = sign(key, envelope({'documentIssuedAt': now}));
    await expectLater(
        journal.accept(
            transport(changed, payload: envelope({'documentIssuedAt': now}))),
        throwsA(failure('APPROVAL_CONFLICT')));
  });
  test('higher version cannot change original scope or lifetime', () async {
    await journal.accept(input());
    for (final changes in [
      {'absoluteNotAfter': now + 300000},
      {
        'ruleIds': ['other']
      },
      {'applicationId': policy}
    ]) {
      await expectLater(journal.accept(removal(changes: changes)),
          throwsA(failure('GRANT_CHANGED')));
    }
    expect((await journal.restore()).keys, [request]);
  });
  test('even a higher UPSERT cannot resurrect a removed request', () async {
    await journal.accept(removal());
    final body = envelope({'documentId': tenant, 'approvalVersion': 3});
    await expectLater(journal.accept(transport(sign(key, body), payload: body)),
        throwsA(failure('APPROVAL_CONFLICT')));
  });
  test(
      'scope namespaces isolate registrations and current trust ring is rechecked',
      () async {
    await journal.accept(input());
    final different = DeviceAccessScope(
        issuer: scope.issuer,
        tenantId: tenant,
        subjectId: subject,
        deviceId: device,
        registrationId: policy);
    expect(await create(target: different).restore(), isEmpty);
    await expectLater(create(trust: newKey('replacement')).restore(),
        throwsA(failure('SIGNATURE_INVALID')));
  });
  test(
      'baseline is rechecked on restore without producing contradictory rejection',
      () async {
    final receipt = await journal.accept(input());
    await journal.acknowledge(ack(receipt));
    hasBase = false;
    expect(await journal.restore(), isEmpty);
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test(
      'server STORED plus missing baseline is local failure without new receipt',
      () async {
    hasBase = false;
    await expectLater(
        journal.accept(input(fields: {'deliveryState': 'STORED'})),
        throwsA(failure('BASELINE_MISSING')));
    expect(await journal.pendingReceipts(), isEmpty);
    expect(await journal.restore(), isEmpty);
  });
  test(
      'server REJECTED is preserved until a new attempt, even with available baseline',
      () async {
    final receipt = await journal.accept(input(fields: {
      'deliveryState': 'REJECTED',
      'reasonCode': 'BASELINE_MISSING',
      'retryStatus': 'AVAILABLE',
      'retryAfter': now
    }));
    expect(receipt.phase, 'REJECTED');
    expect(await journal.restore(), isEmpty);
    expect((await journal.accept(input(attempt: 2))).phase, 'STORED');
  });
  test('conflicting remote terminal state cannot overwrite a local receipt',
      () async {
    await journal.accept(input());
    await expectLater(
        journal.accept(input(fields: {
          'deliveryState': 'REJECTED',
          'reasonCode': 'STORAGE_FAILED',
          'retryStatus': 'AVAILABLE',
          'retryAfter': now
        })),
        throwsA(failure('DELIVERY_CONFLICT')));
    expect((await journal.pendingReceipts()).single.phase, 'STORED');
  });
  test('receipt capacity failure rolls back new document and time floor',
      () async {
    journal = create(capacity: 1);
    final first = await journal.accept(input());
    clock = now + 1000;
    await expectLater(
        journal.accept(removal()), throwsA(failure('STORAGE_CAPACITY')));
    clock = now;
    expect((await journal.restore()).keys, [request]);
    await journal.acknowledge(ack(first));
    await journal.accept(removal());
    expect(await journal.restore(), isEmpty);
  });
  test('request watermark capacity does not silently evict historical state',
      () async {
    journal = create(requests: 1);
    await journal.accept(removal());
    final body = envelope({'requestId': policy, 'documentId': tenant});
    await expectLater(journal.accept(transport(sign(key, body), payload: body)),
        throwsA(failure('STORAGE_CAPACITY')));
    await expectLater(
        journal.accept(input()), throwsA(failure('STALE_APPROVAL')));
  });
  test('closed database never returns a success receipt', () async {
    await db.close();
    await expectLater(
        journal.accept(input()), throwsA(failure('STORAGE_FAILURE')));
  });
  test('invalid signature and metadata never create trusted receipt targets',
      () async {
    await expectLater(
        journal.accept(transport(sign(newKey('wrong'), envelope()))),
        throwsA(failure('SIGNATURE_INVALID')));
    await expectLater(journal.accept(input(fields: {'documentId': tenant})),
        throwsA(failure('TRANSPORT_MISMATCH')));
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test(
      'invalid or unavailable time blocks new grants, without echoing exception data',
      () async {
    clockWorks = false;
    await expectLater(
        journal.accept(input()), throwsA(failure('CLOCK_UNTRUSTED')));
    clockWorks = true;
    clock = -1;
    await expectLater(
        journal.accept(input()), throwsA(failure('CLOCK_UNTRUSTED')));
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test('corrupt persisted receipt is detected before restore or posting',
      () async {
    await journal.accept(input());
    final store = stringMapStoreFactory
        .store('device_access.v1.${scope.storageKey}.requests');
    final row = (await store.record(request).get(db))!;
    final modified = Map<String, Object?>.from(row);
    modified['accepted'] = 'yes';
    await store.record(request).put(db, modified);
    await expectLater(journal.restore(), throwsA(failure('STORAGE_FAILURE')));
  });
  test('ACK parser rejects claimed enforcement and malformed correlation', () {
    const receipt =
        AccessReceipt.internal(request, document, 1, 1, 'STORED', null);
    for (final changes in [
      {'deliveryAttempt': 11},
      {'executionState': 'ENFORCED'},
      {'evidenceStatus': 'VERIFIED'},
      {'current': 'true'},
      {'receivedAt': -1}
    ]) {
      expect(() => ack(receipt, changes), throwsA(failure('ACK_INVALID')));
    }
  });
}
