import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/managed_agent_binding.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_agent_binding_dialog.dart';

import 'managed_agent_binding_fixtures.dart';

typedef _ExecutionEntry = Future<void> Function(ManagedAgentBinding binding,
    {required bool readOnly,
    required bool Function() parentCurrent,
    required Listenable parentChanges});

const _entry = Key('managed-binding-executions');

Future<void> _frames(WidgetTester tester) async {
  for (var index = 0; index < 6; index++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _mount(WidgetTester tester, AgentBindingFixture fixture,
    {_ExecutionEntry? callback}) async {
  fixture.binding = fixture.record(state: 'VERIFIED', version: 2);
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    fixture.client.close();
  });
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: ManagedAgentBindingDialog(
              repository: fixture.repository,
              writable: false,
              reauthenticate: () {},
              now: () => fixture.instant,
              onExecutions: callback))));
  await _frames(tester);
}

Future<void> _dispose(
    WidgetTester tester, AgentBindingFixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _frames(tester);
  fixture.client.close();
  expect(tester.takeException(), isNull);
}

VoidCallback _callback(WidgetTester tester) {
  final entry = find.byKey(_entry);
  expect(entry, findsOneWidget);
  final callback = tester.widget<OutlinedButton>(entry).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

void main() {
  testWidgets(
      'read-only association forwards verified device identity without a write',
      (tester) async {
    final fixture = AgentBindingFixture();
    ManagedAgentBinding? opened;
    bool? readOnlyAtOpen;
    bool? currentAtOpen;
    bool Function()? retainedCurrent;
    Listenable? changes;
    try {
      await _mount(tester, fixture, callback: (binding,
          {required bool readOnly,
          required bool Function() parentCurrent,
          required Listenable parentChanges}) async {
        opened = binding;
        readOnlyAtOpen = readOnly;
        currentAtOpen = parentCurrent();
        retainedCurrent = parentCurrent;
        changes = parentChanges;
      });
      await tester.ensureVisible(find.byKey(_entry));
      await tester.tap(find.byKey(_entry));
      await _frames(tester);
      expect(opened?.deviceId, bindingDevice);
      expect(opened?.registrationId, bindingRegistration);
      expect(readOnlyAtOpen, isTrue);
      expect(currentAtOpen, isTrue);
      expect(changes, isNotNull);
      expect(retainedCurrent!(), isFalse);
      expect(fixture.requests.every((request) => request.method == 'GET'),
          isTrue);
    } finally {
      await _dispose(tester, fixture);
    }
  });

  testWidgets(
      'association execution entry is absent without host authorization',
      (tester) async {
    final fixture = AgentBindingFixture();
    try {
      await _mount(tester, fixture);
      expect(find.byKey(_entry), findsNothing);
    } finally {
      await _dispose(tester, fixture);
    }
  });

  testWidgets('captured association entry rechecks scope before dispatch',
      (tester) async {
    final fixture = AgentBindingFixture();
    var opened = 0;
    try {
      await _mount(tester, fixture, callback: (_,
          {required bool readOnly,
          required bool Function() parentCurrent,
          required Listenable parentChanges}) async {
        opened++;
      });
      final open = _callback(tester);
      fixture.current = false;
      open();
      await _frames(tester);
      expect(opened, 0);
      expect(fixture.requests.where((request) => request.method == 'POST'),
          isEmpty);
    } finally {
      await _dispose(tester, fixture);
    }
  });

  testWidgets(
      'an open execution window blocks a queued second association dispatch',
      (tester) async {
    final fixture = AgentBindingFixture();
    final closed = Completer<void>();
    var opened = 0;
    try {
      await _mount(tester, fixture, callback: (_,
          {required bool readOnly,
          required bool Function() parentCurrent,
          required Listenable parentChanges}) {
        opened++;
        return closed.future;
      });
      final open = _callback(tester);
      open();
      await tester.pump();
      open();
      await tester.pump();
      expect(opened, 1);
      closed.complete();
      await _frames(tester);
      expect(fixture.requests.where((request) => request.method == 'POST'),
          isEmpty);
    } finally {
      if (!closed.isCompleted) closed.complete();
      await _frames(tester);
      await _dispose(tester, fixture);
    }
  });
}
