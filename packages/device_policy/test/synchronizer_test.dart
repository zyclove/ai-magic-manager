import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_policy/device_policy.dart';
import 'package:jose/jose.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:test/test.dart';
import 'fixtures.dart';
import 'transport_test.dart' show token, transportFailure;

void main() {
  late HttpServer server;
  late Directory dir;
  late Database db;
  late ConfigurationJournal journal;
  late DeviceConfigurationSynchronizer sync;
  late JsonWebKey key;
  late Future<void> Function(HttpRequest) respond;
  final paths = <String>[], bodies = <Map<String, dynamic>>[];
  Map<String, dynamic> item(Map<String, dynamic> body) => {
        'id': body['deliveryId'],
        'cursor': body['cursor'],
        'compactJws': sign(key, body),
        'deliveryExpiresAt': body['deliveryExpiresAt'],
        'state': 'SERVED'
      };
  Future<void> json(HttpRequest r, Object value, {int status = 200}) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(value));
    await r.response.close();
  }

  Future<void> defaultReply(HttpRequest r) async {
    if (r.method == 'POST') {
      final body = Map<String, dynamic>.from(
          jsonDecode(await utf8.decoder.bind(r).join()));
      bodies.add(body);
      await json(r, {
        'id': body['receiptId'],
        'state': 'DEVICE_REPORTED_STORED',
        'historical': false,
        'evidenceStatus': 'DEVICE_REPORT_NOT_EXECUTION',
        'receivedAt': now
      });
    } else {
      final after = int.parse(r.uri.queryParameters['after']!);
      await json(r, {
        'items': after == 0 ? [item(envelope())] : [],
        'nextAfter': 1,
        'hasMore': false,
        'serverTime': now
      });
    }
  }

  setUpAll(() => key = newKey());
  setUp(() async {
    paths.clear();
    bodies.clear();
    dir = await Directory.systemTemp.createTemp('device-policy-sync-');
    db = await databaseFactoryIo.openDatabase('${dir.path}/state.db');
    journal = ConfigurationJournal(
        database: db,
        verifier: ConfigurationVerifier(
            scope: scope, trustedKeys: publicRing(key), nowMillis: () => now));
    server = await HttpServer.bind('127.0.0.1', 0);
    respond = defaultReply;
    server.listen((r) async {
      paths.add('${r.method} ${r.uri.path}');
      try {
        await respond(r);
      } catch (_) {
        await r.response.close();
      }
    });
    sync = DeviceConfigurationSynchronizer(
        journal: journal,
        transport: DeviceConfigurationTransport(
            apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
            credential: () async => token,
            allowLoopbackHttp: true,
            timeout: const Duration(seconds: 10)));
  });
  tearDown(() async {
    sync.close();
    await server.close(force: true);
    await db.close();
    await dir.delete(recursive: true);
  });
  test(
      'actual network pull verifies, commits and sends STORED without enforcement claim',
      () async {
    final result = await sync.synchronize();
    expect(result.cursor, 1);
    expect(result.pages, 1);
    expect(result.receiptsAcknowledged, 1);
    expect(result.systemEnforced, isFalse);
    expect(await journal.pendingReceipts(), isEmpty);
    expect((await journal.restore()).keys, [policy]);
    expect(bodies.single['stage'], 'STORED');
  });
  test('simultaneous triggers share one in-flight synchronization', () async {
    final results =
        await Future.wait(List.generate(6, (_) => sync.synchronize()));
    expect(results.every((r) => r.cursor == 1), isTrue);
    expect(paths.where((p) => p.startsWith('GET')), hasLength(1));
    expect(bodies, hasLength(1));
  });
  test('bounded work resumes from durable cursor on the next trigger',
      () async {
    sync.close();
    sync = DeviceConfigurationSynchronizer(
        journal: journal,
        pageSize: 1,
        maxPages: 1,
        transport: DeviceConfigurationTransport(
            apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
            credential: () async => token,
            allowLoopbackHttp: true));
    final requested = <int>[];
    respond = (r) async {
      if (r.method == 'POST') {
        await defaultReply(r);
        return;
      }
      final after = int.parse(r.uri.queryParameters['after']!);
      requested.add(after);
      expect(r.uri.queryParameters['limit'], '1');
      final cursor = after + 1;
      final body = envelope({
        'policyId': cursor == 1 ? policy : version,
        'deliveryId': cursor == 1 ? delivery : registration,
        'cursor': cursor
      });
      await json(r, {
        'items': [item(body)],
        'nextAfter': cursor,
        'hasMore': cursor == 1,
        'serverTime': now
      });
    };
    final first = await sync.synchronize();
    expect(first.pages, 1);
    expect(first.cursor, 1);
    expect(first.hasMore, isTrue);
    final second = await sync.synchronize();
    expect(second.pages, 1);
    expect(second.cursor, 2);
    expect(second.hasMore, isFalse);
    expect(requested, [0, 1]);
    expect(await journal.restore(), hasLength(2));
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test('unconfirmed receipt is flushed before another page is pulled',
      () async {
    await journal.accept(sign(key, envelope()));
    await sync.synchronize();
    expect(paths.first, 'POST /api/v1/device-api/configuration-receipts');
    expect(paths.last, 'GET /api/v1/device-api/configurations');
  });
  test('lost ACK is replayed with original ID and body after reconnect',
      () async {
    bool lose = true;
    respond = (r) async {
      if (r.method == 'POST' && lose) {
        final body = Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(r).join()));
        bodies.add(body);
        // The request reached the server; no acknowledgement reaches the client.
        final socket = await r.response.detachSocket(writeHeaders: false);
        socket.destroy();
      } else {
        await defaultReply(r);
      }
    };
    await expectLater(
        sync.synchronize(),
        throwsA(isA<DeviceTransportFailure>()
            .having((e) => e.outcomeUnknown, 'outcomeUnknown', true)));
    expect(await journal.pendingReceipts(), hasLength(1));
    final original = bodies.single;
    lose = false;
    await sync.synchronize();
    expect(bodies.last, original);
    expect(await journal.pendingReceipts(), isEmpty);
  });
  test('wrong ACK cannot delete a pending receipt', () async {
    respond = (r) async {
      if (r.method == 'POST') {
        await r.drain();
        await json(r, {
          'id': version,
          'state': 'DEVICE_REPORTED_STORED',
          'historical': false,
          'evidenceStatus': 'DEVICE_REPORT_NOT_EXECUTION',
          'receivedAt': now
        });
      } else {
        await defaultReply(r);
      }
    };
    await expectLater(
        sync.synchronize(), throwsA(transportFailure('RESPONSE_INVALID')));
    expect(await journal.pendingReceipts(), hasLength(1));
  });
  test('closing during POST keeps unknown outcome and original pending receipt',
      () async {
    final received = Completer<void>();
    respond = (r) async {
      if (r.method == 'POST') {
        bodies.add(Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(r).join())));
        received.complete();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await r.response.close();
      } else {
        await defaultReply(r);
      }
    };
    final running = sync.synchronize();
    final expected = expectLater(
        running,
        throwsA(isA<DeviceTransportFailure>()
            .having((e) => e.code, 'code', 'CLIENT_CLOSED')
            .having((e) => e.outcomeUnknown, 'outcomeUnknown', true)));
    await received.future;
    sync.close();
    await expected;
    final pending = await journal.pendingReceipts();
    expect(pending, hasLength(1));
    expect(pending.single.toJson(), bodies.single);
    expect(await journal.cursor(), 1);
  });
  test(
      'credential revocation stops cloud requests while preserving last saved state',
      () async {
    await sync.synchronize();
    respond =
        (r) => json(r, {'errorCode': 'DEVICE_UNAUTHENTICATED'}, status: 401);
    await expectLater(sync.synchronize(),
        throwsA(transportFailure('DEVICE_UNAUTHENTICATED')));
    expect((await journal.restore()).keys, [policy]);
  });
  test(
      'retry delays respect rate limit hint and never retry authentication failures',
      () {
    expect(
        sync.retryDelay(
            const DeviceTransportFailure('DEVICE_UNAUTHENTICATED', status: 401),
            1),
        isNull);
    expect(
        sync.retryDelay(
            const DeviceTransportFailure('HTTP_FAILURE',
                status: 429,
                retryable: true,
                retryAfter: Duration(seconds: 30)),
            1),
        const Duration(seconds: 30));
    final delay = sync.retryDelay(
        const DeviceTransportFailure('NETWORK_TIMEOUT', retryable: true), 1)!;
    expect(delay.inMilliseconds, inInclusiveRange(500, 60000));
  });
}
