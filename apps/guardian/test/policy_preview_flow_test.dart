@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/ui/policy_target_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'fixtures/policy_preview_fixture_data.dart';
import 'policy_target_picker_test.dart'
    show PickerSession, mount, settle, reply;

class PreviewSession extends PickerSession {
  PreviewSession({super.groups});
  final previews = <http.Request>[];
  final publications = <http.Request>[];
  Future<http.Response> Function(http.Request)? respond;
  Future<http.Response?> Function(http.Request)? intercept;
  late final previewClient = MockClient((request) async {
    final intercepted = await intercept?.call(request);
    if (intercepted != null) return intercepted;
    if (request.method == 'POST' && request.url.path.endsWith('/previews')) {
      previews.add(request);
      return respond?.call(request) ?? reply(previewFor(request));
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/publications')) {
      publications.add(request);
      throw StateError('These flows must never publish implicitly');
    }
    final forwarded = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..body = request.body;
    return http.Response.fromStream(await client.send(forwarded));
  });
  late final previewApi =
      Api(() async => previewClient, baseUrl: 'https://fixture.invalid/api/v1');
  @override
  Api get api => previewApi;
}

Json previewFor(http.Request request) =>
    policyPreviewFixture(jsonDecode(request.body) as Json);

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

class Flow {
  final BuildContext context;
  final Future<void> done;
  Object? failure;
  bool completed = false;
  Flow(this.context, Future<void> operation) : done = operation;
}

Future<Flow> startFlow(WidgetTester tester, PreviewSession session,
    {double width = 1100, double scale = 1}) async {
  addTearDown(() => session.previewClient.close());
  await mount(tester, session, width: width, scale: scale);
  await tester.tap(find.text('取消'));
  await settle(tester);
  final context = tester.element(find.text('选择设备'));
  final completer = Completer<void>();
  final flow = Flow(context, completer.future);
  ConsoleActions(context, session).previewPolicy(context, {
    'id': 'policy-a',
    'revision': 7,
  }).then((_) {
    flow.completed = true;
    completer.complete();
  }, onError: (Object failure) {
    flow.failure = failure;
    flow.completed = true;
    completer.complete();
  });
  await settle(tester);
  return flow;
}

Future<void> selectTablet(WidgetTester tester) async {
  await reveal(tester, find.text('学习平板 A'));
  await tester.tap(find.text('学习平板 A'));
  await tester.pump();
}

Future<void> reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    final list = find.descendant(
        of: find.byType(PolicyTargetPicker), matching: find.byType(ListView));
    await tester.scrollUntilVisible(target, 120,
        scrollable:
            find.descendant(of: list, matching: find.byType(Scrollable)).first);
  }
  await tester.ensureVisible(target);
  await tester.pump();
}

Future<void> scrollToTop(WidgetTester tester) async {
  tester
      .widget<ListView>(find.descendant(
          of: find.byType(PolicyTargetPicker), matching: find.byType(ListView)))
      .controller!
      .jumpTo(0);
  await tester.pump();
}

Future<void> selectGroup(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('一年级 · 2 台').last);
  await settle(tester);
}

Future<void> closeResult(WidgetTester tester, Flow flow) async {
  await tester.tap(find.text('关闭').last);
  await settle(tester);
  expect(flow.completed, isTrue);
  await flow.done;
  expect(flow.failure, isNull);
}

void main() {
  testWidgets(
      'group replacement immediately reviews all members and clears search',
      (tester) async {
    final session = PreviewSession(groups: true);
    final flow = await startFlow(tester, session);
    await tester.enterText(find.byType(TextField), '学习平板 A');
    await selectGroup(tester);
    expect(tester.widget<FilterChip>(find.byType(FilterChip)).selected, isTrue);
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    expect(find.text('班级平板 group-1'), findsOneWidget);
    expect(find.text('班级平板 group-2'), findsOneWidget);
    expect(find.text('学习平板 A'), findsNothing);
    expect(session.previews, isEmpty);
    await tester.tap(find.text('取消'));
    await settle(tester);
    await flow.done;
  });

  testWidgets(
      'failed preview keeps the explicit selection and retries the same scope',
      (tester) async {
    final session = PreviewSession();
    session.respond = (request) async => session.previews.length == 1
        ? reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503)
        : reply(previewFor(request));
    final flow = await startFlow(tester, session);
    await selectTablet(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(find.byType(PolicyTargetPicker), findsOneWidget);
    expect(find.text('已选 1 / 50 台'), findsOneWidget);
    expect(flow.failure, isNull);
    expect(session.previews, hasLength(1));
    await tester.tap(find.text('重试预览'));
    await settle(tester);
    expect(session.previews, hasLength(2));
    expect(session.previews[0].body, session.previews[1].body);
    expect(session.previews[1].headers['if-match'], '"7"');
    expect(find.text('发布前预览'), findsOneWidget);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
  });

  testWidgets(
      'pending preview locks changes and duplicate requests; cancellation ignores result',
      (tester) async {
    final session = PreviewSession(groups: true);
    final response = Completer<http.Response>();
    session.respond = (_) => response.future;
    final flow = await startFlow(tester, session);
    await selectTablet(tester);
    final submit =
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!;
    submit();
    submit();
    await flush(tester);
    expect(find.byType(PolicyTargetPicker), findsOneWidget);
    expect(session.previews, hasLength(1));
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await scrollToTop(tester);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>))
            .onChanged,
        isNull);
    // ListView builds offscreen rows lazily. Check its declared controls without
    // relying on those rows being mounted in the current scroll viewport.
    final contents = (tester
            .widget<ListView>(find.descendant(
                of: find.byType(PolicyTargetPicker),
                matching: find.byType(ListView)))
            .childrenDelegate as SliverChildListDelegate)
        .children;
    expect(
        contents
            .whereType<Align>()
            .map((item) => item.child)
            .whereType<TextButton>()
            .single
            .onPressed,
        isNull);
    expect(
        contents
            .whereType<CheckboxListTile>()
            .singleWhere((item) =>
                item.key is ValueKey &&
                (item.key as ValueKey).value == 'tablet-a')
            .onChanged,
        isNull);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(flow.completed, isTrue);
    response.complete(reply(previewFor(session.previews.single)));
    await settle(tester);
    expect(find.text('发布前预览'), findsNothing);
    expect(session.previews, hasLength(1));
    expect(session.publications, isEmpty);
    expect(tester.takeException(), isNull);
    await flow.done;
  });

  testWidgets(
      'same-identity scope renewal during pending preview preserves a covering notice',
      (tester) async {
    final session = PreviewSession();
    final response = Completer<http.Response>();
    session.respond = (_) => response.future;
    final flow = await startFlow(tester, session);
    await selectTablet(tester);
    await tester.tap(find.text('预览这些设备'));
    await flush(tester);
    final notice = showDialog<void>(
        context: flow.context,
        builder: (context) => AlertDialog(
              title: const Text('独立通知'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭通知'))
              ],
            ));
    await flush(tester);
    session.renewScope();
    session.renewScope();
    await settle(tester);
    expect(flow.completed, isTrue);
    expect(find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
    response.complete(reply(previewFor(session.previews.single)));
    await settle(tester);
    expect(find.text('独立通知'), findsOneWidget);
    expect(find.text('发布前预览'), findsNothing);
    expect(session.publications, isEmpty);
    await tester.tap(find.text('关闭通知'));
    await settle(tester);
    await notice;
    await flow.done;
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled group check cannot start a later preview request',
      (tester) async {
    final session = PreviewSession(groups: true);
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    final groupResponse = Completer<http.Response>();
    var pendingChecks = 0;
    session.intercept = (request) async {
      if (request.method == 'GET' &&
          request.url.path.endsWith('/device-groups/group-a')) {
        pendingChecks++;
        return groupResponse.future;
      }
      return null;
    };
    await tester.tap(find.text('预览这些设备'));
    await flush(tester);
    expect(pendingChecks, 1);
    expect(session.previews, isEmpty);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(flow.completed, isTrue);
    await flow.done;
    groupResponse.complete(reply(session.group));
    await settle(tester);
    expect(session.previews, isEmpty);
    expect(session.publications, isEmpty);
    expect(find.text('发布前预览'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final succeeds in [false, true]) {
    testWidgets(
        'covered pending ${succeeds ? 'success' : 'failure'} preserves the independent route',
        (tester) async {
      final session = PreviewSession();
      final response = Completer<http.Response>();
      session.respond = (_) => response.future;
      final flow = await startFlow(tester, session);
      await selectTablet(tester);
      await tester.tap(find.text('预览这些设备'));
      await flush(tester);
      final notice = showDialog<void>(
          context: flow.context,
          builder: (context) => AlertDialog(
                title: const Text('独立通知'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭通知'))
                ],
              ));
      await flush(tester);
      response.complete(succeeds
          ? reply(previewFor(session.previews.single))
          : reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503));
      await settle(tester);
      expect(find.text('独立通知', skipOffstage: false), findsOneWidget);
      expect(session.previews, hasLength(1));
      expect(session.publications, isEmpty);
      if (succeeds) {
        expect(
            find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
        expect(find.text('发布前预览'), findsOneWidget);
        await closeResult(tester, flow);
        expect(find.text('独立通知'), findsOneWidget);
      } else {
        expect(flow.completed, isFalse);
      }
      await tester.tap(find.text('关闭通知'));
      await settle(tester);
      await notice;
      if (!succeeds) {
        expect(find.byType(PolicyTargetPicker), findsOneWidget);
        expect(find.text('已选 1 / 50 台'), findsOneWidget);
        expect(find.text('重试预览'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await settle(tester);
        await flow.done;
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'system back cancels a group check before the route exit animation',
      (tester) async {
    final session = PreviewSession(groups: true);
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    final groupResponse = Completer<http.Response>();
    var pendingChecks = 0;
    session.intercept = (request) async {
      if (request.method == 'GET' &&
          request.url.path.endsWith('/device-groups/group-a')) {
        pendingChecks++;
        return groupResponse.future;
      }
      return null;
    };
    await tester.tap(find.text('预览这些设备'));
    await flush(tester);
    expect(pendingChecks, 1);
    expect(session.previews, isEmpty);
    expect(await Navigator.of(flow.context).maybePop(), isTrue);
    // Release before pumping the exit animation or disposing the picker.
    groupResponse.complete(reply(session.group));
    await settle(tester);
    expect(flow.completed, isTrue);
    await flow.done;
    expect(session.previews, isEmpty);
    expect(session.publications, isEmpty);
    expect(find.text('发布前预览'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'group revision is checked again before retry without silently changing selection',
      (tester) async {
    final session = PreviewSession(groups: true);
    session.respond =
        (_) async => reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503);
    final flow = await startFlow(tester, session);
    await selectGroup(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(find.byType(PolicyTargetPicker), findsOneWidget);
    session.group['version'] = 4;
    await tester.tap(find.text('重试预览'));
    await settle(tester);
    expect(session.previews, hasLength(1));
    expect(find.text('来自“一年级”第 3 版'), findsOneWidget);
    expect(find.text('已选 2 / 50 台'), findsOneWidget);
    expect(find.text('发布前预览'), findsNothing);
    expect(session.publications, isEmpty);
    await tester.tap(find.text('取消'));
    await settle(tester);
    await flow.done;
  });

  for (final invalid in [
    'missing',
    'extra',
    'duplicate',
    'registration',
    'group-version',
    'rules-null',
    'rule-scalar',
    'wrong-policy'
  ]) {
    testWidgets('invalid $invalid response retains the group selection',
        (tester) async {
      final session = PreviewSession(groups: true);
      session.respond = (request) async {
        final data = previewFor(request);
        final targets = data['targets'] as List;
        switch (invalid) {
          case 'missing':
            targets.removeLast();
          case 'extra':
            targets.add({...targets.first as Json, 'deviceId': 'foreign'});
          case 'duplicate':
            targets.add(targets.first);
          case 'registration':
            (targets.first as Json)['registrationId'] = 'stale-registration';
          case 'group-version':
            (data['snapshot']['groupSelection'] as Json)['groupVersion'] = 4;
          case 'rules-null':
            (targets.first as Json)['rules'] = null;
          case 'rule-scalar':
            (targets.first as Json)['rules'] = ['invalid-rule'];
          case 'wrong-policy':
            data['policyId'] = 'foreign-policy';
        }
        return reply(data);
      };
      final flow = await startFlow(tester, session);
      await selectGroup(tester);
      await tester.tap(find.text('预览这些设备'));
      await settle(tester);
      expect(find.byType(PolicyTargetPicker), findsOneWidget);
      expect(find.text('已选 2 / 50 台'), findsOneWidget);
      expect(find.text('发布前预览'), findsNothing);
      expect(session.previews, hasLength(1));
      expect(session.publications, isEmpty);
      expect(flow.failure, isNull);
      await tester.tap(find.text('取消'));
      await settle(tester);
      await flow.done;
    });
  }

  testWidgets(
      'preview result becomes inaccessible after same-identity scope renewal',
      (tester) async {
    final session = PreviewSession();
    final flow = await startFlow(tester, session);
    await selectTablet(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(find.text('发布前预览'), findsOneWidget);
    session.renewScope();
    await settle(tester);
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    expect(find.text('仅保存配置'), findsNothing);
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
  });

  testWidgets(
      'narrow large-text picker keeps preview reachable above the keyboard',
      (tester) async {
    final session = PreviewSession();
    final flow = await startFlow(tester, session, width: 390, scale: 2);
    await selectTablet(tester);
    await scrollToTop(tester);
    await tester.ensureVisible(find.byType(TextField));
    await tester.showKeyboard(find.byType(TextField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final previewButton = find.widgetWithText(FilledButton, '预览这些设备');
    expect(tester.getRect(previewButton).bottom, lessThanOrEqualTo(844 - 280));
    expect(tester.takeException(), isNull);
    await tester.tap(previewButton);
    await settle(tester);
    expect(find.text('发布前预览'), findsOneWidget);
    expect(session.previews, hasLength(1));
    expect(session.publications, isEmpty);
    await closeResult(tester, flow);
    expect(tester.takeException(), isNull);
  });
}
