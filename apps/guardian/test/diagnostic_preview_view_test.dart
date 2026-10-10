import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/core/api.dart';
import '../lib/core/device_diagnostic.dart';
import '../lib/ui/diagnostic_preview_view.dart';
import 'fixtures/diagnostic.dart';

DeviceDiagnostic sample() => DeviceDiagnostic.parse(fixture(),
    tenantId: tenant, deviceId: device, registrationId: registration);

Future<void> open(WidgetTester tester, Future<DeviceDiagnostic> Function() load,
    {bool Function()? current,
    Listenable? accessChanges,
    VoidCallback? reauth}) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: DiagnosticPreviewView(
              load: load,
              current: current ?? () => true,
              accessChanges: accessChanges,
              onReauth: reauth,
              onClose: () {}))));
}

void main() {
  testWidgets(
      'diagnostic values expose readable text instead of editable fields',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await open(tester, () async => sample());
      await tester.tap(find.text('读取诊断'));
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byType(SelectionArea), matching: find.text('1.2.3')),
          findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      expect(find.bySemanticsLabel('1.2.3'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });
  testWidgets('requires explicit read and labels reports as evidence only',
      (tester) async {
    var calls = 0;
    await open(tester, () async {
      calls++;
      return sample();
    });
    expect(calls, 0);
    expect(find.text('诊断信息尚未读取'), findsOneWidget);
    await tester.tap(find.text('读取诊断'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('设备自报与下发记录，不代表策略已执行。'), findsOneWidget);
    expect(find.text('1.2.3'), findsOneWidget);
  });
  testWidgets('prevents duplicate reads while loading', (tester) async {
    final pending = Completer<DeviceDiagnostic>();
    var calls = 0;
    await open(tester, () {
      calls++;
      return pending.future;
    });
    await tester.tap(find.text('读取诊断'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((w) => w is FilledButton))
            .onPressed,
        isNull);
    pending.complete(sample());
    await tester.pumpAndSettle();
    expect(calls, 1);
  });
  testWidgets('clears visible diagnostic on background and requires fresh read',
      (tester) async {
    var calls = 0;
    await open(tester, () async {
      calls++;
      return sample();
    });
    await tester.tap(find.text('读取诊断'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('1.2.3'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('1.2.3'), findsNothing);
    expect(calls, 1);
    expect(find.text('诊断信息已清除，请重新读取。'), findsOneWidget);
  });
  testWidgets('late result stays discarded after background and resume',
      (tester) async {
    final pending = Completer<DeviceDiagnostic>();
    await open(tester, () => pending.future);
    await tester.tap(find.text('读取诊断'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    pending.complete(sample());
    await tester.pumpAndSettle();
    expect(find.text('1.2.3'), findsNothing);
  });
  testWidgets('scope revocation clears private result and disables read',
      (tester) async {
    var current = true;
    final changed = ChangeNotifier();
    await open(tester, () async => sample(),
        current: () => current, accessChanges: changed);
    await tester.tap(find.text('读取诊断'));
    await tester.pumpAndSettle();
    current = false;
    changed.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('1.2.3'), findsNothing);
    expect(find.text('账号或设备范围已变化，请关闭后重新打开。'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((w) => w is FilledButton))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
    changed.dispose();
  });
  testWidgets(
      'reauthentication has an explicit action and errors do not expose text',
      (tester) async {
    var reauth = 0;
    await open(
        tester, () async => throw const ApiFailure(401, 'REAUTH_REQUIRED'),
        reauth: () {
      reauth++;
    });
    await tester.tap(find.text('读取诊断'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新认证'));
    expect(reauth, 1);
    await open(tester, () async => throw StateError('SECRET_STACK'));
    await tester.tap(find.text('读取诊断'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SECRET'), findsNothing);
  });
  testWidgets(
      'phone layout and long fingerprints remain scrollable without overflow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await open(tester, () async => sample());
    await tester.tap(find.text('读取诊断'));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byType(SingleChildScrollView).first, const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置 1'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('配置指纹')).dx,
        tester.getTopLeft(find.text('策略指纹')).dx);
    expect(tester.takeException(), isNull);
  });
  testWidgets('shows only validated request identifiers on failure',
      (tester) async {
    await open(
        tester,
        () async => throw const ApiFailure(
            502, 'DIAGNOSTIC_SOURCE_INVALID', correlation));
    await tester.tap(find.text('读取诊断'));
    await tester.pumpAndSettle();
    expect(find.text('请求标识：$correlation'), findsOneWidget);
    await open(
        tester,
        () async => throw const ApiFailure(
            502, 'DIAGNOSTIC_SOURCE_INVALID', 'SECRET_URL'));
    await tester.tap(find.text('读取诊断'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SECRET_URL'), findsNothing);
    expect(find.text('请求标识：$correlation'), findsNothing);
  });
}
