import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_identity/device_identity.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

TypeMatcher<DeviceIdentityFailure> code(String expected) =>
    isA<DeviceIdentityFailure>().having((e) => e.code, 'code', expected);
void main() {
  late HttpServer server;
  late DeviceIdentityApi api;
  late Future<void> Function(HttpRequest) respond;
  var count = 0;
  setUp(() async {
    count = 0;
    server = await HttpServer.bind('127.0.0.1', 0);
    respond = (r) async {
      await r.drain();
      r.response.headers.contentType = ContentType.json;
      r.response.statusCode = 201;
      r.response.write('{}');
      await r.response.close();
    };
    server.listen((r) async {
      count++;
      try {
        await respond(r);
      } catch (_) {
        await r.response.close();
      }
    });
    api = DeviceIdentityApi(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        allowLoopbackHttp: true,
        timeout: const Duration(milliseconds: 400));
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
  });
  test(
      'plaintext remote, credentials in URI, fragment and ambiguous roots are refused',
      () {
    for (final root in [
      'http://example.com/api/v1',
      'https://user:secret@example.com/api/v1',
      'https://example.com/api/v1?q=x',
      'https://example.com/api/v1#x',
      'https://example.com/other'
    ]) {
      expect(() => DeviceIdentityApi(apiRoot: Uri.parse(root)),
          throwsArgumentError);
    }
  });
  test('missing and JWT credentials fail before authenticated request',
      () async {
    await expectLater(api.send(IdentityOperation.heartbeat),
        throwsA(code('DEVICE_CREDENTIAL_UNAVAILABLE')));
    await expectLater(
        api.send(IdentityOperation.heartbeat, credential: 'ey.jwt.token'),
        throwsA(code('DEVICE_CREDENTIAL_UNAVAILABLE')));
    await expectLater(api.send(IdentityOperation.claim, credential: 'T' * 43),
        throwsA(code('DEVICE_CREDENTIAL_UNAVAILABLE')));
    expect(count, 0);
  });
  test(
      'redirect cannot forward enrollment secret or bearer to another endpoint',
      () async {
    final target = await HttpServer.bind('127.0.0.1', 0);
    var forwarded = 0;
    target.listen((r) async {
      forwarded++;
      await r.response.close();
    });
    try {
      respond = (r) async {
        await r.drain();
        r.response.statusCode = 307;
        r.response.headers
            .set('location', 'http://127.0.0.1:${target.port}/capture');
        await r.response.close();
      };
      await expectLater(
          api.send(IdentityOperation.rotate, credential: 'T' * 43),
          throwsA(code('REDIRECT_REFUSED')));
      expect(forwarded, 0);
      expect(count, 1);
    } finally {
      await target.close(force: true);
    }
  });
  test('deadline covers stalled response body and unknown write outcome',
      () async {
    respond = (r) async {
      await r.drain();
      r.response.statusCode = 201;
      r.response.headers.contentType = ContentType.json;
      r.response.write('{');
      await r.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await r.response.close();
    };
    await expectLater(
        api.send(IdentityOperation.claim),
        throwsA(code('NETWORK_TIMEOUT')
            .having((e) => e.outcomeUnknown, 'unknown', true)));
    expect(count, 1);
  });
  test('oversized JSON and incorrect success phase are not accepted', () async {
    api.close();
    api = DeviceIdentityApi(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        allowLoopbackHttp: true,
        maxResponseBytes: 1024);
    respond = (r) async {
      await r.drain();
      r.response.statusCode = 201;
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({'extra': 'X' * 2048}));
      await r.response.close();
    };
    await expectLater(
        api.send(IdentityOperation.claim), throwsA(code('RESPONSE_INVALID')));
    respond = (r) async {
      await r.drain();
      r.response.statusCode = 200;
      r.response.headers.contentType = ContentType.json;
      r.response.write('{}');
      await r.response.close();
    };
    await expectLater(
        api.send(IdentityOperation.activate, credential: 'T' * 43),
        throwsA(code('RESPONSE_INVALID')));
  });
  test(
      'untrusted server copy is redacted and authentication failures never retry',
      () async {
    final secret = 'T' * 43;
    respond = (r) async {
      await r.drain();
      r.response.statusCode = 401;
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({'errorCode': secret, 'detail': secret}));
      await r.response.close();
    };
    await expectLater(
        api.send(IdentityOperation.rotate, credential: secret),
        throwsA(isA<DeviceIdentityFailure>()
            .having((e) => e.code, 'code', 'HTTP_FAILURE')
            .having((e) => e.retryable, 'retryable', false)
            .having((e) => e.toString(), 'redacted', isNot(contains(secret)))));
    expect(count, 1);
  });
  test(
      'closing aborts this request but keeps an injected SDK client caller-owned',
      () async {
    api.close();
    final client = http.Client();
    api = DeviceIdentityApi(
        apiRoot: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        allowLoopbackHttp: true,
        client: client);
    final received = Completer<void>();
    respond = (r) async {
      await r.drain();
      received.complete();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await r.response.close();
    };
    final running = api.send(IdentityOperation.claim);
    final expected = expectLater(
        running,
        throwsA(isA<DeviceIdentityFailure>()
            .having((e) => e.code, 'code', 'CLIENT_CLOSED')
            .having((e) => e.outcomeUnknown, 'unknown', true)));
    await received.future;
    api.close();
    await expected;
    respond = (r) async {
      r.response.statusCode = 204;
      await r.response.close();
    };
    try {
      final response =
          await client.get(Uri.parse('http://127.0.0.1:${server.port}/health'));
      expect(response.statusCode, 204);
    } finally {
      client.close();
    }
  });
}
