import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/managed_agent_binding.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_agent_binding_dialog.dart';

import 'managed_agent_binding_fixtures.dart';
import 'managed_agent_binding_dialog_test.dart' show settleBinding;

void main() {
  Future<void> mount(WidgetTester tester, AgentBindingFixture f,
      {Future<void> Function(ManagedAgentBinding)? callback}) async {
    f.binding = f.record(state: 'VERIFIED', version: 2);
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: ManagedAgentBindingDialog(
                repository: f.repository,
                writable: false,
                reauthenticate: () {},
                now: () => f.instant,
                onExecutions: callback))));
    await settleBinding(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      f.client.close();
    });
  }

  testWidgets(
      'read-only association forwards verified device identity without a write',
      (tester) async {
    final f = AgentBindingFixture();
    ManagedAgentBinding? opened;
    await mount(tester, f, callback: (binding) async {
      opened = binding;
    });
    final entry = find.byKey(const Key('managed-binding-executions'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(opened?.deviceId, bindingDevice);
    expect(opened?.registrationId, bindingRegistration);
    expect(f.requests.every((r) => r.method == 'GET'), isTrue);
  });

  testWidgets(
      'association execution entry is absent without host authorization',
      (tester) async {
    await mount(tester, AgentBindingFixture());
    expect(find.byKey(const Key('managed-binding-executions')), findsNothing);
  });

  testWidgets('captured association entry rechecks scope before dispatch',
      (tester) async {
    final f = AgentBindingFixture();
    var opened = 0;
    await mount(tester, f, callback: (_) async {
      opened++;
    });
    final callback = tester
        .widget<OutlinedButton>(
            find.byKey(const Key('managed-binding-executions')))
        .onPressed!;
    f.current = false;
    callback();
    await tester.pump();
    expect(opened, 0);
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  testWidgets(
      'an open execution window blocks a queued second association dispatch',
      (tester) async {
    final f = AgentBindingFixture();
    final closed = Completer<void>();
    var opened = 0;
    await mount(tester, f, callback: (_) {
      opened++;
      return closed.future;
    });
    final callback = tester
        .widget<OutlinedButton>(
            find.byKey(const Key('managed-binding-executions')))
        .onPressed!;
    callback();
    await tester.pump();
    callback();
    await tester.pump();
    expect(opened, 1);
    closed.complete();
    await tester.pumpAndSettle();
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
  });
}
