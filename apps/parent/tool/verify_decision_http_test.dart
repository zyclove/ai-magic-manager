import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/access_decision.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/pending_decisions.dart';

class Storage extends ParentDurableStorage {
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

class LostApprovalReply extends http.BaseClient {
  final delegate = http.Client();
  int writes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await delegate.send(request);
    if (request.method == 'POST' &&
        request.url.path.endsWith('/decisions') &&
        ++writes == 1 &&
        response.statusCode == 200) {
      await response.stream.drain<void>();
      throw http.ClientException('Synthetic lost approval acknowledgement');
    }
    return response;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test('production controller approves shorter duration and recovers read-only',
      () async {
    final fixture =
        jsonDecode(Platform.environment['PARENT_DECISION_HTTP_FIXTURE']!)
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
    final transport = LostApprovalReply();
    final api = ParentApi(() async => fixture['token'],
        baseUrl: root.toString(), client: transport);
    final store = PendingDecisionStore(storage: Storage());
    ParentAccessDecision make() => ParentAccessDecision(
        api: api,
        store: store,
        tenant: fixture['tenantId'],
        actor: fixture['actorId'],
        requestId: fixture['requestId'],
        isCurrent: () => true,
        foreground: () => true,
        reauthenticate: () async => true);
    final first = make();
    await first.load();
    expect(first.error, isNull);
    expect(first.request!['requestedWindowSeconds'], 600);
    await first.execute(choice: 'APPROVE', seconds: 300);
    expect(first.error, isA<ParentApiException>());
    expect(first.pending!.grantedWindowSeconds, 300);
    first.dispose();
    final recovered = make();
    try {
      await recovered.load();
      expect(recovered.error, isNull);
      expect(recovered.queried, isTrue);
      expect(recovered.request!['state'], 'APPROVED_PENDING_DELIVERY');
      expect(recovered.request!['grantedWindowSeconds'], 300);
      expect(recovered.receipt, isNull);
      await recovered.execute(choice: 'DENY', reason: 'OTHER');
      expect(transport.writes, 1);
      expect(await recovered.acknowledge(), isTrue);
      await recovered.load();
      expect(recovered.pending, isNull);
      expect(recovered.request!['state'], 'APPROVED_PENDING_DELIVERY');
      expect(transport.writes, 1);
    } finally {
      recovered.dispose();
      api.close();
    }
  });
}
