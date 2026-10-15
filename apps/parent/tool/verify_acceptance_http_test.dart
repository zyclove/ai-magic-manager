import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:parent/core/invitation_acceptance.dart';
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

class _LostAcceptance extends http.BaseClient {
  final delegate = http.Client();
  bool lost = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final result = await delegate.send(request);
    if (!lost &&
        request.url.path.endsWith('/acceptances') &&
        result.statusCode == 200) {
      lost = true;
      await result.stream.drain<void>();
      throw http.ClientException('Synthetic acknowledgement loss');
    }
    return result;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test('real recipient preview acceptance recovery revocation and later rejoin',
      () async {
    final encoded = Platform.environment['PARENT_ACCEPTANCE_HTTP_FIXTURE'];
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
    final ownerClient = http.Client(), recipientClient = _LostAcceptance();
    addTearDown(ownerClient.close);
    addTearDown(recipientClient.close);
    final owner = ParentApi(() async => fixture['token'],
        baseUrl: root.toString(), client: ownerClient);
    final recipient = ParentApi(() async => fixture['recipientToken'],
        baseUrl: root.toString(), client: recipientClient);
    final tenant = fixture['tenantId'] as String,
        actor = fixture['recipientActor'] as String,
        path = '/tenants/$tenant';
    Future<Json> issue(String role) async =>
        await owner.send('POST', '$path/invitations/issuances',
            body: {
              'recipientEmail': fixture['recipientEmail'],
              'role': role,
              'subjectId': null,
              'classIds': <String>[]
            },
            idempotencyKey: const Uuid().v4()) as Json;
    final first = await issue('GUARDIAN');
    final storage = _Storage();
    final durable = InvitationAcceptanceStore(storage: storage);
    InvitationAcceptanceController make() => InvitationAcceptanceController(
        api: recipient, actor: actor, store: durable, isCurrent: () => true);
    var c = make();
    await c.load();
    await c.inspect(first['token']);
    expect(c.error, isNull);
    expect(c.preview!['role'], 'GUARDIAN');
    expect((await owner.page('$path/members')).items, hasLength(1));
    await c.accept();
    expect(c.error, isA<ParentApiException>());
    expect(c.committed, isFalse);
    final descriptor = Map<String, dynamic>.from(c.pending!);
    expect(storage.values.values.single, isNot(contains(first['token'])));
    c.dispose();
    final members = await owner.page('$path/members');
    final member = members.items.singleWhere((m) => m['actorId'] == actor);
    await owner.send('DELETE', '$path/members/${member['cursor']}/access',
        version: member['version'], idempotencyKey: const Uuid().v4());
    c = make();
    await c.load();
    await c.recover();
    expect(c.error, isNull);
    expect(c.committed, isTrue);
    expect(c.result!['accepted']['role'], 'GUARDIAN');
    expect(c.result!['current']['state'], 'REVOKED');
    expect(await c.acknowledge(), isTrue);
    final second = await issue('AUDITOR');
    await c.inspect(second['token']);
    expect(c.error, isNull);
    await c.accept();
    expect(c.error, isNull);
    expect(c.result!['current']['state'], 'ACTIVE');
    expect(c.result!['current']['role'], 'AUDITOR');
    expect(c.result!['accepted']['memberVersion'], 2);
    expect(await c.acknowledge(), isTrue);
    c.dispose();
    final original = await recipient.object(
        '/invitations/${descriptor['invitationId']}/acceptance-results/${descriptor['requestId']}');
    expect(original['accepted']['role'], 'GUARDIAN');
    expect(original['current']['role'], 'AUDITOR');
    expect(original['current']['version'], 2);
    expect(recipientClient.lost, isTrue);
    expect(storage.values, isEmpty);
  });
}
