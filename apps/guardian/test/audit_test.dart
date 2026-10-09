import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/audit.dart';
import 'package:guardian/ui/audit_view.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const id = 'aaaaaaaa-1111-1111-1111-111111111111';
const second = 'bbbbbbbb-1111-1111-1111-111111111111';
final now = DateTime.now().millisecondsSinceEpoch - 1000;
Json event({String key = id, int? at}) => {
      'id': key,
      'actorId': 'exact-actor',
      'action': 'SUBJECT_CREATED',
      'resourceId': id,
      'correlationId': id,
      'occurredAt': at ?? now
    };
http.Response response(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
AuditRepository repo(FutureOr<http.Response> Function(http.Request) handle,
        {bool Function()? current}) =>
    AuditRepository(
        api: Api(() async => MockClient((r) async => handle(r))),
        root: '/tenants/$id',
        current: current ?? () => true);
Widget host(AuditRepository repository) => MaterialApp(
    theme: consoleTheme(),
    home: Scaffold(
        body: SingleChildScrollView(child: AuditView(repository: repository))));
void main() {
  testWidgets('copied actor hash resource is accepted as a filter', (t) async {
    final requests = <Uri>[];
    final repository = repo((r) {
      requests.add(r.url);
      return response({'items': [], 'nextCursor': null});
    });
    await t.pumpWidget(host(repository));
    await t.pumpAndSettle();
    final hash = List.filled(32, 'ab').join();
    await t.enterText(find.widgetWithText(TextFormField, '资源编号'), hash);
    await t.tap(find.text('应用筛选'));
    await t.pumpAndSettle();
    expect(requests.last.queryParameters['resourceId'], hash);
  });
  testWidgets('failed next page retries the same cursor', (t) async {
    final cursors = <String?>[];
    var failed = false;
    final repository = repo((r) {
      final cursor = r.url.queryParameters['cursor'];
      cursors.add(cursor);
      if (cursor == 'next' && !failed) {
        failed = true;
        return response({'errorCode': 'TEMPORARY_FAILURE'}, 503);
      }
      return response({
        'items': cursor == null
            ? List.generate(
                20,
                (n) => event(
                    key:
                        '${(30 - n).toRadixString(16).padLeft(8, '0')}-1111-1111-1111-111111111111',
                    at: now - n))
            : [event(at: now - 30)],
        'nextCursor': cursor == null ? 'next' : null
      });
    });
    await t.pumpWidget(host(repository));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('下一页'));
    await t.tap(find.text('下一页'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('重试'));
    await t.tap(find.text('重试'));
    await t.pumpAndSettle();
    expect(cursors, [null, 'next', 'next']);
    expect(find.text('第 2 页 · 1 条'), findsOneWidget);
  });
  test(
      'strict page validation rejects wrong order, duplicates, oversized pages and out of range',
      () async {
    final q = AuditQuery(from: now - 1000, to: now + 1000);
    for (final items in [
      [event(), event()],
      [event(), event(key: second, at: now + 1)],
      List.generate(21, (_) => event()),
      [event(at: now + 1000)]
    ]) {
      await expectLater(
          repo((_) => response({'items': items, 'nextCursor': null})).load(q),
          throwsA(isA<ApiFailure>()));
    }
  });
  test(
      'query values are encoded and workspace changes discard pending responses',
      () async {
    final pending = Completer<http.Response>();
    var current = true;
    final repository = repo((r) {
      expect(r.url.queryParameters['correlationId'], id);
      return pending.future;
    }, current: () => current);
    final result = repository
        .load(AuditQuery(from: now - 1000, to: now + 1000, correlationId: id));
    current = false;
    pending.complete(response({
      'items': [event()],
      'nextCursor': null
    }));
    await expectLater(result, throwsA(isA<ApiFailure>()));
  });
  testWidgets('filters reset pagination and failed refresh hides stale records',
      (t) async {
    final requests = <Uri>[];
    var fail = false;
    final repository = repo((r) {
      requests.add(r.url);
      return fail
          ? response({'errorCode': 'TEMPORARY_FAILURE'}, 503)
          : response({
              'items': [event()],
              'nextCursor': null
            });
    });
    await t.pumpWidget(host(repository));
    await t.pumpAndSettle();
    expect(find.text('查看详情'), findsOneWidget);
    await t.enterText(find.byKey(const Key('audit-action')), 'SUBJECT_CREATED');
    await t.tap(find.text('应用筛选'));
    await t.pumpAndSettle();
    expect(requests.last.queryParameters['action'], 'SUBJECT_CREATED');
    expect(requests.last.queryParameters['cursor'], isNull);
    fail = true;
    await t.tap(find.byTooltip('刷新审计日志'));
    await t.pumpAndSettle();
    expect(find.text('查看详情'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });
  testWidgets('details are fetched again and revocation hides page records',
      (t) async {
    var denied = false;
    final repository = repo((r) {
      if (r.url.path.endsWith('/search')) {
        return response({
          'items': [event()],
          'nextCursor': null
        });
      }
      denied = true;
      return response({'errorCode': 'SCOPE_DENIED'}, 403);
    });
    await t.pumpWidget(host(repository));
    await t.pumpAndSettle();
    await t.tap(find.text('查看详情'));
    await t.pumpAndSettle();
    expect(denied, isTrue);
    expect(find.text('查看详情'), findsNothing);
    expect(find.text('exact-actor'), findsNothing);
  });
  testWidgets('mobile filters and detail fit without overflow', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final repository = repo((r) => response(r.url.path.endsWith('/search')
        ? {
            'items': [event()],
            'nextCursor': null
          }
        : event()));
    await t.pumpWidget(host(repository));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('查看详情'));
    await t.tap(find.text('查看详情'));
    await t.pumpAndSettle();
    expect(find.text('审计事件详情'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
