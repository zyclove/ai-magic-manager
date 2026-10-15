import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/ownership.dart';
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

class _LostReply extends http.BaseClient {
  final delegate = http.Client();
  final String suffix;
  bool lost = false;
  _LostReply(this.suffix);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final result = await delegate.send(request);
    if (!lost &&
        request.method == 'POST' &&
        request.url.path.contains('/ownership-transfers') &&
        request.url.path.endsWith(suffix) &&
        result.statusCode < 300) {
      lost = true;
      await result.stream.drain<void>();
      throw http.ClientException('Synthetic reply loss');
    }
    return result;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test(
      'real ownership flows recover lost proposal and acceptance across role changes',
      () async {
    final encoded = Platform.environment['PARENT_OWNERSHIP_HTTP_FIXTURE'];
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
    final ownerClient = _LostReply('/ownership-transfers'),
        recipientClient = _LostReply('/accept');
    addTearDown(ownerClient.close);
    addTearDown(recipientClient.close);
    final owner = ParentApi(() async => fixture['token'],
        baseUrl: root.toString(), client: ownerClient);
    final recipient = ParentApi(() async => fixture['recipientToken'],
        baseUrl: root.toString(), client: recipientClient);
    final tenant = fixture['tenantId'] as String,
        ownerActor = fixture['actorId'] as String,
        recipientActor = fixture['recipientActor'] as String,
        path = '/tenants/$tenant';
    final invite = await owner.object('$path/membership');
    expect(invite['role'], 'OWNER');
    final invitation = await owner.send('POST', '$path/invitations',
        body: {'recipientEmail': fixture['recipientEmail'], 'role': 'AUDITOR'});
    await recipient.send('POST', '/invitations/accept',
        body: {'token': invitation['token']});
    final storage = _Storage(), recipientStorage = _Storage();
    OwnershipOperation makeOwner() => OwnershipOperation(
        api: owner,
        tenant: tenant,
        actor: ownerActor,
        store: OwnershipStore(storage: storage),
        isCurrent: () => true);
    OwnershipOperation makeRecipient() => OwnershipOperation(
        api: recipient,
        tenant: tenant,
        actor: recipientActor,
        store: OwnershipStore(storage: recipientStorage),
        isCurrent: () => true);
    var proposed = makeOwner();
    await proposed.load();
    await proposed.submit(
        {'operation': 'start', 'version': 0, 'targetActorId': recipientActor});
    expect(proposed.error, isA<ParentApiException>());
    expect(ownerClient.lost, true);
    final startDescriptor = Map<String, dynamic>.from(proposed.pending!);
    proposed.dispose();
    final transfers = await recipient.page('$path/ownership-transfers');
    expect(transfers.items, hasLength(1));
    final first = readOwnership(transfers.items.single, tenant);
    var decision = makeRecipient();
    await decision.load();
    await decision.submit({
      'operation': 'accept',
      'version': first['version'],
      'transferId': first['id']
    });
    expect(recipientClient.lost, true);
    expect(decision.committed, false);
    final acceptDescriptor = Map<String, dynamic>.from(decision.pending!);
    decision.dispose();
    proposed = makeOwner();
    await proposed.load();
    await proposed.recover();
    expect(proposed.error, isNull);
    expect(proposed.original!['state'], 'PENDING');
    expect(proposed.current!['state'], 'ACCEPTED');
    expect(proposed.currentRole, 'GUARDIAN');
    expect(await proposed.acknowledge(), true);
    proposed.dispose();
    decision = makeRecipient();
    await decision.load();
    await decision.recover();
    expect(decision.currentRole, 'OWNER');
    expect(decision.current!['state'], 'ACCEPTED');
    expect(await decision.acknowledge(), true);
    // A second legitimate handover proves an earlier success is not current ownership.
    await decision.submit(
        {'operation': 'start', 'version': 0, 'targetActorId': ownerActor});
    expect(decision.error, isNull);
    final second = decision.current!;
    expect(await decision.acknowledge(), true);
    decision.dispose();
    var back = makeOwner();
    await back.load();
    await back.submit({
      'operation': 'accept',
      'version': second['version'],
      'transferId': second['id']
    });
    expect(back.error, isNull);
    expect(back.currentRole, 'OWNER');
    expect(await back.acknowledge(), true);
    back.dispose();
    final oldAcceptance = await recipient.send('POST',
        '$path/ownership-transfers/operation-results/${acceptDescriptor['requestId']}/query',
        body: acceptDescriptor['input']);
    expect(oldAcceptance['original']['state'], 'ACCEPTED');
    expect(oldAcceptance['currentRole'], 'GUARDIAN');
    final oldStart = await owner.send('POST',
        '$path/ownership-transfers/operation-results/${startDescriptor['requestId']}/query',
        body: startDescriptor['input']);
    expect(oldStart['original']['state'], 'PENDING');
    expect(oldStart['current']['state'], 'ACCEPTED');
    expect(oldStart['currentRole'], 'OWNER');
    expect(storage.values, isEmpty);
    expect(recipientStorage.values, isEmpty);
  });
}
