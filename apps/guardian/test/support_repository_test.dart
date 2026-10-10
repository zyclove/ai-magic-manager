import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import '../lib/core/api.dart';
import '../lib/core/support.dart';
import '../lib/core/support_repository.dart';
import 'fixtures/support.dart';
import 'diagnostic_repository_test.dart' show Client;

http.StreamedResponse response(Object body,
        {int status = 200, Map<String, String>? headers}) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status,
        headers: headers ??
            {'content-type': 'application/json', 'cache-control': 'no-store'});
SupportRepository repo(Client client,
        {bool Function()? current,
        Duration timeout = const Duration(seconds: 25)}) =>
    SupportRepository(
        api: Api(() async => client),
        actor: owner,
        tenant: tenant,
        current: current ?? () => true,
        timeout: timeout);
void main() {
  test('resolve puts secret only in bounded POST body and disables redirects',
      () async {
    final client = Client((r) async {
      expect(r.method, 'POST');
      expect(r.url.toString(), isNot(contains(code)));
      expect(r.followRedirects, isFalse);
      expect(jsonDecode((r as http.Request).body), {'code': code});
      return response(pairingFixture());
    });
    expect((await repo(client).resolve(code)).recipientActorId, recipient);
    expect(client.closed, isFalse);
  });
  test('create retry preserves exact body version and idempotency key',
      () async {
    final requests = <http.Request>[];
    final client = Client((r) async {
      requests.add(r as http.Request);
      if (requests.length == 1) throw http.ClientException('offline');
      return response(grantFixture(), status: 201);
    });
    final draft = SupportGrantDraft(
        tenantId: tenant,
        deviceId: device,
        registrationId: registration,
        recipientActorId: recipient,
        pairingCode: code,
        deviceVersion: 3,
        durationMinutes: 60,
        diagnosticTypes: ['DEVICE_STATUS']);
    await expectLater(
        repo(client).createGrant(draft), throwsA(isA<ApiFailure>()));
    expect((await repo(client).createGrant(draft)).id, grantId);
    expect(requests[0].body, requests[1].body);
    expect(requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key']);
    expect(requests[1].headers['If-Match'], '"3"');
  });
  test('mismatched creation scope or recipient is discarded', () async {
    final draft = SupportGrantDraft(
        tenantId: tenant,
        deviceId: device,
        registrationId: registration,
        recipientActorId: recipient,
        pairingCode: code,
        deviceVersion: 0,
        durationMinutes: 60,
        diagnosticTypes: ['DEVICE_STATUS']);
    for (final entry in {
      'recipientActorId': owner,
      'registrationId': device,
      'creatorActorId': recipient,
      'diagnosticTypes': ['CAPABILITIES']
    }.entries) {
      final client = Client((_) async =>
          response(grantFixture()..[entry.key] = entry.value, status: 201));
      await expectLater(
          repo(client).createGrant(draft),
          throwsA(isA<ApiFailure>()
              .having((e) => e.code, 'code', 'INVALID_SUPPORT_RESPONSE')));
    }
  });
  test('no stale scope request and late body cancellation', () async {
    var calls = 0, current = true, cancelled = false;
    final pending = Completer<http.StreamedResponse>();
    final client = Client((_) {
      calls++;
      return pending.future;
    });
    await expectLater(repo(client, current: () => false).resolve(code),
        throwsA(isA<ApiFailure>()));
    expect(calls, 0);
    final load = repo(client, current: () => current).resolve(code);
    final checked = expectLater(
        load,
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'WORKSPACE_CHANGED')));
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
  test('stream size bounded and timeout cancels late response', () async {
    var cancelled = false;
    late StreamController<List<int>> body;
    body = StreamController(onListen: () {
      body.add(List.filled(131073, 32));
    }, onCancel: () {
      cancelled = true;
    });
    await expectLater(
        repo(Client((_) async => http.StreamedResponse(body.stream, 200)))
            .resolve(code),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'INVALID_SUPPORT_RESPONSE')));
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    await body.close();
    final pending = Completer<http.StreamedResponse>();
    final client = Client((_) => pending.future);
    await expectLater(
        repo(client, timeout: const Duration(milliseconds: 5)).resolve(code),
        throwsA(
            isA<ApiFailure>().having((e) => e.code, 'code', 'NETWORK_ERROR')));
    cancelled = false;
    final lateBody = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    pending.complete(http.StreamedResponse(lateBody.stream, 200));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(cancelled, isTrue);
    expect(client.closed, isFalse);
    await lateBody.close();
  });
  test('unsafe errors, redirects and cacheable success are rejected', () async {
    final unsafe = repo(Client((_) async => response(
        {'errorCode': 'SECRET', 'correlationId': 'SECRET'},
        status: 502)));
    await expectLater(
        unsafe.resolve(code),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'REQUEST_FAILED')
            .having((e) => e.correlationId, 'correlation', isNull)));
    for (final value in [
      response(pairingFixture(), status: 302),
      response(pairingFixture(), headers: {'content-type': 'application/json'})
    ]) {
      await expectLater(repo(Client((_) async => value)).resolve(code),
          throwsA(isA<ApiFailure>()));
    }
  });
}
