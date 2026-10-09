@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_access/device_access.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
Matcher transportFailure(String code) =>
    isA<AccessTransportFailure>().having((e) => e.code, 'code', code);
void main() {
  test('VM also refuses an integral value supplied with runtime double type',
      () {
    expect(
        () => AccessRetryResult.fromJson({
              'documentId': document,
              'deliveryAttempt': 2.0,
              'createdAt': now,
              'current': true
            }, documentId: document, failedAttempt: 1),
        throwsA(isA<AccessFailure>()));
  });
  late HttpServer server;
  late DeviceAccessTransport transport;
  late Future<void> Function(HttpRequest) respond;
  final requests = <HttpRequest>[];
  Future<void> json(HttpRequest r, Object value, {int status = 200}) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(value));
    await r.response.close();
  }

  DeviceAccessTransport create(
          {Future<String?> Function()? credential,
          Duration timeout = const Duration(seconds: 2),
          int size = 1048576}) =>
      DeviceAccessTransport(
          apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
          credential: credential ?? () async => token,
          allowLoopbackHttp: true,
          timeout: timeout,
          maxResponseBytes: size);
  setUp(() async {
    requests.clear();
    server = await HttpServer.bind('127.0.0.1', 0);
    respond = (r) => json(r, {'items': [], 'nextCursor': null});
    server.listen((r) async {
      requests.add(r);
      try {
        await respond(r);
      } catch (_) {
        await r.response.close();
      }
    });
    transport = create();
  });
  tearDown(() async {
    transport.close();
    await server.close(force: true);
  });
  test('actual HTTP uses independent credentials and explicit UUID page inputs',
      () async {
    expect((await transport.list(cursor: document, limit: 2)).items, isEmpty);
    expect(requests.single.uri.path, '/api/v1/device-api/access-requests');
    expect(requests.single.uri.queryParameters,
        {'cursor': document, 'limit': '2'});
    expect(requests.single.headers.value('authorization'), 'Bearer $token');
  });
  test('fresh credential lookup follows rotations', () async {
    var calls = 0;
    final other = 'B' * 43;
    final client = create(credential: () async => calls++ == 0 ? token : other);
    try {
      await client.list();
      await client.list();
    } finally {
      client.close();
    }
    expect(requests.map((r) => r.headers.value('authorization')),
        ['Bearer $token', 'Bearer $other']);
  });
  test('JWT and malformed credentials cannot reach the device endpoint',
      () async {
    for (final value in [null, 'ey.jwt.signature', 'short', '$token\n']) {
      final client = create(credential: () async => value);
      try {
        await expectLater(client.list(),
            throwsA(transportFailure('DEVICE_CREDENTIAL_UNAVAILABLE')));
      } finally {
        client.close();
      }
    }
    expect(requests, isEmpty);
  });
  test('plaintext external roots and embedded credentials are rejected', () {
    for (final url in [
      'http://example.com/api/v1',
      'https://name:secret@example.com/api/v1',
      'https://example.com/api/v1?token=secret',
      'https://example.com/other'
    ]) {
      expect(
          () => DeviceAccessTransport(
              apiRoot: Uri.parse(url),
              credential: () async => token,
              allowLoopbackHttp: true),
          throwsArgumentError);
    }
  });
  test('redirects are never followed with device credentials', () async {
    respond = (r) {
      r.response.headers.set('location', '/outside');
      return json(r, {}, status: 307);
    };
    await expectLater(
        transport.list(), throwsA(transportFailure('REDIRECT_REFUSED')));
    expect(requests, hasLength(1));
  });
  test('401 is terminal and server text is excluded from errors', () async {
    respond = (r) => json(
        r, {'errorCode': 'DEVICE_UNAUTHENTICATED', 'message': token},
        status: 401);
    await expectLater(
        transport.list(),
        throwsA(isA<AccessTransportFailure>()
            .having((e) => e.retryable, 'retryable', isFalse)
            .having((e) => e.toString(), 'text', isNot(contains(token)))));
    expect(requests, hasLength(1));
  });
  test('rate limit hints support both HTTP-date and seconds', () async {
    final client = DeviceAccessTransport(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        credential: () async => token,
        allowLoopbackHttp: true,
        retryClock: () => DateTime.utc(2026, 1, 1));
    try {
      for (final hint in ['30', 'Thu, 01 Jan 2026 00:00:30 GMT']) {
        respond = (r) {
          r.response.headers.set('retry-after', hint);
          return json(r, {'errorCode': 'RATE_LIMITED'}, status: 429);
        };
        await expectLater(
            client.list(),
            throwsA(isA<AccessTransportFailure>().having(
                (e) => e.retryAfter, 'delay', const Duration(seconds: 30))));
      }
    } finally {
      client.close();
    }
  });
  test('response size and schema bounds fail without transport retries',
      () async {
    final client = create(size: 1024);
    try {
      respond = (r) => json(r, {'padding': 'X' * 2048});
      await expectLater(
          client.list(), throwsA(transportFailure('RESPONSE_INVALID')));
      respond = (r) => json(r, {'items': [], 'nextCursor': request});
      await expectLater(
          client.list(), throwsA(transportFailure('RESPONSE_INVALID')));
    } finally {
      client.close();
    }
  });
  test('document metadata and ACK must match their requested resource',
      () async {
    final e = envelope();
    final raw = sign(newKey(), e);
    respond = (r) => json(r, {
          'documentId': document,
          'requestId': tenant,
          'approvalVersion': 1,
          'action': e['action'],
          'signedDocument': raw,
          'documentIssuedAt': e['documentIssuedAt'],
          'deliveryAttempt': 1,
          'deliveryState': 'SIGNED',
          'retryStatus': 'NOT_NEEDED'
        });
    await expectLater(transport.document(request),
        throwsA(transportFailure('RESPONSE_INVALID')));
    const receipt =
        AccessReceipt.internal(request, document, 1, 1, 'STORED', null);
    respond = (r) => json(r, {
          'documentId': document,
          'approvalVersion': 1,
          'deliveryAttempt': 2,
          'phase': 'STORED',
          'receivedAt': now,
          'current': true,
          'evidenceStatus': 'DEVICE_REPORT_UNVERIFIED',
          'executionState': 'NOT_ENFORCED'
        });
    await expectLater(transport.acknowledge(receipt),
        throwsA(transportFailure('RESPONSE_INVALID')));
  });
  test(
      'POST timeout is explicitly ambiguous and is never retried transparently',
      () async {
    final client = create(timeout: const Duration(milliseconds: 60));
    respond = (r) async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await json(r, {});
    };
    try {
      await expectLater(
          client.acknowledge(const AccessReceipt.internal(
              request, document, 1, 1, 'STORED', null)),
          throwsA(isA<AccessTransportFailure>()
              .having((e) => e.code, 'code', 'NETWORK_TIMEOUT')
              .having((e) => e.outcomeUnknown, 'unknown', isTrue)));
      expect(requests, hasLength(1));
    } finally {
      client.close();
    }
  });
  test('close aborts even while credential lookup is pending', () async {
    final pending = Completer<String?>();
    final client = create(credential: () => pending.future);
    final operation = client.list();
    final expected =
        expectLater(operation, throwsA(transportFailure('CLIENT_CLOSED')));
    client.close();
    await expected.timeout(const Duration(milliseconds: 500));
    pending.complete(token);
    expect(requests, isEmpty);
  });
  test('strict page ordering and continuation prevent skips and loops', () {
    Map<String, dynamic> ref(String id) => {
          'requestId': id,
          'approvalVersion': 1,
          'approvalState': 'APPROVED_PENDING_DELIVERY',
          'absoluteNotAfter': now + 299000
        };
    for (final data in [
      {
        'items': [ref(request), ref(request)],
        'nextCursor': null
      },
      {
        'items': [ref(request)],
        'nextCursor': document
      },
      {
        'items': [ref(document)],
        'nextCursor': null
      },
    ]) {
      expect(
          () => AccessReferencePage.fromJson(data, after: document, limit: 2),
          throwsA(isA<AccessFailure>()));
    }
  });
}
