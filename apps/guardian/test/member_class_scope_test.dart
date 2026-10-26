import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/member_class_scope.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const firstId = '00000000-0000-0000-0000-000000000001';
const secondId = '00000000-0000-0000-0000-000000000002';
const missingId = '00000000-0000-0000-0000-000000000003';
const otherId = '00000000-0000-0000-0000-000000000009';

http.Response page(List<Json> rows, {String? cursor}) => http.Response(
    jsonEncode({'items': rows, 'nextCursor': cursor}), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Widget host(Api api, Listenable changes, bool Function() isCurrent,
    {Key? scopeKey}) => MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(body: SingleChildScrollView(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('成员资料：林老师'),
          MemberClassScope(
              key: scopeKey,
              api: api,
              path: '/tenants/tenant-a/classes?includeArchived=true',
              classIds: const [firstId, secondId, missingId],
              accessChanges: changes,
              isCurrent: isCurrent),
        ]))));

void main() {
  testWidgets('names load independently and old retries cannot switch API owners',
      (tester) async {
    final changes = ValueNotifier(true);
    addTearDown(changes.dispose);
    final firstRead = Completer<http.Response>();
    var reads = 0;
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/tenants/tenant-a/classes');
      expect(request.url.queryParameters['includeArchived'], 'true');
      expect(request.url.queryParameters['limit'], '50');
      reads++;
      if (reads == 1) return firstRead.future;
      if (reads == 2) {
        return page([
          {'id': firstId, 'name': '七年级一班', 'state': 'ACTIVE'},
          {'id': otherId, 'name': '未获授秘密班级', 'state': 'ACTIVE'},
        ], cursor: 'next-page');
      }
      expect(reads, 3);
      expect(request.url.queryParameters['cursor'], 'next-page');
      return page([
        {'id': secondId, 'name': '原六年级二班', 'state': 'ARCHIVED'},
      ]);
    });
    addTearDown(client.close);
    final api = Api(() async => client, baseUrl: 'http://localhost/api/v1');
    await tester.pumpWidget(host(api, changes, () => changes.value));
    await tester.pump();
    expect(find.text('成员资料：林老师'), findsOneWidget);
    expect(reads, 1);
    expect(find.text('班级编号：$firstId'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    firstRead.complete(http.Response('{"code":"UNAVAILABLE"}', 503));
    await tester.pumpAndSettle();
    expect(find.text('成员资料：林老师'), findsOneWidget);
    expect(find.text('班级名称未读到，以上完整编号来自当前成员权限。'), findsOneWidget);
    for (final id in [firstId, secondId, missingId]) {
      expect(find.text('班级编号：$id'), findsOneWidget);
    }
    final retry = tester.widget<TextButton>(find.byWidgetPredicate(
        (widget) => widget is TextButton)).onPressed!;
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(reads, 3);
    expect(find.text('七年级一班 · $firstId'), findsOneWidget);
    expect(find.text('原六年级二班（已归档） · $secondId'), findsOneWidget);
    expect(find.text('名称未提供 · $missingId'), findsOneWidget);
    expect(find.textContaining('未获授秘密班级'), findsNothing);
    expect(find.text('重试'), findsNothing);

    var replacementReads = 0;
    final replacementClient = MockClient((request) async {
      replacementReads++;
      return page([]);
    });
    addTearDown(replacementClient.close);
    final replacement = Api(() async => replacementClient,
        baseUrl: 'http://localhost/api/v1');
    await tester.pumpWidget(host(replacement, changes, () => changes.value));
    retry();
    await tester.pumpAndSettle();
    expect(find.textContaining('七年级一班'), findsNothing);
    expect(find.textContaining(firstId), findsNothing);
    expect(replacementReads, 0);
    expect(reads, 3);
  });

  testWidgets('permission loss hides names and rejects late pages even after access returns',
      (tester) async {
    final changes = ValueNotifier(true);
    final lateRead = Completer<http.Response>();
    var reads = 0;
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      reads++;
      if (reads == 1) {
        return page([
          {'id': firstId, 'name': '已读取私有名称', 'state': 'ACTIVE'},
        ]);
      }
      expect(reads, 2);
      return lateRead.future;
    });
    addTearDown(client.close);
    final api = Api(() async => client, baseUrl: 'http://localhost/api/v1');
    await tester.pumpWidget(host(api, changes, () => changes.value));
    await tester.pumpAndSettle();
    expect(find.text('已读取私有名称 · $firstId'), findsOneWidget);
    changes.value = false;
    changes.value = true;
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('已读取私有名称'), findsNothing);
    expect(find.textContaining(firstId), findsNothing);
    expect(reads, 1);

    await tester.pumpWidget(host(api, changes, () => changes.value,
        scopeKey: const ValueKey('fresh-detail')));
    await tester.pump();
    expect(reads, 2);
    changes.value = false;
    changes.value = true;
    lateRead.complete(page([
      {'id': firstId, 'name': '晚到私有名称', 'state': 'ACTIVE'},
    ], cursor: 'must-not-load'));
    await tester.pumpAndSettle();
    expect(find.textContaining('晚到私有名称'), findsNothing);
    expect(find.textContaining(firstId), findsNothing);
    expect(reads, 2);

    changes.dispose();
    await tester.pumpWidget(host(api, changes, () => false,
        scopeKey: const ValueKey('already-retired-detail')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(reads, 2);
  });
}
