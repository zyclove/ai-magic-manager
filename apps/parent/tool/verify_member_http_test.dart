import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:parent/core/member_access.dart';
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

/// Deliver real HTTP mutations, then discard one successful reply per operation.
class _LostReplies extends http.BaseClient {
  final delegate = http.Client();
  final lost = <String>{};
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final result = await delegate.send(request);
    if (request.url.path.endsWith('/access') &&
        const {'PATCH', 'DELETE'}.contains(request.method) &&
        result.statusCode < 300 &&
        lost.add(request.method)) {
      await result.stream.drain<void>();
      throw http.ClientException('Synthetic lost acknowledgement');
    }
    return result;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test('real member HTTP update and revoke recover original committed results',
      () async {
    final encoded = Platform.environment['PARENT_MEMBER_HTTP_FIXTURE'];
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
        memberKey = fixture['memberKey'] as String,
        path = '/tenants/$tenant';
    final scope = <String>[];
    for (final name in ['Class A', 'Class B']) {
      final row = await api.send('POST', '$path/classes',
          body: {'name': name}, idempotencyKey: const Uuid().v4()) as Json;
      scope.add(row['id']);
    }
    final members = await api.page('$path/members');
    members.items.forEach(validateMemberRow);
    expect(members.items.where((r) => r['cursor'] == memberKey), hasLength(1));
    final before =
        readMemberAccess(await api.object('$path/members/$memberKey/access'));
    final store = MemberOperationStore(storage: _Storage());
    MemberOperationController make() => MemberOperationController(
        api: api,
        tenant: tenant,
        actor: actor,
        store: store,
        isCurrent: () => true);
    var c = make();
    await c.load();
    await c.submit({
      'operation': 'UPDATE',
      'version': before['version'],
      'role': 'TEACHER',
      'subjectId': null,
      'classIds': scope.reversed.toList()
    }, before);
    expect(c.saved, isFalse);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
    c = make();
    await c.load();
    await c.recover(retry: true);
    expect(c.error, isNull);
    expect(c.saved, isTrue);
    expect(c.currentState, 'ACTIVE');
    expect(c.latest!['version'], 1);
    expect(c.committed!['classIds'], unorderedEquals(scope));
    final changed = c.latest!;
    expect(await c.acknowledge(), isTrue);
    await c.submit(
        {'operation': 'REVOKE', 'version': changed['version']}, changed);
    expect(c.error, isA<ParentApiException>());
    expect(c.saved, isFalse);
    c.dispose();
    c = make();
    await c.load();
    await c.recover();
    expect(c.error, isNull);
    expect(c.saved, isTrue);
    expect(c.committed, isNull);
    expect(c.currentState, 'REVOKED');
    expect(c.latest!['version'], 2);
    expect(await c.acknowledge(), isTrue);
    c.dispose();
    final history = await api.page('$path/members/$memberKey/access-history');
    history.items.forEach(validateMemberHistory);
    expect(history.items.map((r) => r['changeType']).toList(),
        ['REVOKED', 'UPDATED']);
    final active = await api.page('$path/members');
    expect(active.items.where((r) => r['cursor'] == memberKey), isEmpty);
    expect(transport.lost, {'PATCH', 'DELETE'});
  });
}
