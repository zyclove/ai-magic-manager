import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import '../lib/core/api.dart';
import '../lib/core/diagnostic_repository.dart';
import 'fixtures/diagnostic.dart' show fixture, tenant, device, registration;

class Client extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  Client(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() {
    closed = true;
  }
}

http.StreamedResponse response(Object body,
        {int status = 200, String type = 'application/json'}) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status,
        headers: {'content-type': type, 'cache-control': 'no-store'});

DiagnosticRepository repository(Client client,
        {bool Function()? current,
        Duration timeout = const Duration(seconds: 25)}) =>
    DiagnosticRepository(
        api: Api(() async => client, baseUrl: 'http://localhost:8082/api/v1'),
        tenantId: tenant,
        deviceId: device,
        registrationId: registration,
        current: current ?? () => true,
        timeout: timeout);

TypeMatcher<ApiFailure> failure(String code) =>
    isA<ApiFailure>().having((e) => e.code, 'code', code);

void main() {
  test(
      'loads only exact device route, disables redirects, preserves shared client',
      () async {
    final client = Client((request) async {
      expect(request.method, 'GET');
      expect(request.url.path,
          '/api/v1/tenants/$tenant/devices/$device/diagnostic-preview');
      expect(request.followRedirects, isFalse);
      return response(fixture());
    });
    final value = await repository(client).load();
    expect(value.registrationId, registration);
    expect(client.closed, isFalse);
  });
  test('does not start a stale workspace request', () async {
    var calls = 0;
    final client = Client((_) async {
      calls++;
      return response(fixture());
    });
    await expectLater(repository(client, current: () => false).load(),
        throwsA(failure('WORKSPACE_CHANGED')));
    expect(calls, 0);
  });
  test('discards late response after workspace changes and cancels body',
      () async {
    var current = true, cancelled = false;
    final pending = Completer<http.StreamedResponse>();
    final client = Client((_) => pending.future);
    final result = repository(client, current: () => current).load();
    final checked = expectLater(result, throwsA(failure('WORKSPACE_CHANGED')));
    await Future<void>.delayed(Duration.zero);
    current = false;
    final body = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    pending.complete(http.StreamedResponse(body.stream, 200));
    await checked;
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    await body.close();
  });
  test('bounds streamed bytes even without declared length', () async {
    var cancelled = false;
    late StreamController<List<int>> body;
    body = StreamController(onListen: () {
      body.add(List.filled(512 * 1024 + 1, 32));
    }, onCancel: () {
      cancelled = true;
    });
    final client = Client((_) async => http.StreamedResponse(body.stream, 200,
        headers: {'content-type': 'application/json'}));
    await expectLater(repository(client).load(),
        throwsA(failure('INVALID_DIAGNOSTIC_RESPONSE')));
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    await body.close();
  });
  test('rejects oversized declared length before reading bytes', () async {
    var cancelled = false;
    final body = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    final client = Client((_) async =>
        http.StreamedResponse(body.stream, 200, contentLength: 524289));
    await expectLater(repository(client).load(),
        throwsA(failure('INVALID_DIAGNOSTIC_RESPONSE')));
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    await body.close();
  });
  test('rejects wrong content type and malformed JSON', () async {
    final wrongType =
        Client((_) async => response(fixture(), type: 'text/html'));
    await expectLater(repository(wrongType).load(),
        throwsA(failure('INVALID_DIAGNOSTIC_RESPONSE')));
    final malformed = Client((_) async => http.StreamedResponse(
        Stream.value([0xff]), 200,
        headers: {'content-type': 'application/json'}));
    await expectLater(repository(malformed).load(),
        throwsA(failure('INVALID_DIAGNOSTIC_RESPONSE')));
  });
  test('returns stable known error and discards untrusted error text',
      () async {
    final auth = Client(
        (_) async => response({'errorCode': 'REAUTH_REQUIRED'}, status: 401));
    await expectLater(
        repository(auth).load(), throwsA(failure('REAUTH_REQUIRED')));
    final unsafe = Client((_) async => response(
        {'errorCode': 'SECRET_URL', 'correlationId': 'SECRET'},
        status: 502));
    await expectLater(
        repository(unsafe).load(),
        throwsA(failure('REQUEST_FAILED')
            .having((ApiFailure e) => e.correlationId, 'correlation', isNull)));
  });
  test('timeout releases late response and keeps shared client usable',
      () async {
    final pending = Completer<http.StreamedResponse>();
    final client = Client((_) => pending.future);
    await expectLater(
        repository(client, timeout: const Duration(milliseconds: 10)).load(),
        throwsA(failure('NETWORK_ERROR')));
    var cancelled = false;
    final body = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    pending.complete(http.StreamedResponse(body.stream, 200));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(cancelled, isTrue);
    expect(client.closed, isFalse);
    await body.close();
  });
}
