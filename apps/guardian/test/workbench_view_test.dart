import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/overview_summary.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/workbench_view.dart';

OverviewSummary summary({
  int subjects = 1,
  int devices = 1,
  int policies = 1,
  int approvals = 0,
  int help = 0,
  int connections = 0,
  List<Map<String, Object>> activity = const [],
}) =>
    OverviewSummary.parse({
      'subjectCount': subjects,
      'activeDeviceCount': devices,
      'policyDraftCount': policies,
      'pendingRequestCount': approvals,
      'openHelpRequestCount': help,
      'connectionCheckCount': connections,
      'recentActivity': activity,
    });

const sections = {
  'subjects',
  'devices',
  'policies',
  'approvals',
  'help-requests',
  'reports',
  'audit',
};

Widget host(Widget child, {double textScale = 1}) => MaterialApp(
    theme: consoleTheme(),
    builder: (context, value) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: value!),
    home: Scaffold(
        body: SingleChildScrollView(
            padding: const EdgeInsets.all(18), child: child)));

void main() {
  final cases = <({String name, OverviewSummary value, String destination})>[
    (
      name: 'help takes priority over every other task',
      value: summary(help: 2, approvals: 3, connections: 1, subjects: 0),
      destination: 'help-requests',
    ),
    (
      name: 'pending approvals take priority over connection checks',
      value: summary(approvals: 3, connections: 1),
      destination: 'approvals',
    ),
    (
      name: 'connection checks take priority over setup',
      value: summary(connections: 1, subjects: 0),
      destination: 'devices',
    ),
    (
      name: 'empty workspace opens the existing subject form',
      value: summary(subjects: 0, devices: 0, policies: 0),
      destination: 'add-subject',
    ),
    (
      name: 'existing subject without devices opens the existing device form',
      value: summary(devices: 0, policies: 0),
      destination: 'add-device',
    ),
    (
      name: 'no draft links to rules without claiming rules are absent',
      value: summary(policies: 0),
      destination: 'policies',
    ),
    (
      name: 'established workspace offers reports instead of onboarding',
      value: summary(),
      destination: 'reports',
    ),
  ];
  for (final item in cases) {
    testWidgets(item.name, (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(host(WorkbenchView(
          workspaceName: '我的家庭',
          role: 'OWNER',
          organization: false,
          summary: item.value,
          canOpen: sections.contains,
          onOpen: opened.add,
          onAddSubject: () => opened.add('add-subject'),
          onAddDevice: () => opened.add('add-device'),
          onRefresh: () {},
          onReauth: () {})));
      await tester.tap(find.byKey(const Key('workbench-next-action')));
      await tester.pump();
      expect(opened, [item.destination]);
      expect(find.text('连接第一台设备'), findsNothing);
      expect(find.text('系统连接'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('summary links and common actions keep their intended targets',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(host(WorkbenchView(
        workspaceName: '学校',
        role: 'ORG_ADMIN',
        organization: true,
        summary: summary(),
        canOpen: sections.contains,
        onOpen: opened.add,
        onAddSubject: () => opened.add('add-subject'),
        onAddDevice: () => opened.add('add-device'),
        onRefresh: () {},
        onReauth: () {})));
    expect(find.text('学生档案'), findsOneWidget);
    expect(find.text('儿童档案'), findsNothing);
    await tester
        .ensureVisible(find.byKey(const Key('workbench-metric-subjects')));
    await tester.tap(find.byKey(const Key('workbench-metric-subjects')));
    await tester.ensureVisible(find.byKey(const Key('workbench-add-subject')));
    await tester.tap(find.byKey(const Key('workbench-add-subject')));
    await tester.ensureVisible(find.byKey(const Key('workbench-add-device')));
    await tester.tap(find.byKey(const Key('workbench-add-device')));
    expect(opened, ['subjects', 'add-subject', 'add-device']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable sections hide counts, actions and audit content',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(host(WorkbenchView(
        workspaceName: '受限空间',
        role: 'GUARDIAN',
        organization: false,
        summary: summary(help: 8, approvals: 9, activity: [
          {
            'id': 'activity-1',
            'action': 'SUBJECT_CREATED',
            'resourceId': 'subject-1',
            'occurredAt': 1791849600000,
          }
        ]),
        canOpen: (section) => section == 'reports',
        onOpen: opened.add,
        onRefresh: () {},
        onReauth: () {})));
    await tester.tap(find.byKey(const Key('workbench-next-action')));
    expect(opened, ['reports']);
    expect(find.text('最近活动'), findsNothing);
    expect(find.text('创建儿童档案'), findsNothing);
    expect(find.byKey(const Key('workbench-metric-help')), findsNothing);
    expect(find.byKey(const Key('workbench-add-subject')), findsNothing);
    expect(find.byKey(const Key('workbench-add-device')), findsNothing);
  });

  testWidgets(
      'loading and failures never show ready counts or connection claims',
      (tester) async {
    int retries = 0, reauths = 0;
    Widget view({Object? error}) => host(WorkbenchView(
        workspaceName: '我的家庭',
        role: 'OWNER',
        organization: false,
        summary: null,
        error: error,
        canOpen: sections.contains,
        onOpen: (_) {},
        onRefresh: () => retries++,
        onReauth: () => reauths++));
    await tester.pumpWidget(view());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('workbench-next-action')), findsNothing);
    expect(find.textContaining('上次读取完成'), findsNothing);
    await tester
        .pumpWidget(view(error: const ApiFailure(401, 'REAUTH_REQUIRED')));
    await tester.tap(find.text('重试'));
    await tester.tap(find.text('重新安全验证'));
    expect(retries, 1);
    expect(reauths, 1);
    expect(find.text('已连接'), findsNothing);
  });

  testWidgets(
      'refresh completion is explicit and active forms block duplicates',
      (tester) async {
    int starts = 0;
    await tester.pumpWidget(host(WorkbenchView(
        workspaceName: '我的家庭',
        role: 'OWNER',
        organization: false,
        summary: summary(subjects: 0, devices: 0, policies: 0),
        refreshedAt: DateTime(2026, 10, 14, 9, 30),
        busy: true,
        canOpen: sections.contains,
        onOpen: (_) {},
        onAddSubject: () => starts++,
        onAddDevice: () => starts++,
        onRefresh: () {},
        onReauth: () {})));
    expect(find.textContaining('上次读取完成：2026-10-14 09:30'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('workbench-next-action')))
            .onPressed,
        isNull);
    await tester.ensureVisible(find.byKey(const Key('workbench-add-subject')));
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const Key('workbench-add-subject')))
            .onPressed,
        isNull);
    expect(starts, 0);
    expect(find.text('已连接'), findsNothing);
  });

  testWidgets('narrow large text keeps urgent action and metrics operable',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final opened = <String>[];
    await tester.pumpWidget(host(
        WorkbenchView(
            workspaceName: '名字很长的教育机构管理空间',
            role: 'ORG_ADMIN',
            organization: true,
            summary: summary(help: 12, approvals: 99, connections: 5),
            canOpen: sections.contains,
            onOpen: opened.add,
            onAddSubject: () {},
            onAddDevice: () {},
            onRefresh: () {},
            onReauth: () {}),
        textScale: 1.5));
    await tester.ensureVisible(find.byKey(const Key('workbench-next-action')));
    await tester.tap(find.byKey(const Key('workbench-next-action')));
    await tester
        .ensureVisible(find.byKey(const Key('workbench-metric-approvals')));
    await tester.tap(find.byKey(const Key('workbench-metric-approvals')));
    expect(opened, ['help-requests', 'approvals']);
    expect(tester.takeException(), isNull);
  });
}
