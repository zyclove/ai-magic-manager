import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/observation.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/observation_editor.dart';

const before = ManagedObservationSettings(
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333',
    0,
    false,
    false,
    null);
Future<void> open(WidgetTester tester, Future<void> Function(Json) send,
    {ValueChanged<Json?>? returned, VoidCallback? reauth}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    final result = await showDialog<Json>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => ObservationEditor(
                            before: before, onSubmit: send, reauth: reauth));
                    returned?.call(result);
                  },
                  child: const Text('打开'))))));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Future<void> fill(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('observe-inventory')));
  await tester.enterText(
      find.byKey(const Key('observe-reason')), '  监护人确认清单用途  ');
  await tester.ensureVisible(find.byKey(const Key('observe-confirm')));
  await tester.tap(find.byKey(const Key('observe-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  for (final failure in [
    const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'),
    const ApiFailure(503, 'SERVICE_UNAVAILABLE'),
    const ApiFailure(401, 'REAUTH_REQUIRED'),
  ]) {
    testWidgets('mobile failure ${failure.status} reveals recovery details',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, (_) async => throw failure, reauth: () {});
      await fill(tester);
      await tester.tap(find.text('确认授权变更'));
      await tester.pumpAndSettle();
      expect(
          find.text(observationError(failure)).hitTestable(), findsOneWidget);
      expect(find.text('关闭并刷新').hitTestable(), findsOneWidget);
      if (failure.status == 503) {
        expect(find.text('重试原提交').hitTestable(), findsOneWidget);
      }
      if (failure.status == 401) {
        expect(find.text('重新安全验证').hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'separate switches require reason and explicit impact acknowledgement',
      (tester) async {
    Json? sent;
    await open(tester, (body) async => sent = body);
    await tester.tap(find.text('确认授权变更'));
    await tester.pumpAndSettle();
    expect(sent, isNull);
    expect(find.text('请输入本次授权变更原因'), findsOneWidget);
    await fill(tester);
    await tester.tap(find.text('确认授权变更'));
    await tester.pumpAndSettle();
    expect(sent, {
      'inventoryEnabled': true,
      'usageEnabled': false,
      'reason': '监护人确认清单用途'
    });
  });
  testWidgets(
      'unknown outcome freezes switches and reason then retries exact body',
      (tester) async {
    final sent = <Json>[];
    await open(tester, (body) async {
      sent.add(body);
      if (sent.length == 1) throw const ApiFailure(503, 'SERVICE_UNAVAILABLE');
    });
    await fill(tester);
    await tester.tap(find.text('确认授权变更'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('observe-inventory')))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('observe-reason')))
            .enabled,
        isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is Semantics &&
            widget.properties.label == '本次变更原因（已锁定）：监护人确认清单用途'),
        findsOneWidget);
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(2));
    expect(sent.first, sent.last);
  });
  testWidgets(
      'version conflict requires refresh and does not resend stale edit',
      (tester) async {
    Json? returned;
    await open(tester,
        (_) async => throw const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT'),
        returned: (value) => returned = value);
    await fill(tester);
    await tester.tap(find.text('确认授权变更'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认授权变更'))
            .onPressed,
        isNull);
    await tester.tap(find.text('关闭并刷新'));
    await tester.pumpAndSettle();
    expect(returned, {'refresh': true});
  });
  testWidgets('reauthentication is available without bypassing the server',
      (tester) async {
    var authentications = 0;
    await open(
        tester, (_) async => throw const ApiFailure(401, 'REAUTH_REQUIRED'),
        reauth: () => authentications++);
    await fill(tester);
    await tester.tap(find.text('确认授权变更'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重新安全验证'));
    await tester.tap(find.text('重新安全验证'));
    expect(authentications, 1);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认授权变更'))
            .onPressed,
        isNull);
  });
}
