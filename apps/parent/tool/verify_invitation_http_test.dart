import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/invitations.dart';
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
  bool issuance = false, cancellation = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final result = await delegate.send(request);
    if (result.statusCode < 300 &&
        ((!issuance && request.url.path.endsWith('/issuances')) ||
            (!cancellation && request.method == 'DELETE'))) {
      if (request.method == 'DELETE') {
        cancellation = true;
      } else {
        issuance = true;
      }
      await result.stream.drain<void>();
      throw http.ClientException('Synthetic acknowledgement loss');
    }
    return result;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test(
      'real invitation issuance recovery cancellation and recipient acceptance',
      () async {
    final encoded = Platform.environment['PARENT_INVITATION_HTTP_FIXTURE'];
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
    final recipientClient = http.Client();
    addTearDown(recipientClient.close);
    final recipient = ParentApi(() async => fixture['recipientToken'],
        baseUrl: root.toString(), client: recipientClient);
    final tenant = fixture['tenantId'] as String,
        actor = fixture['actorId'] as String,
        path = '/tenants/$tenant/invitations';
    final store = InvitationOperationStore(storage: _Storage());
    InvitationOperationController make() => InvitationOperationController(
        api: api,
        tenant: tenant,
        actor: actor,
        store: store,
        isCurrent: () => true);
    final body = <String, dynamic>{
      'recipientEmail': fixture['recipientEmail'],
      'role': 'GUARDIAN',
      'subjectId': null,
      'classIds': <String>[]
    };
    var c = make();
    await c.load();
    await c.issue(body);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
    c = make();
    await c.load();
    await c.recover(retry: true);
    expect(c.error, isNull);
    expect(c.committed, isTrue);
    expect(c.token, isNull);
    final original = c.latest!;
    expect(await c.acknowledge(), isTrue);
    await c.cancel(original);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
    c = make();
    await c.load();
    await c.recover();
    expect(c.error, isNull);
    expect(c.latest!['state'], 'CANCELLED');
    expect(c.committed, isTrue);
    expect(await c.acknowledge(), isTrue);
    await c.issue(body);
    expect(c.error, isNull);
    expect(c.token, isNotNull);
    final acceptedInvitation = c.latest!, token = c.token!;
    expect(acceptedInvitation['id'], isNot(original['id']));
    final joined = await recipient
        .send('POST', '/invitations/accept', body: {'token': token}) as Json;
    expect(joined['tenantId'], tenant);
    expect(joined['role'], 'GUARDIAN');
    await c.recover();
    expect(c.latest!['state'], 'ACCEPTED');
    expect(c.token, isNull);
    expect(await c.acknowledge(), isTrue);
    await c.cancel(acceptedInvitation);
    expect(c.error, isA<ParentApiException>());
    expect((c.error as ParentApiException).code, 'INVITATION_ALREADY_ACCEPTED');
    await c.recover();
    expect(c.latest!['state'], 'ACCEPTED');
    expect(c.committed, isFalse);
    expect(await c.acknowledge(), isTrue);
    c.dispose();
    final page = await api.page(path);
    expect(page.items, hasLength(2));
    page.items.forEach(readInvitation);
    expect(page.items.map((r) => r['state']),
        unorderedEquals(['CANCELLED', 'ACCEPTED']));
    final grant = await recipient.object('/tenants/$tenant/membership');
    expect(grant['role'], 'GUARDIAN');
    expect(transport.issuance && transport.cancellation, isTrue);
  });
}
