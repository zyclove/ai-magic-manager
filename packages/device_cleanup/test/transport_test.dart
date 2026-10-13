import 'dart:async';
import 'dart:convert';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:device_identity/device_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  CleanupCommandClient client(
          Future<http.Response> Function(http.Request) handler,
          {Duration timeout = const Duration(seconds: 2)}) =>
      CleanupCommandClient(
          scope: scope,
          apiRoot: Uri.parse('https://cleanup.example/api/v1'),
          nowMillis: () => f.now,
          timeout: timeout,
          maxResponseBytes: 1024,
          client: MockClient(handler),
          proofFactory: (action, id) async {
            final header = base64Url
                .encode(utf8.encode(jsonEncode({
                  'alg': 'ES256',
                  'typ': 'aimanager-cleanup-auth+jwt',
                  'kid': registration
                })))
                .replaceAll('=', '');
            return CleanupProof('$header.e30.AA', scope.keyThumbprint);
          });
  Matcher failure(String code, bool unknown) => isA<CleanupFailure>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.outcomeUnknown, 'outcomeUnknown', unknown);

  for (final status in [302, 401, 403, 404, 500]) {
    for (final writing in [false, true]) {
      test(
          '${writing ? 'write' : 'read'} status $status preserves outcome classification',
          () async {
        final transport = client((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.url.origin, 'https://cleanup.example');
          return http.Response('{}', status,
              headers: {'content-type': 'application/json'});
        });
        final code = status == 302
            ? 'CLEANUP_REDIRECT_REFUSED'
            : [401, 403, 404].contains(status)
                ? 'CLEANUP_NOT_AVAILABLE'
                : 'CLEANUP_SERVICE_UNAVAILABLE';
        final receipt = CleanupReceipt(
            await f.verified(), tenant, CleanupReceiptStage.received);
        await expectLater(
            writing
                ? transport.submitReceipt(receipt)
                : transport.fetchAndVerify(),
            throwsA(failure(code, writing)));
        transport.close();
      });
    }
  }
  for (final response in [
    http.Response('X' * 2048, 200,
        headers: {'content-type': 'application/json'}),
    http.Response('{}', 200),
    http.Response('[]', 200, headers: {'content-type': 'application/json'})
  ]) {
    test(
        'malformed or oversized acknowledgement keeps write outcome unknown ${response.body.length}/${response.headers}',
        () async {
      final transport = client((request) async => response);
      final receipt = CleanupReceipt(
          await f.verified(), tenant, CleanupReceiptStage.received);
      await expectLater(transport.submitReceipt(receipt),
          throwsA(failure('CLEANUP_RESPONSE_INVALID', true)));
    });
  }
  test('dispatched write timeout is unknown and exposes no raw response',
      () async {
    final gate = Completer<http.Response>();
    final sent = Completer<void>();
    final transport = client((request) {
      sent.complete();
      return gate.future;
    }, timeout: const Duration(milliseconds: 50));
    final receipt = CleanupReceipt(
        await f.verified(), tenant, CleanupReceiptStage.received);
    final outcome = transport.submitReceipt(receipt);
    final check =
        expectLater(outcome, throwsA(failure('CLEANUP_NETWORK_TIMEOUT', true)));
    await sent.future;
    await check;
    gate.complete(jsonResponse(f.ack(receipt.body)));
    transport.close();
  });
  test('closed client performs no transport request', () async {
    var requests = 0;
    final transport = client((request) async {
      requests++;
      return jsonResponse({});
    })
      ..close();
    await expectLater(transport.fetchAndVerify(),
        throwsA(failure('CLEANUP_CLIENT_CLOSED', false)));
    expect(requests, 0);
  });
}
