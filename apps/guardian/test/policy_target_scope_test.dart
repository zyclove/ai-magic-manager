@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/policy_target_picker.dart';
import 'policy_target_picker_test.dart' show PickerSession, mount, settle;

void main() {
  testWidgets('scope change closes picker and its open device-group dropdown',
      (tester) async {
    final session = PickerSession(groups: true);
    await mount(tester, session);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    session.renewScope();
    await settle(tester);
    expect(find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
    expect(find.text('一年级 · 2 台', skipOffstage: false), findsNothing);
    expect(find.text('选择设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope change removes only its picker beneath another dialog',
      (tester) async {
    final session = PickerSession();
    await mount(tester, session);
    final context = tester.element(find.byType(PolicyTargetPicker));
    final overlay = showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(title: const Text('独立通知'), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭通知'))
            ]));
    await tester.pumpAndSettle();
    session.renewScope();
    await settle(tester);
    expect(find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
    expect(find.text('独立通知'), findsOneWidget);
    await tester.tap(find.text('关闭通知'));
    await settle(tester);
    await overlay;
    expect(find.text('选择设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated scope notifications preserve the parent page',
      (tester) async {
    final session = PickerSession();
    await mount(tester, session);
    await tester.tap(find.text('取消'));
    await settle(tester);
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    final parent = navigator.push(MaterialPageRoute<void>(
        builder: (context) => Scaffold(
            body: TextButton(
                onPressed: () => showDialog<PolicyTargetSelection>(
                    context: context,
                    builder: (_) => PolicyTargetPicker(
                        session: session,
                        root: session.root,
                        actor: 'admin',
                        role: 'OWNER')),
                child: const Text('父页面打开设备')))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('父页面打开设备'));
    await settle(tester);
    session.renewScope();
    session.renewScope();
    session.renewScope();
    await settle(tester);
    expect(find.byType(PolicyTargetPicker, skipOffstage: false), findsNothing);
    expect(find.text('父页面打开设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
    navigator.pop();
    await tester.pumpAndSettle();
    await parent;
  });
}
