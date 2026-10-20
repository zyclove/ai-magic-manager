import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/family_identity_controller.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/family_identity_release_panel.dart';
import 'family_identity_configuration_test.dart';
import 'family_identity_release_test.dart';
import 'family_identity_repository_test.dart' show identityReply;

Future<void> mountReleasePanel(
    WidgetTester tester, FamilyIdentityController controller,
    {double scale = 1}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
              body: SingleChildScrollView(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: AnimatedBuilder(
                          animation: controller,
                          builder: (_, __) => IdentityProviderReleasePanel(
                              controller: controller))))))));
}

Future<void> flushRelease(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'a new deployment does not present the last confirmed version as current',
      (tester) async {
    final controller = releaseController((request) async => identityReply(
        request.url.path.endsWith('/release-status')
            ? releaseStatusFixture(
                active: releaseOperationFixture(
                    id: identityOperationId, state: 'CLAIMED'),
                confirmed: releaseOperationFixture(
                    state: 'APPLIED_CLOSED', versionId: historicalId))
            : identityStatusFixture()));
    await controller.load();
    await mountReleasePanel(tester, controller);
    expect(find.text('配置已加载，登录入口待验收'), findsNothing);
    expect(find.textContaining('当前部署待确认'), findsOneWidget);
    expect(find.textContaining('最近确认时间'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('account change closes a pending publication confirmation',
      (tester) async {
    var posts = 0;
    final controller = releaseController((request) async {
      if (request.method == 'POST') posts++;
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture()
          : identityStatusFixture());
    });
    await controller.load();
    readyPreparation(controller);
    await mountReleasePanel(tester, controller);
    await tester.tap(find.text('发布此配置'));
    await tester.pumpAndSettle();
    expect(find.text('确认受控发布'), findsOneWidget);
    controller.invalidate();
    await tester.pumpAndSettle();
    expect(find.text('确认受控发布'), findsNothing);
    expect(posts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets(
      'publish shows concrete version and artifacts before a single confirmed request',
      (tester) async {
    final posts = <Map<String, dynamic>>[];
    String? operationId;
    final controller = releaseController((request) async {
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        posts.add(body);
        operationId = body['id'];
        return identityReply(releaseOperationFixture(id: operationId!));
      }
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(
              active: operationId == null
                  ? null
                  : releaseOperationFixture(id: operationId!))
          : identityStatusFixture());
    });
    await controller.load();
    readyPreparation(controller);
    await mountReleasePanel(tester, controller);
    final publish = find.text('发布此配置');
    await tester.ensureVisible(publish);
    await tester.tap(publish);
    await tester.pumpAndSettle();
    expect(find.textContaining('配置版本 1'), findsOneWidget);
    expect(posts, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '确认发布此版本'));
    await tester.pumpAndSettle();
    expect(posts, isEmpty);
    expect(find.text('请填写 64 位十六进制摘要'), findsNWidgets(2));
    await tester.enterText(find.byType(TextFormField).at(0), 'a' * 64);
    await tester.enterText(find.byType(TextFormField).at(1), 'b' * 64);
    await tester.tap(find.widgetWithText(FilledButton, '确认发布此版本'));
    await flushRelease(tester);
    expect(posts, hasLength(1));
    expect(posts.single['kind'], 'PUBLISH');
    expect(posts.single['versionId'], identityVersionId);
    expect(posts.single['preparationId'], preparationId);
    expect(posts.single['expectedRuntimeRevision'], 0);
    expect(find.text('等待部署执行'), findsOneWidget);
    expect(find.text('配置已加载，登录入口待验收'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('closing publish confirmation never creates an operation',
      (tester) async {
    var posts = 0;
    final controller = releaseController((request) async {
      if (request.method == 'POST') posts++;
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture()
          : identityStatusFixture());
    });
    await controller.load();
    readyPreparation(controller);
    await mountReleasePanel(tester, controller);
    await tester.tap(find.text('发布此配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂不发布'));
    await tester.pumpAndSettle();
    expect(posts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets(
      'historical rollback requires selection and an impact preview before dispatch',
      (tester) async {
    final posts = <Map<String, dynamic>>[];
    String? operationId;
    final controller = releaseController((request) async {
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        posts.add(body);
        operationId = body['id'];
        return identityReply(releaseOperationFixture(
            id: operationId!, kind: 'ROLLBACK', versionId: historicalId));
      }
      return identityReply(request.url.path.endsWith('/release-status')
          ? releaseStatusFixture(
              rollback: operationId == null,
              active: operationId == null
                  ? null
                  : releaseOperationFixture(
                      id: operationId!,
                      kind: 'ROLLBACK',
                      versionId: historicalId))
          : identityStatusFixture());
    });
    await controller.load();
    await mountReleasePanel(tester, controller);
    await tester.tap(find.text('回退到已确认版本'));
    await tester.pumpAndSettle();
    expect(find.text('选择已确认的历史配置'), findsOneWidget);
    expect(posts, isEmpty);
    await tester.tap(find.text('配置 55555555'));
    await tester.pumpAndSettle();
    expect(find.text('回退影响预览'), findsOneWidget);
    expect(posts, isEmpty);
    expect(find.textContaining('当前草稿保留'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确认回退此版本'));
    await flushRelease(tester);
    expect(posts, hasLength(1));
    expect(posts.single['kind'], 'ROLLBACK');
    expect(posts.single['versionId'], historicalId);
    expect(find.text('等待部署执行'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets(
      'large text on narrow screen shows closed login and no paid or provider success',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = releaseController((request) async => identityReply(
        request.url.path.endsWith('/release-status')
            ? releaseStatusFixture(
                confirmed: releaseOperationFixture(state: 'APPLIED_CLOSED'),
                rollback: true)
            : identityStatusFixture()));
    await controller.load();
    await mountReleasePanel(tester, controller, scale: 2);
    expect(find.text('配置已加载，登录入口待验收'), findsOneWidget);
    expect(find.text('短信正常'), findsNothing);
    expect(find.text('可以收费'), findsNothing);
    expect(tester.takeException(), isNull);
    final rollback = find.text('回退到已确认版本');
    await tester.ensureVisible(rollback);
    await tester.tap(rollback);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('配置 55555555'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
