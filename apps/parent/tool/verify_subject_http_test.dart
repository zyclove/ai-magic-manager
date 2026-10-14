import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/subjects.dart';

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

class _LostReply extends http.BaseClient {
  final delegate = http.Client();
  int changes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await delegate.send(request);
    if (request.url.path.endsWith('/changes') &&
        ++changes == 1 &&
        response.statusCode == 200) {
      await response.stream.drain<void>();
      throw http.ClientException('Synthetic lost acknowledgement');
    }
    return response;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test(
      'production profile controller creates recovers edits and archives over loopback HTTP',
      () async {
    final fixture =
        jsonDecode(Platform.environment['PARENT_SUBJECT_HTTP_FIXTURE']!)
            as Json;
    final root = Uri.parse(fixture['apiRoot']);
    if (fixture['testOnly'] != true ||
        root.scheme != 'http' ||
        root.host != '127.0.0.1' ||
        root.path != '/api/v1' ||
        root.hasQuery ||
        root.hasFragment ||
        root.userInfo.isNotEmpty) {
      throw StateError('Only explicit loopback fixtures are permitted');
    }
    final transport = _LostReply();
    final api = ParentApi(() async => fixture['token'],
        baseUrl: root.toString(), client: transport);
    final store = SubjectChangeStore(storage: _Storage());
    SubjectChangeController controller() => SubjectChangeController(
        api: api,
        store: store,
        tenant: fixture['tenantId'],
        actor: fixture['actorId'],
        isCurrent: () => true,
        foreground: () => true,
        reauthenticate: () async => true);
    final first = controller();
    final create = <String, dynamic>{
      'operation': 'CREATE',
      'nickname': 'HTTP fixture',
      'ageBand': 'AGE_7_12'
    };
    await first.load();
    await first.execute(create);
    expect(first.error, isA<ParentApiException>());
    expect(first.pending, isNotNull);
    final request = first.pending!['requestId'];
    first.dispose();
    final recovered = controller();
    try {
      await recovered.load();
      expect(recovered.pending!['requestId'], request);
      await recovered.query();
      expect(recovered.error, isNull);
      final id = recovered.result!['current']['id'] as String;
      await api.send('PATCH', '/tenants/${fixture['tenantId']}/subjects/$id',
          version: 0,
          body: {'nickname': 'Legacy edit', 'ageBand': 'AGE_13_17'});
      await recovered.query();
      expect(recovered.result!['committed']['nickname'], 'HTTP fixture');
      expect(recovered.result!['current']['nickname'], 'Legacy edit');
      await recovered.acknowledge();
      await recovered.load();
      await recovered.execute({
        'operation': 'UPDATE',
        'subjectId': id,
        'version': 1,
        'nickname': 'Mobile edit',
        'ageBand': 'AGE_13_17'
      });
      expect(recovered.error, isNull);
      expect(recovered.result!['current']['version'], 2);
      await recovered.acknowledge();
      await recovered.load();
      await recovered
          .execute({'operation': 'ARCHIVE', 'subjectId': id, 'version': 2});
      expect(recovered.error, isNull);
      expect(recovered.result!['current']['state'], 'ARCHIVED');
      expect(recovered.result!['current']['version'], 3);
      expect(transport.changes, 3);
      final result = await api.send('POST',
          '/tenants/${fixture['tenantId']}/subjects/operation-results/$request/query',
          body: create) as Json;
      expect(result['committed']['version'], 0);
      expect(result['current']['version'], 3);
    } finally {
      recovered.dispose();
      api.close();
    }
  });
}
