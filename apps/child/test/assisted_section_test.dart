import 'package:child/core/assisted_runtime.dart';
import 'package:child/ui/assisted_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('test/assisted_section');
  late List<MethodCall> calls;
  late AndroidAssistedRuntime runtime;
  setUp(() {
    calls = [];
    runtime = AndroidAssistedRuntime(
        channel: channel, nowMillis: () => 1792026000000);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'health': 'CONSENT_REQUIRED',
        'limitStatus': 'UNKNOWN',
        'observedAt': 1792026000000,
        'optedIn': false,
        'usageGranted': false,
        'accessibilityConnected': false,
        'systemEnforced': false,
      };
    });
  });
  tearDown(() {
    runtime.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  testWidgets('opening assistance requires an explicit informed confirmation',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChildAssistedSection(
                runtime: runtime, available: true, onRequest: () {}))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启家庭应用辅助'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'setConsent'), isEmpty);
    expect(find.textContaining('不读取页面、聊天或输入文字'), findsOneWidget);
    await tester.tap(find.text('了解并同意'));
    await tester.pumpAndSettle();
    final consent = calls.where((c) => c.method == 'setConsent').single;
    expect(consent.arguments, {'enabled': true});
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('unavailable native evidence never displays remaining allowance',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChildAssistedSection(
                runtime: runtime, available: true, onRequest: () {}))));
    await tester.pumpAndSettle();
    expect(find.text('本机辅助状态尚未核对'), findsOneWidget);
    expect(find.textContaining('今日剩余'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
