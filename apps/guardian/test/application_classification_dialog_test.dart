import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/application_classification.dart';
import 'package:guardian/ui/application_classification_dialog.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'application_classification_test.dart'
    show classificationFixture, classificationIdentity;

Future<void> openClassification(WidgetTester tester, MockClient client,
    {bool canEdit = true, ValueNotifier<bool>? access}) async {
  final repository = ApplicationClassificationRepository(
      api: Api(() async => client),
      root: '/tenants/11111111-1111-1111-1111-111111111111',
      applicationId: '22222222-2222-2222-2222-222222222222',
      identity: classificationIdentity,
      current: () => access?.value ?? true);
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => ApplicationClassificationDialog(
                          repository: repository,
                          applicationName: '阅读工具',
                          canEdit: canEdit,
                          accessChanges: access)),
                  child: const Text('打开'))))));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('classification-category')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'unknown save result freezes original category and retries the same key',
      (tester) async {
    final writes = <http.Request>[];
    await openClassification(tester, MockClient((r) async {
      if (r.method == 'GET') {
        return http.Response(jsonEncode(classificationFixture()), 200);
      }
      writes.add(r);
      if (writes.length == 1) {
        return http.Response('{"errorCode":"TEMPORARY_FAILURE"}', 503);
      }
      return http.Response(
          jsonEncode(classificationFixture(category: 'EDUCATION', version: 1)),
          200);
    }));
    await choose(tester, '学习教育');
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    expect(find.textContaining('上次修改结果尚未确认'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byKey(const Key('classification-category')))
            .onChanged,
        isNull);
    await tester.tap(find.text('重试相同修改'));
    await tester.pumpAndSettle();
    expect(writes.length, 2);
    expect(writes[0].body, writes[1].body);
    expect(writes[0].headers['Idempotency-Key'],
        writes[1].headers['Idempotency-Key']);
    expect(find.text('应用分类'), findsNothing);
  });
  testWidgets(
      'version conflict requires explicit reload and never overwrites automatically',
      (tester) async {
    var gets = 0, writes = 0;
    await openClassification(tester, MockClient((r) async {
      if (r.method == 'GET') {
        gets++;
        return http.Response(
            jsonEncode(classificationFixture(
                category: gets == 1 ? 'UNCLASSIFIED' : 'TOOLS',
                version: gets == 1 ? 0 : 1)),
            200);
      }
      writes++;
      return http.Response('{"errorCode":"RESOURCE_VERSION_CONFLICT"}', 412);
    }));
    await choose(tester, '游戏');
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    expect(find.text('重新加载分类'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byKey(const Key('classification-category')))
            .onChanged,
        isNull);
    await tester.tap(find.text('重新加载分类'));
    await tester.pumpAndSettle();
    expect(find.text('实用工具'), findsOneWidget);
    expect(writes, 1);
    expect(gets, 2);
  });
  testWidgets(
      'read only narrow screen and access changes hide the previous classification',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final access = ValueNotifier(true);
    addTearDown(access.dispose);
    await openClassification(
        tester,
        MockClient((_) async => http.Response(
            jsonEncode(classificationFixture(category: 'TOOLS', version: 1)),
            200)),
        canEdit: false,
        access: access);
    expect(find.text('保存分类'), findsNothing);
    expect(find.textContaining('管理员声明'), findsWidgets);
    expect(tester.takeException(), isNull);
    access.value = false;
    await tester.pumpAndSettle();
    expect(find.text('实用工具'), findsNothing);
    expect(find.text('应用分类'), findsNothing);
  });
}
