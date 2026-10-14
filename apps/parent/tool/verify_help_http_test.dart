import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/help_attention.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:uuid/uuid.dart';

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

class _LostReceipt extends http.BaseClient {
  final delegate = http.Client();
  int posts = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await delegate.send(request);
    if (request.method == 'POST') {
      posts++;
      if (response.statusCode == 200) {
        await response.stream.drain<void>();
        throw http.ClientException('Synthetic lost receipt');
      }
    }
    return response;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test(
      'device report, parent acknowledgement, history and durable read-only recovery over real HTTP',
      () async {
    final raw = Platform.environment['PARENT_HELP_HTTP_FIXTURE'];
    if (raw == null) throw StateError('Explicit loopback fixture required');
    final fixture = jsonDecode(raw) as Map<String, dynamic>;
    final root = Uri.parse(fixture['apiRoot']);
    if (fixture['testOnly'] != true ||
        root.scheme != 'http' ||
        root.host != '127.0.0.1' ||
        root.path != '/api/v1' ||
        root.hasQuery ||
        root.hasFragment ||
        root.userInfo.isNotEmpty) {
      throw StateError('Only isolated loopback fixtures are permitted');
    }
    final device =
        ParentApi(() async => fixture['deviceToken'], baseUrl: root.toString());
    final lost = _LostReceipt();
    final api = ParentApi(() async => fixture['token'],
        baseUrl: root.toString(), client: lost);
    final store = HelpAttentionStore(storage: _Storage());
    final clientId = const Uuid().v4();
    try {
      final created = parseHelp(await device.send(
          'POST', '/device-api/help-requests',
          body: {'clientRequestId': clientId, 'reasonCode': 'DEVICE_PROBLEM'}));
      ParentHelpDetail create() => ParentHelpDetail(
          api: api,
          store: store,
          tenant: fixture['tenantId'],
          actor: fixture['actorId'],
          id: created.id,
          isCurrent: () => true,
          foreground: () => true);
      final first = create();
      await first.load();
      expect(first.error, isNull);
      expect(first.request!.subjectNickname, 'Fixture child');
      await first.acknowledge();
      expect(first.error, isA<ParentApiException>());
      expect(first.pending, isNotNull);
      first.dispose();
      final recovered = create();
      try {
        await recovered.load();
        expect(recovered.error, isNull);
        expect(recovered.request!.state, 'ACKNOWLEDGED');
        expect(recovered.queried, isTrue);
        await recovered.acknowledge();
        expect(lost.posts, 1);
        final open = await api.page(
            '/tenants/${fixture['tenantId']}/help-requests?state=OPEN',
            limit: 20);
        final history = await api.page(
            '/tenants/${fixture['tenantId']}/help-requests?state=ACKNOWLEDGED',
            limit: 20);
        expect(open.items, isEmpty);
        expect(parseHelp(history.items.single).id, created.id);
        await recovered.clearPending();
        expect(
            await store.load(fixture['tenantId'], fixture['actorId']), isNull);
        expect(lost.posts, 1);
        final childView = parseHelp(
            await device.object('/device-api/help-requests/$clientId'));
        expect(childView.state, 'ACKNOWLEDGED');
        expect(childView.subjectNickname, isNull);
      } finally {
        recovered.dispose();
      }
    } finally {
      api.close();
      device.close();
    }
  });
}
