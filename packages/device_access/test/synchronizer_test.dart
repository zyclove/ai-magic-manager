@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_access/device_access.dart';
import 'package:jose/jose.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:test/test.dart';
import 'fixtures.dart';
import 'transport_test.dart' show token, transportFailure;
import 'verifier_test.dart' show failure;

void main() {
  late Directory directory;
  late Database database;
  late JsonWebKey key;
  late HttpServer server;
  late AccessWindowJournal journal;
  late DeviceAccessSynchronizer sync;
  final docs = <String, Map<String, dynamic>>{};
  final bodies = <String, Map<String, dynamic>>{};
  final paths = <String>[];
  final cursors = <String?>[];
  int clock = now, postFailures = 0, retryFailures = 0, retryCalls = 0;
  bool hasBase = true, conflict = false, supersedeOnRetry = false;
  Completer<void>? documentGate;
  void add(
      [Map<String, dynamic> changes = const {},
      Map<String, dynamic> metadata = const {}]) {
    final body = envelope(changes);
    bodies[body['requestId']] = body;
    docs[body['requestId']] = {
      'requestId': body['requestId'],
      'documentId': body['documentId'],
      'approvalVersion': body['approvalVersion'],
      'action': body['action'],
      'documentIssuedAt': body['documentIssuedAt'],
      'signedDocument': sign(key, body),
      'deliveryAttempt': 1,
      'deliveryState': 'SIGNED',
      'reasonCode': null,
      'retryStatus': 'NOT_NEEDED',
      'retryAfter': null,
      ...metadata
    };
  }

  Future<void> json(HttpRequest r, Object value, {int status = 200}) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(value));
    await r.response.close();
  }

  Future<void> respond(HttpRequest r) async {
    paths.add('${r.method} ${r.uri.path}');
    expect(r.headers.value('authorization'), 'Bearer $token');
    if (r.method == 'GET' && r.uri.path.endsWith('/access-requests')) {
      final after = r.uri.queryParameters['cursor'];
      cursors.add(after);
      final limit = int.parse(r.uri.queryParameters['limit']!);
      final ids = docs.keys
          .where((id) => after == null || id.compareTo(after) > 0)
          .toList()
        ..sort();
      final page = ids.take(limit).toList();
      await json(r, {
        'items': page
            .map((id) => {
                  'requestId': id,
                  'approvalVersion': bodies[id]!['approvalVersion'],
                  'approvalState': bodies[id]!['approvalState'],
                  'absoluteNotAfter': bodies[id]!['absoluteNotAfter']
                })
            .toList(),
        'nextCursor': ids.length > limit ? page.last : null
      });
      return;
    }
    final id = r.uri.pathSegments[r.uri.pathSegments.length - 2];
    final doc = docs[id]!;
    if (r.method == 'GET') {
      if (documentGate != null) await documentGate!.future;
      await json(r, doc);
      return;
    }
    final input =
        jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
    if (r.uri.path.endsWith('/delivery-retries')) {
      retryCalls++;
      if (supersedeOnRetry) {
        supersedeOnRetry = false;
        add({
          'approvalVersion': 2,
          'documentId': tenant,
          'action': 'REMOVE_ACCESS_WINDOW',
          'approvalState': 'REVOKED'
        });
        await json(r, {'errorCode': 'ACCESS_DOCUMENT_SUPERSEDED'}, status: 409);
        return;
      }
      if (doc['deliveryAttempt'] == input['failedAttempt']) {
        doc['deliveryAttempt'] = (doc['deliveryAttempt'] as int) + 1;
        doc['deliveryState'] = 'SIGNED';
        doc['reasonCode'] = null;
        doc['retryStatus'] = 'NOT_NEEDED';
        doc['retryAfter'] = null;
      }
      if (retryFailures-- > 0) {
        await json(r, {'errorCode': 'SERVER_ERROR'}, status: 503);
        return;
      }
      await json(r, {
        'documentId': input['documentId'],
        'deliveryAttempt': input['failedAttempt'] + 1,
        'createdAt': clock,
        'current': true
      });
      return;
    }
    if (conflict) {
      await json(r, {'errorCode': 'ACCESS_RECEIPT_CONFLICT'}, status: 409);
      return;
    }
    if (input['documentId'] == doc['documentId'] &&
        input['deliveryAttempt'] == doc['deliveryAttempt']) {
      doc['deliveryState'] = input['phase'];
      doc['reasonCode'] = input['reasonCode'];
      if (input['phase'] == 'REJECTED') {
        doc['retryStatus'] = 'WAITING';
        doc['retryAfter'] ??= clock + 30000;
      }
    }
    if (postFailures-- > 0) {
      await json(r, {'errorCode': 'SERVER_ERROR'}, status: 503);
      return;
    }
    await json(r, {
      'documentId': input['documentId'],
      'approvalVersion':
          input['documentId'] == document ? 1 : doc['approvalVersion'],
      'deliveryAttempt': input['deliveryAttempt'],
      'phase': input['phase'],
      'receivedAt': clock,
      'current': input['documentId'] == doc['documentId'] &&
          input['deliveryAttempt'] == doc['deliveryAttempt'],
      'evidenceStatus': 'DEVICE_REPORT_UNVERIFIED',
      'executionState': 'NOT_ENFORCED'
    });
  }

  void create({int pageSize = 10, int maxPages = 5, int maxPosts = 128}) {
    journal = AccessWindowJournal(
        database: database,
        verifier: AccessWindowVerifier(
            scope: scope, trustedKeys: publicRing(key), nowMillis: () => clock),
        baselineMatches: (_) => hasBase);
    sync = DeviceAccessSynchronizer(
        journal: journal,
        pageSize: pageSize,
        maxPages: maxPages,
        maxReceiptPosts: maxPosts,
        transport: DeviceAccessTransport(
            apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
            credential: () async => token,
            allowLoopbackHttp: true,
            timeout: const Duration(seconds: 2)));
  }

  setUpAll(() => key = newKey());
  setUp(() async {
    docs.clear();
    bodies.clear();
    paths.clear();
    cursors.clear();
    clock = now;
    postFailures = 0;
    retryFailures = 0;
    retryCalls = 0;
    hasBase = true;
    conflict = false;
    supersedeOnRetry = false;
    documentGate = null;
    directory = await Directory.systemTemp.createTemp('access-http-sync-');
    database =
        await databaseFactoryIo.openDatabase('${directory.path}/state.db');
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) async {
      try {
        await respond(r);
      } catch (_) {
        await r.response.close();
      }
    });
    add();
    create();
  });
  tearDown(() async {
    sync.close();
    if (documentGate != null && !documentGate!.isCompleted) {
      documentGate!.complete();
    }
    await server.close(force: true);
    await database.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final actual = await directory.resolveSymbolicLinks();
    if (!actual.toLowerCase().startsWith(
        '$root${Platform.pathSeparator}access-http-sync-'.toLowerCase())) {
      throw StateError('Unexpected test directory');
    }
    await Directory(actual).delete(recursive: true);
  });
  test(
      'real network scan verifies and stores before correlated receipt acknowledgement',
      () async {
    final result = await sync.synchronize();
    expect(result.documentsStored, 1);
    expect(result.receiptsAcknowledged, 1);
    expect(result.systemEnforced, isFalse);
    expect(result.issues, isEmpty);
    expect(await journal.pendingReceipts(), isEmpty);
    expect((await journal.restore()).keys, [request]);
  });
  test('six simultaneous triggers share one bounded synchronization', () async {
    await Future.wait(List.generate(6, (_) => sync.synchronize()));
    expect(cursors, [null]);
    expect(paths.where((p) => p.startsWith('POST')), hasLength(1));
  });
  test(
      'scan checkpoint survives restart and a completed cycle starts from the beginning',
      () async {
    add({'requestId': application, 'documentId': tenant});
    sync.close();
    create(pageSize: 1, maxPages: 1);
    expect((await sync.synchronize()).hasMore, isTrue);
    sync.close();
    await database.close();
    database =
        await databaseFactoryIo.openDatabase('${directory.path}/state.db');
    create(pageSize: 1, maxPages: 1);
    expect((await sync.synchronize()).hasMore, isFalse);
    expect((await sync.synchronize()).hasMore, isTrue);
    expect(cursors, [null, request, null]);
  });
  test('an old request revoked later is found by the next complete scan',
      () async {
    await sync.synchronize();
    add({
      'approvalVersion': 2,
      'documentId': tenant,
      'action': 'REMOVE_ACCESS_WINDOW',
      'approvalState': 'REVOKED'
    });
    await sync.synchronize();
    expect(cursors, [null, null]);
    expect(await journal.restore(), isEmpty);
  });
  test('lost receipt response retains queue and recovers after file reopen',
      () async {
    postFailures = 1;
    final first = await sync.synchronize();
    expect(first.issues.map((i) => i.code), contains('SERVER_ERROR'));
    expect(await journal.pendingReceipts(), hasLength(1));
    expect(first.pendingReceipts, 1);
    expect(first.issues.single.retryable, isTrue);
    expect(first.issues.single.outcomeUnknown, isTrue);
    sync.close();
    await database.close();
    database =
        await databaseFactoryIo.openDatabase('${directory.path}/state.db');
    create();
    final second = await sync.synchronize();
    expect(second.issues, isEmpty);
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test(
      'temporary rejection respects readiness and retryAfter without extending the grant',
      () async {
    hasBase = false;
    await sync.synchronize();
    hasBase = true;
    clock = now + 29999;
    await sync.synchronize();
    expect(retryCalls, 0);
    clock++;
    final recovered = await sync.synchronize();
    expect(retryCalls, 1);
    expect(recovered.retriesCreated, 1);
    expect(recovered.issues, isEmpty);
    expect((await journal.restore())[request]!.absoluteNotAfter, now + 299000);
    expect(docs[request]!['deliveryAttempt'], 2);
    expect(docs[request]!['deliveryState'], 'STORED');
  });
  test(
      'missing baseline does not spend another server retry even after backoff',
      () async {
    hasBase = false;
    await sync.synchronize();
    clock += 60000;
    await sync.synchronize();
    expect(retryCalls, 0);
    expect(await journal.restore(), isEmpty);
  });
  test('ambiguous retry result recovers by reading current document next cycle',
      () async {
    hasBase = false;
    await sync.synchronize();
    hasBase = true;
    clock += 30000;
    retryFailures = 1;
    expect((await sync.synchronize()).issues.map((i) => i.code),
        contains('SERVER_ERROR'));
    expect(retryCalls, 1);
    expect(docs[request]!['deliveryAttempt'], 2);
    final next = await sync.synchronize();
    expect(next.issues, isEmpty);
    expect(retryCalls, 1);
    expect(docs[request]!['deliveryState'], 'STORED');
  });
  test('invalid document does not starve a later valid removal', () async {
    add({
      'requestId': application,
      'documentId': tenant,
      'approvalVersion': 2,
      'action': 'REMOVE_ACCESS_WINDOW',
      'approvalState': 'REVOKED'
    });
    docs[request]!['signedDocument'] =
        sign(newKey('untrusted'), bodies[request]!);
    final result = await sync.synchronize();
    expect(result.issues.map((i) => i.code), contains('SIGNATURE_INVALID'));
    expect(docs[application]!['deliveryState'], 'STORED');
  });
  test('conflicting historical receipt does not block fetching a later removal',
      () async {
    postFailures = 1;
    await sync.synchronize();
    conflict = true;
    add({
      'approvalVersion': 2,
      'documentId': tenant,
      'action': 'REMOVE_ACCESS_WINDOW',
      'approvalState': 'REVOKED'
    });
    final result = await sync.synchronize();
    expect(
        result.issues.map((i) => i.code), contains('ACCESS_RECEIPT_CONFLICT'));
    expect(await journal.restore(), isEmpty);
    expect(await journal.pendingReceipts(), hasLength(2));
  });
  test(
      'receipt posting has a fixed per-run budget and keeps remaining work durable',
      () async {
    add({'requestId': application, 'documentId': tenant});
    sync.close();
    create(maxPosts: 1);
    final result = await sync.synchronize();
    expect(result.receiptsAcknowledged, 1);
    expect(paths.where((p) => p.startsWith('POST')), hasLength(1));
    expect(await journal.pendingReceipts(), hasLength(1));
  });
  test('scan compare-and-set rejects an obsolete coordinator position',
      () async {
    final old = await journal.scanPosition();
    await journal.advanceScan(old, request);
    await expectLater(
        journal.advanceScan(old, null), throwsA(failure('SYNC_CONFLICT')));
    expect((await journal.scanPosition()).cursor, request);
  });
  test(
      'approval superseded during retry fetches and commits the current removal',
      () async {
    hasBase = false;
    await sync.synchronize();
    hasBase = true;
    clock += 30000;
    supersedeOnRetry = true;
    final result = await sync.synchronize();
    expect(result.issues, isEmpty);
    expect(await journal.restore(), isEmpty);
    expect(docs[request]!['approvalVersion'], 2);
    expect(docs[request]!['deliveryState'], 'STORED');
  });
  test(
      'removal storage recovery is allowed after the old deadline without a baseline',
      () async {
    hasBase = false;
    clock += 400000;
    add({
      'approvalVersion': 2,
      'documentId': tenant,
      'action': 'REMOVE_ACCESS_WINDOW',
      'approvalState': 'REVOKED'
    }, {
      'deliveryState': 'REJECTED',
      'reasonCode': 'STORAGE_FAILED',
      'retryStatus': 'AVAILABLE',
      'retryAfter': now
    });
    final result = await sync.synchronize();
    expect(result.issues, isEmpty);
    expect(result.retriesCreated, 1);
    expect(await journal.restore(), isEmpty);
  });
  test(
      'exhaustion, ending windows and permanent rejection never spend another attempt',
      () async {
    docs[request]!.addAll({
      'deliveryAttempt': 10,
      'deliveryState': 'REJECTED',
      'reasonCode': 'STORAGE_FAILED',
      'retryStatus': 'EXHAUSTED',
      'retryAfter': null
    });
    add({
      'requestId': application,
      'documentId': tenant
    }, {
      'deliveryAttempt': 9,
      'deliveryState': 'REJECTED',
      'reasonCode': 'STORAGE_FAILED',
      'retryStatus': 'WINDOW_ENDING',
      'retryAfter': null
    });
    add({
      'requestId': device,
      'documentId': subject
    }, {
      'deliveryState': 'REJECTED',
      'reasonCode': 'SIGNATURE_INVALID',
      'retryStatus': 'NOT_ALLOWED',
      'retryAfter': null
    });
    await sync.synchronize();
    expect(retryCalls, 0);
    expect(await journal.restore(), isEmpty);
  });
  test(
      'scheduling hints only retry transient failures with bounded positive delays',
      () {
    expect(
        sync.retryDelay(
            const AccessTransportFailure('DEVICE_UNAUTHENTICATED'), 1),
        isNull);
    expect(
        sync.retryDelay(
            const AccessTransportFailure('RATE_LIMITED',
                retryable: true, retryAfter: Duration.zero),
            1),
        const Duration(seconds: 1));
    expect(
        sync
            .retryDelay(
                const AccessTransportFailure('CONNECTION_FAILED',
                    retryable: true),
                31)!
            .inSeconds,
        lessThanOrEqualTo(60));
  });
  test('close blocks receipt submission after a pending download', () async {
    documentGate = Completer<void>();
    final operation = sync.synchronize();
    final expected =
        expectLater(operation, throwsA(transportFailure('CLIENT_CLOSED')));
    while (!paths.any((p) => p.endsWith('/document'))) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    sync.close();
    documentGate!.complete();
    await expected;
    expect(paths.where((p) => p.startsWith('POST')), isEmpty);
  });
}
