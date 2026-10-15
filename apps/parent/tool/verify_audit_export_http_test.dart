import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/audit.dart';
import 'package:parent/core/audit_exports.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';

class _Storage extends ParentDurableStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

class _LostCreationReply extends http.BaseClient {
  final inner = http.Client();
  int creates = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final reply = await inner.send(request);
    if (request.method == 'POST' &&
        request.url.path.endsWith('/audit-exports')) {
      creates++;
      if (reply.statusCode == 202) {
        await reply.stream.drain<void>();
        throw http.ClientException('Synthetic creation reply loss');
      }
    }
    return reply;
  }

  @override
  void close() => inner.close();
}

void main() {
  test(
      'production export creation recovery download and cancellation over real HTTP',
      () async {
    final encoded = Platform.environment['PARENT_EXPORT_HTTP_FIXTURE'];
    if (encoded == null || encoded.length > 16000) {
      throw StateError('Explicit fixture required');
    }
    final fixture = jsonDecode(encoded) as Json,
        root = Uri.parse(jsonDecode(encoded)['apiRoot']);
    if (fixture['testOnly'] != true ||
        root.scheme != 'http' ||
        root.host != '127.0.0.1' ||
        !root.hasPort ||
        root.path != '/api/v1' ||
        root.hasQuery ||
        root.hasFragment ||
        root.userInfo.isNotEmpty) {
      throw StateError('Only loopback fixture permitted');
    }
    final client = _LostCreationReply(),
        api = ParentApi(() async => fixture['token'],
            baseUrl: root.toString(), client: client);
    final repository = ParentAuditExports(
        api: api,
        tenant: fixture['tenant'],
        current: () => true,
        token: () async => fixture['token']);
    addTearDown(api.close);
    addTearDown(repository.close);
    final storage = AuditExportStore(storage: _Storage());
    final op = AuditExportOperation(
        repository: repository,
        store: storage,
        actor: fixture['actor'],
        current: () => true);
    await op.load();
    await op.create(AuditQuery(
        from: fixture['from'],
        to: fixture['to'],
        resourceId: fixture['resource']));
    expect(client.creates, 1);
    expect(op.pending, isNotNull);
    expect(op.result, isNull);
    op.dispose();
    final restored = AuditExportOperation(
        repository: repository,
        store: storage,
        actor: fixture['actor'],
        current: () => true);
    await restored.load();
    await restored.recover();
    expect(restored.result, isNotNull);
    var job = restored.result!;
    for (int n = 0; n < 150 && job.pending; n++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      job = await repository.get(job.id);
    }
    expect(job.state, 'READY');
    expect(job.recordCount, 2);
    expect(client.creates, 1);
    final bytes = await repository.download(job, operation: () => true);
    final payload = jsonDecode(utf8.decode(bytes)) as Json;
    expect((payload['events'] as List).length, 2);
    expect(payload['tenantId'], fixture['tenant']);
    expect(await restored.clear(), true);
    await restored.cancel(job.id);
    expect(restored.result?.state, 'CANCELLED');
    await expectLater(
        repository.download(job, operation: () => true),
        throwsA(
            isA<ParentApiException>().having((e) => e.status, 'status', 409)));
    final list = await repository.list();
    expect(list.items.single.id, job.id);
    expect(list.items.single.state, 'CANCELLED');
  });
}
