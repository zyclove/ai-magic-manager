import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/organization_classes.dart';
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

class _LostReplies extends http.BaseClient {
  final delegate = http.Client();
  bool createLost = false, transferLost = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final result = await delegate.send(request);
    if (request.method == 'POST' &&
        result.statusCode < 300 &&
        ((!createLost && request.url.path.endsWith('/classes')) ||
            (!transferLost && request.url.path.endsWith('/transfer')))) {
      if (request.url.path.endsWith('/classes')) {
        createLost = true;
      } else {
        transferLost = true;
      }
      await result.stream.drain<void>();
      throw http.ClientException('Synthetic lost acknowledgement');
    }
    return result;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test(
      'real class HTTP lifecycle with durable creation and atomic transfer recovery',
      () async {
    final encoded = Platform.environment['PARENT_CLASS_HTTP_FIXTURE'];
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
    final transport = _LostReplies();
    addTearDown(transport.close);
    final api = ParentApi(() async => fixture['token'],
        baseUrl: root.toString(), client: transport);
    final tenant = fixture['tenantId'] as String,
        actor = fixture['actorId'] as String,
        path = '/tenants/$tenant';
    final store = ClassOperationStore(storage: _Storage());
    ClassOperationController make() => ClassOperationController(
        api: api,
        tenant: tenant,
        actor: actor,
        store: store,
        isCurrent: () => true);
    var c = make();
    await c.load();
    await c.submit({'operation': 'CREATE', 'name': 'Class A'});
    expect(c.committed, isNull);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
    c = make();
    await c.load();
    await c.recover();
    expect(c.error, isNull);
    var source = c.latest!.single;
    expect(await c.acknowledge(), isTrue);
    await c.submit({'operation': 'CREATE', 'name': 'Class B'});
    expect(c.error, isNull);
    var target = c.latest!.single;
    expect(await c.acknowledge(), isTrue);
    final child = await api.send('POST', '$path/subjects',
        body: {'nickname': 'Class HTTP child', 'ageBand': 'AGE_7_12'}) as Json;
    await c.submit({
      'operation': 'ADD',
      'classId': source['id'],
      'version': source['version'],
      'subjectId': child['id']
    }, before: source);
    expect(c.error, isNull);
    source = c.latest!.single;
    expect(source['studentCount'], 1);
    await c.acknowledge();
    await c.submit({
      'operation': 'TRANSFER',
      'classId': source['id'],
      'version': source['version'],
      'subjectId': child['id'],
      'targetClassId': target['id'],
      'targetVersion': target['version']
    }, before: source, target: target);
    expect(c.committed, isNull);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
    c = make();
    await c.load();
    await c.recover(retry: true);
    expect(c.error, isNull);
    source = c.latest!.first;
    target = c.latest!.last;
    expect(source['version'], 2);
    expect(target['version'], 1);
    expect(source['studentCount'], 0);
    expect(target['studentCount'], 1);
    await c.acknowledge();
    final roster = await api.page('$path/classes/${target['id']}/students');
    expect(roster.items, hasLength(1));
    validateClassStudent(roster.items.single);
    await c.submit({
      'operation': 'REMOVE',
      'classId': target['id'],
      'version': target['version'],
      'subjectId': child['id']
    }, before: target);
    expect(c.error, isNull);
    target = c.latest!.single;
    await c.acknowledge();
    await c.submit({
      'operation': 'RENAME',
      'classId': target['id'],
      'version': target['version'],
      'name': 'Class B renamed'
    }, before: target);
    expect(c.error, isNull);
    expect(c.latest!.single['name'], 'Class B renamed');
    await c.acknowledge();
    await c.submit({
      'operation': 'ARCHIVE',
      'classId': source['id'],
      'version': source['version']
    }, before: source);
    expect(c.error, isNull);
    expect(c.latest!.single['state'], 'ARCHIVED');
    expect(await c.acknowledge(), isTrue);
    c.dispose();
    final active = await api.page('$path/classes');
    expect(active.items, hasLength(1));
    final all = await api.page('$path/classes?includeArchived=true');
    expect(all.items, hasLength(2));
    expect(transport.createLost && transport.transferLost, isTrue);
  });
}
