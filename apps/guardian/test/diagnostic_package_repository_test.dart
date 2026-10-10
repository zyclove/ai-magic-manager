import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import '../lib/core/api.dart';
import '../lib/core/support.dart';
import '../lib/core/diagnostic_package.dart';
import '../lib/core/diagnostic_package_repository.dart';
import 'fixtures/diagnostic_package.dart';
import 'fixtures/diagnostic.dart' as diagnostic;
import 'fixtures/support.dart' show grantFixture;

class PackageClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  PackageClient(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() {
    closed = true;
  }
}

http.StreamedResponse response(Object value,
        {int status = 200, Map<String, String>? headers}) =>
    http.StreamedResponse(
        Stream.value(
            value is Uint8List ? value : utf8.encode(jsonEncode(value))),
        status,
        headers: headers ??
            {'content-type': 'application/json', 'cache-control': 'no-store'});
DiagnosticPackageRepository repository(PackageClient client,
        {bool received = false, bool Function()? current}) =>
    DiagnosticPackageRepository(
        api: Api(() async => client),
        actor: received ? recipient : owner,
        tenant: received ? null : tenant,
        received: received,
        current: current ?? () => true,
        clock: () => diagnostic.now);
DiagnosticPackage job(
        {bool received = false, String state = 'READY', Json? value}) =>
    DiagnosticPackage.parse(
        value ?? packageFixture(received: received, state: state),
        actor: received ? recipient : owner,
        mode: received ? 'SUPPORT_GRANT' : 'ADMIN',
        tenant: received ? null : tenant);
void main() {
  test('creation retries preserve original device scope version and key',
      () async {
    final requests = <http.Request>[];
    final client = PackageClient((r) async {
      requests.add(r as http.Request);
      if (requests.length == 1) throw http.ClientException('offline');
      return response(packageFixture(), status: 202);
    });
    final repo = repository(client),
        draft = DiagnosticPackageDraft.admin(
            deviceId: device, registrationId: registration, deviceVersion: 3);
    await expectLater(repo.create(draft), throwsA(isA<ApiFailure>()));
    expect((await repo.create(draft)).id, packageId);
    expect(requests[0].body, requests[1].body);
    expect(requests[1].headers['Idempotency-Key'], draft.key);
    expect(requests[1].headers['If-Match'], '"3"');
    expect(requests[1].followRedirects, isFalse);
    expect(client.closed, isFalse);
  });
  test('received creation uses the bound grant without a wider editable scope',
      () async {
    final grant = SupportGrant.parse(grantFixture(now: diagnostic.now - 1000));
    final client = PackageClient((r) async {
      expect(r.url.path, '/api/v1/support/grants/$grantId/diagnostic-packages');
      expect((r as http.Request).body, '');
      return response(packageFixture(received: true), status: 202);
    });
    expect(
        (await repository(client, received: true)
                .create(DiagnosticPackageDraft.received(grant)))
            .grantId,
        grantId);
    final wrong = SupportGrant.parse(
        grantFixture(now: diagnostic.now - 1000)..['recipientActorId'] = owner);
    await expectLater(
        repository(client, received: true)
            .create(DiagnosticPackageDraft.received(wrong)),
        throwsA(isA<ApiFailure>()));
  });
  test(
      'download retains the exact validated bytes and rechecks current metadata',
      () async {
    final bytes = Uint8List.fromList(utf8.encode(
            const JsonEncoder.withIndent('  ').convert(packageDocument()))),
        row = packageFixture(state: 'READY')
          ..['byteCount'] = bytes.length
          ..['sha256'] = sha256.convert(bytes).toString();
    final paths = <String>[];
    final client = PackageClient((r) async {
      paths.add(r.url.path);
      return response(r.url.path.endsWith('/content') ? bytes : row);
    });
    final result = await repository(client).download(job(value: row));
    expect(result.bytes, bytes);
    expect(paths.length, 2);
    expect(paths.first, endsWith('/$packageId'));
    expect(paths.last, endsWith('/$packageId/content'));
    expect(client.closed, isFalse);
  });
  test(
      'received download loads its actual current grant and validates the restricted payload',
      () async {
    final doc = packageDocument(received: true),
        row = packageFixture(received: true, state: 'READY', document: doc);
    final paths = <String>[];
    final client = PackageClient((r) async {
      paths.add(r.url.path);
      if (r.url.path.endsWith('/content')) return response(documentBytes(doc));
      if (r.url.path.endsWith('/grants/$grantId'))
        return response(grantFixture(now: diagnostic.now - 1000));
      return response(row);
    });
    expect(
        (await repository(client, received: true)
                .download(job(received: true, value: row)))
            .bytes,
        isNotEmpty);
    expect(paths, contains('/api/v1/support/grants/$grantId'));
  });
  test(
      'download rejects cacheable partial redirected and changed-scope results',
      () async {
    for (final mode in ['cache', 'partial', 'redirect', 'scope']) {
      final client = PackageClient((r) async {
        if (!r.url.path.endsWith('/content'))
          return response(packageFixture(state: 'READY')
            ..['registrationId'] = mode == 'scope' ? device : registration);
        return response(documentBytes(packageDocument()),
            status: mode == 'partial'
                ? 206
                : mode == 'redirect'
                    ? 302
                    : 200,
            headers:
                mode == 'cache' ? {'content-type': 'application/json'} : null);
      });
      await expectLater(
          repository(client).download(job()), throwsA(isA<ApiFailure>()),
          reason: mode);
    }
  });
  test(
      'session change discards late downloads without closing the shared client',
      () async {
    bool current = true;
    final client = PackageClient((r) async {
      if (r.url.path.endsWith('/content')) current = false;
      return response(r.url.path.endsWith('/content')
          ? documentBytes(packageDocument())
          : packageFixture(state: 'READY'));
    });
    await expectLater(
        repository(client, current: () => current).download(job()),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'WORKSPACE_CHANGED')));
    expect(client.closed, isFalse);
  });
  test(
      'cancel retries use the same original version and reject unrelated returned jobs',
      () async {
    final requests = <http.BaseRequest>[];
    final client = PackageClient((r) async {
      requests.add(r);
      return response(packageFixture(state: 'CANCELLED')..['version'] = 3);
    });
    final repo = repository(client), original = job();
    for (int n = 0; n < 2; n++) {
      expect(
          (await repo.cancel(original, 'cancel-fixture')).state, 'CANCELLED');
    }
    expect(requests.map((r) => r.headers['If-Match']).toSet(), {'"2"'});
    expect(requests.map((r) => r.headers['Idempotency-Key']).toSet(),
        {'cancel-fixture'});
  });
}
