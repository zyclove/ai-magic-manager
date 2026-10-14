import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/notifications.dart';

class LostReadReply extends http.BaseClient {
  final delegate = http.Client();
  int writes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await delegate.send(request);
    if (request.method == 'PUT' &&
        ++writes == 1 &&
        response.statusCode == 200) {
      await response.stream.drain<void>();
      throw http.ClientException('Synthetic lost read acknowledgement');
    }
    return response;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test('production inbox survives lost receipt without changing approval',
      () async {
    final fixture =
        jsonDecode(Platform.environment['PARENT_NOTIFICATION_HTTP_FIXTURE']!)
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
    final transport = LostReadReply();
    final api = ParentApi(() async => fixture['token'],
        baseUrl: root.toString(), client: transport);
    final c = ParentNotificationInbox(
        api: api,
        root: '/tenants/${fixture['tenantId']}',
        isCurrent: () => true);
    try {
      await c.load();
      expect(c.error, isNull);
      expect(c.snapshot!.unread.count, 3);
      final oldApproval = c.snapshot!.page.items
          .singleWhere((n) => n.state == 'APPROVED_PENDING_DELIVERY');
      var opened = 0;
      Future<void> open(String id) async {
        opened++;
        expect(id, fixture['requestId']);
        final current = await api
            .object('/tenants/${fixture['tenantId']}/access-requests/$id');
        expect(current['state'], 'REVOKED');
        expect(current['version'], 2);
      }

      await c
          .read([oldApproval.id], requestId: oldApproval.requestId, open: open);
      expect(c.error, isA<ParentApiException>());
      expect(opened, 0);
      final before = await api
          .object('/tenants/${fixture['tenantId']}/notifications?limit=20');
      final firstRead = (before['items'] as List)
          .singleWhere((n) => n['id'] == oldApproval.id)['readAt'];
      await c.read(c.retryIds!, requestId: c.retryRequestId, open: open);
      expect(c.error, isNull);
      expect(opened, 1);
      expect(c.snapshot!.unread.count, 2);
      await c.read(c.snapshot!.page.items.map((n) => n.id).toList(),
          open: open);
      expect(c.error, isNull);
      expect(c.snapshot!.unread.count, 0);
      expect(c.snapshot!.page.items, isEmpty);
      await c.load(unread: false);
      expect(
          c.snapshot!.page.items
              .singleWhere((n) => n.id == oldApproval.id)
              .readAt,
          firstRead);
      expect(transport.writes, 2);
    } finally {
      c.dispose();
      api.close();
    }
  });
}
