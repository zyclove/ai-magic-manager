import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:device_policy/device_policy.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
Matcher transportFailure(String code) =>
    isA<DeviceTransportFailure>().having((e) => e.code, 'code', code);
void main() {
  test('usage report keeps its 8 MiB limit when other operations allow more',
      () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({'oversized': 'x' * (8 * 1024 * 1024)}), 200,
        headers: {'content-type': 'application/json'}));
    final reader = DeviceConfigurationTransport(
        apiRoot: Uri.parse('https://reports.example/api/v1'),
        credential: () async => token,
        client: client,
        maxResponseBytes: 16 * 1024 * 1024);
    try {
      await expectLater(
          reader
              .usageReport(from: 1, to: 1000, timeZone: 'UTC')
              .then((_) => true),
          throwsA(transportFailure('RESPONSE_INVALID')));
    } finally {
      reader.close();
      client.close();
    }
  });
  late HttpServer server;
  late DeviceConfigurationTransport transport;
  late Future<void> Function(HttpRequest) respond;
  final requests = <HttpRequest>[];
  Future<void> json(HttpRequest request, Object value,
      {int status = 200}) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind('127.0.0.1', 0);
    respond = (r) => json(
        r, {'items': [], 'nextAfter': 0, 'hasMore': false, 'serverTime': now});
    server.listen((r) async {
      requests.add(r);
      try {
        await respond(r);
      } catch (_) {
        await r.response.close();
      }
    });
    transport = DeviceConfigurationTransport(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        credential: () async => token,
        allowLoopbackHttp: true);
  });
  tearDown(() async {
    transport.close();
    await server.close(force: true);
  });
  test(
      'usage report uses a fixed read-only route and freezes the returned document',
      () async {
    respond = (r) => json(r, {
          'schemaVersion': 1,
          'devices': [
            {'status': 'NO_DATA'}
          ]
        });
    final report = await transport.usageReport(
        from: now - 86400000,
        to: now,
        timeZone: 'Asia/Shanghai',
        period: 'WEEK');
    expect(requests.single.method, 'GET');
    expect(requests.single.uri.path, '/api/v1/device-api/usage-report');
    expect(requests.single.uri.queryParameters, {
      'from': '${now - 86400000}',
      'to': '$now',
      'timeZone': 'Asia/Shanghai',
      'period': 'WEEK'
    });
    expect(requests.single.headers.value('authorization'), 'Bearer $token');
    expect(() => report['schemaVersion'] = 2, throwsUnsupportedError);
    expect(() => (report['devices'] as List).clear(), throwsUnsupportedError);
    expect(() => report['devices'][0]['status'] = 'OBSERVED',
        throwsUnsupportedError);
  });
  test('usage report validates its bounded query before requesting credentials',
      () async {
    int credentials = 0;
    final guarded = DeviceConfigurationTransport(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        credential: () async {
          credentials++;
          return token;
        },
        allowLoopbackHttp: true);
    try {
      expect(() => guarded.usageReport(from: now, to: now, timeZone: 'UTC'),
          throwsArgumentError);
      expect(
          () => guarded.usageReport(
              from: now - 33 * 86400000, to: now, timeZone: 'UTC'),
          throwsArgumentError);
      expect(() => guarded.usageReport(from: -1, to: now, timeZone: 'UTC'),
          throwsArgumentError);
      expect(
          () => guarded.usageReport(
              from: now - 1, to: now, timeZone: 'UTC&deviceId=other'),
          throwsArgumentError);
      expect(
          () => guarded.usageReport(
              from: now - 1, to: now, timeZone: 'UTC', period: 'MONTH'),
          throwsArgumentError);
      expect(credentials, 0);
      expect(requests, isEmpty);
    } finally {
      guarded.close();
    }
  });
  test('usage report preserves safe size errors without retry or server copy',
      () async {
    respond = (r) => json(
        r, {'errorCode': 'USAGE_REPORT_TOO_LARGE', 'message': token},
        status: 413);
    await expectLater(
        transport.usageReport(from: now - 1, to: now, timeZone: 'UTC'),
        throwsA(isA<DeviceTransportFailure>()
            .having((e) => e.code, 'code', 'USAGE_REPORT_TOO_LARGE')
            .having((e) => e.retryable, 'retryable', false)
            .having((e) => e.outcomeUnknown, 'outcome', false)
            .having((e) => e.toString().contains(token), 'secret disclosure',
                false)));
    expect(requests, hasLength(1));
  });
  test(
      'actual HTTP sends only the independent opaque credential and paging fields',
      () async {
    final page = await transport.pull(after: 0, limit: 2);
    expect(page.nextAfter, 0);
    expect(page.hasMore, isFalse);
    expect(requests.single.uri.path, '/api/v1/device-api/configurations');
    expect(requests.single.uri.queryParameters, {'after': '0', 'limit': '2'});
    expect(requests.single.headers.value('authorization'), 'Bearer $token');
    expect(requests.single.headers.value('cookie'), isNull);
  });
  test('JWT, absent, and malformed credentials are rejected before HTTP',
      () async {
    for (final credential in [
      null,
      'eyJ.jwt.signature',
      'short',
      '${'A' * 43}\n'
    ]) {
      final client = DeviceConfigurationTransport(
          apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
          credential: () async => credential,
          allowLoopbackHttp: true);
      await expectLater(client.pull(after: 0),
          throwsA(transportFailure('DEVICE_CREDENTIAL_UNAVAILABLE')));
      client.close();
    }
    expect(requests, isEmpty);
  });
  test('HTTP 401 is terminal and has no automatic retry', () async {
    respond = (r) => json(
        r, {'errorCode': 'DEVICE_UNAUTHENTICATED', 'message': token},
        status: 401);
    await expectLater(
        transport.pull(after: 0),
        throwsA(isA<DeviceTransportFailure>()
            .having((e) => e.code, 'code', 'DEVICE_UNAUTHENTICATED')
            .having((e) => e.retryable, 'retryable', false)));
    expect(requests, hasLength(1));
  });
  test('rate-limit hints support integer and standard HTTP-date formats',
      () async {
    final client = DeviceConfigurationTransport(
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
            client.pull(after: 0),
            throwsA(isA<DeviceTransportFailure>()
                .having((e) => e.retryable, 'retryable', true)
                .having((e) => e.retryAfter, 'retryAfter',
                    const Duration(seconds: 30))));
      }
    } finally {
      client.close();
    }
  });
  test('redirect is not followed and device credential never reaches target',
      () async {
    final target = await HttpServer.bind('127.0.0.1', 0);
    int leaked = 0;
    target.listen((r) async {
      leaked++;
      await json(r, {});
    });
    try {
      respond = (r) async {
        r.response.statusCode = 302;
        r.response.headers
            .set('location', 'http://127.0.0.1:${target.port}/capture');
        await r.response.close();
      };
      await expectLater(transport.pull(after: 0),
          throwsA(transportFailure('REDIRECT_REFUSED')));
      expect(leaked, 0);
    } finally {
      await target.close(force: true);
    }
  });
  test('credential timeout has no late network request', () async {
    final credential = Completer<String?>();
    final client = DeviceConfigurationTransport(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        credential: () => credential.future,
        allowLoopbackHttp: true,
        timeout: const Duration(milliseconds: 25));
    await expectLater(
        client.pull(after: 0), throwsA(transportFailure('NETWORK_TIMEOUT')));
    credential.complete(token);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    client.close();
    expect(requests, isEmpty);
  });
  test('timeout includes a stalled response body', () async {
    respond = (r) async {
      r.response.headers.contentType = ContentType.json;
      r.response.write('{');
      await r.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await r.response.close();
    };
    final client = DeviceConfigurationTransport(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        credential: () async => token,
        allowLoopbackHttp: true,
        timeout: const Duration(milliseconds: 35));
    await expectLater(
        client.pull(after: 0), throwsA(transportFailure('NETWORK_TIMEOUT')));
    client.close();
  });
  test('oversized body is bounded before JSON parsing', () async {
    respond = (r) async {
      r.response.headers.contentType = ContentType.json;
      r.response.write('x' * 4096);
      await r.response.close();
    };
    final client = DeviceConfigurationTransport(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        credential: () async => token,
        allowLoopbackHttp: true,
        maxResponseBytes: 1024);
    await expectLater(
        client.pull(after: 0), throwsA(transportFailure('RESPONSE_INVALID')));
    client.close();
  });
  test('malformed success response cannot masquerade as empty page', () async {
    for (final value in [
      {},
      [],
      {'items': [], 'nextAfter': 100, 'hasMore': true, 'serverTime': now}
    ]) {
      respond = (r) => json(r, value);
      await expectLater(transport.pull(after: 0),
          throwsA(transportFailure('RESPONSE_INVALID')));
    }
  });
  test('invalid roots require explicit TLS or opted-in loopback development',
      () {
    for (final url in [
      'http://example.com/api/v1',
      'http://127.0.0.1/api/v1',
      'https://user:secret@example.com/api/v1',
      'https://example.com/api/v1?next=secret',
      'https://example.com/wrong'
    ]) {
      expect(
          () => DeviceConfigurationTransport(
              apiRoot: Uri.parse(url), credential: () async => token),
          throwsArgumentError);
    }
  });
  test('closed client cannot issue requests', () async {
    transport.close();
    await expectLater(
        transport.pull(after: 0), throwsA(transportFailure('CLIENT_CLOSED')));
    expect(requests, isEmpty);
  });
}
