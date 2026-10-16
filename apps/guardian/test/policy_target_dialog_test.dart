@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/ui/policy_target_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'policy_target_picker_test.dart'
    show PickerSession, mount, settle, reply;

class PolicyDetailsSession extends PickerSession {
  late final detailsClient = MockClient((request) async {
    if (request.url.path.endsWith('/policies/policy-a')) {
      requests.add(request);
      return reply({
        'id': 'policy-a',
        'name': '学习时间规则',
        'kind': 'POLICY',
        'revision': 1,
        'rules': <Object>[],
      });
    }
    return http.Response.fromStream(await client.send(request));
  });
  late final detailsApi =
      Api(() async => detailsClient, baseUrl: 'https://fixture.invalid/api/v1');
  @override
  Api get api => detailsApi;
}

void main() {
  testWidgets('policy details cancellation preserves an independent notice',
      (tester) async {
    final session = PolicyDetailsSession();
    addTearDown(() => session.detailsClient.close());
    await mount(tester, session);
    await tester.tap(find.text('取消'));
    await settle(tester);
    final context = tester.element(find.text('选择设备'));
    final details =
        ConsoleActions(context, session).policyDetails({'id': 'policy-a'});
    await settle(tester);
    await tester.tap(find.text('预览与发布'));
    await settle(tester);
    expect(find.byType(PolicyTargetPicker), findsOneWidget);
    final notice = showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('独立通知'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭通知'),
          ),
        ],
      ),
    );
    await settle(tester);
    session.renewScope();
    await settle(tester);
    expect(find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
    expect(find.text('独立通知'), findsOneWidget);
    expect(
        session.requests.every((request) => request.method == 'GET'), isTrue);
    await tester.tap(find.text('关闭通知'));
    await settle(tester);
    await notice;
    expect(find.text('学习时间规则'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await settle(tester);
    await details;
    expect(find.text('选择设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final switchWorkspace in [false, true]) {
    testWidgets(
        'picker cancels before first frame after ${switchWorkspace ? 'workspace switch' : 'session renewal'}',
        (tester) async {
      final session = PickerSession();
      await mount(tester, session);
      await tester.tap(find.text('取消'));
      await settle(tester);
      final requestCount = session.requests.length;
      var completed = false;
      PolicyTargetSelection? result;
      final picker = showPolicyTargetPicker(
        context: tester.element(find.text('选择设备')),
        session: session,
        root: session.root,
        actor: 'admin',
        role: 'OWNER',
      ).then((value) {
        completed = true;
        result = value;
      });
      // Deliberately invalidate before the dialog's first build/listener.
      if (switchWorkspace) {
        session.tenant = {'id': 'tenant-b', 'kind': 'FAMILY'};
      }
      session.renewScope();
      await settle(tester);
      expect(completed, isTrue);
      expect(result, isNull);
      expect(session.requests.length, requestCount);
      expect(
          find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
      expect(find.text('选择设备'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await picker;
    });
  }

  testWidgets('scope cancellation releases a covered picker caller',
      (tester) async {
    final session = PickerSession();
    await mount(tester, session);
    await tester.tap(find.text('取消'));
    await settle(tester);
    final context = tester.element(find.text('选择设备'));
    var completed = false;
    PolicyTargetSelection? result;
    final picker = showPolicyTargetPicker(
      context: context,
      session: session,
      root: session.root,
      actor: 'admin',
      role: 'OWNER',
    ).then((value) {
      completed = true;
      result = value;
    });
    await settle(tester);
    final notice = showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('独立通知'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭通知'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    session.renewScope();
    session.renewScope();
    await settle(tester);
    // Check completion before awaiting, so a regression fails without hanging.
    expect(completed, isTrue);
    expect(result, isNull);
    expect(find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
    expect(find.text('独立通知'), findsOneWidget);
    await picker;
    await tester.tap(find.text('关闭通知'));
    await settle(tester);
    await notice;
    expect(find.text('选择设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker helper returns the explicit preview selection',
      (tester) async {
    final session = PickerSession();
    await mount(tester, session);
    await tester.tap(find.text('取消'));
    await settle(tester);
    var completed = false;
    PolicyTargetSelection? result;
    final picker = showPolicyTargetPicker(
      context: tester.element(find.text('选择设备')),
      session: session,
      root: session.root,
      actor: 'admin',
      role: 'OWNER',
    ).then((value) {
      completed = true;
      result = value;
    });
    await settle(tester);
    await tester.tap(find.text('学习平板 A'));
    await settle(tester);
    await tester.tap(find.text('预览这些设备'));
    await settle(tester);
    expect(completed, isTrue);
    expect(result?.deviceIds, ['tablet-a']);
    await picker;
    expect(find.text('选择设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
