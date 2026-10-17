import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/device_management.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/device_management_dialog.dart';
import 'device_management_dialog_test.dart' as devices;

void main() {
  Future<void> mount(
      WidgetTester tester, devices.FakeDeviceManagementController controller,
      {Future<void> Function(DeviceManagementRecord)? callback}) async {
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: DeviceManagementDialog(
                controller: controller,
                onClose: () {},
                onExecutions: callback))));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  for (final writable in [true, false]) {
    testWidgets(
        'execution entry forwards the current device for writable=$writable',
        (tester) async {
      final controller =
          devices.FakeDeviceManagementController(writable: writable);
      DeviceManagementRecord? selected;
      await mount(tester, controller, callback: (device) async {
        selected = device;
      });
      final entry = find.byKey(const Key('device-management-executions'));
      expect(entry, findsOneWidget);
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(selected?.id, devices.deviceId);
      expect(selected?.registrationId, devices.registrationId);
      expect(controller.actionDispatches, 1);
    });
  }
  testWidgets('execution entry is absent when host has not granted access',
      (tester) async {
    await mount(tester, devices.FakeDeviceManagementController());
    expect(find.byKey(const Key('device-management-executions')), findsNothing);
  });
  testWidgets('scope loss blocks a previously captured execution callback',
      (tester) async {
    final controller = devices.FakeDeviceManagementController();
    var opened = 0;
    await mount(tester, controller, callback: (_) async {
      opened++;
    });
    final entry = find.byKey(const Key('device-management-executions'));
    final callback = tester.widget<OutlinedButton>(entry).onPressed!;
    controller.accessValue = false;
    controller.publish();
    callback();
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.byKey(const Key('device-management-executions')), findsNothing);
  });
  testWidgets('an open execution child prevents repeated dispatch',
      (tester) async {
    final controller = devices.FakeDeviceManagementController();
    final completed = Completer<void>();
    var opened = 0;
    await mount(tester, controller, callback: (_) {
      opened++;
      return completed.future;
    });
    final callback = tester
        .widget<OutlinedButton>(
            find.byKey(const Key('device-management-executions')))
        .onPressed!;
    callback();
    await tester.pump();
    callback();
    await tester.pump();
    expect(opened, 1);
    completed.complete();
    await tester.pumpAndSettle();
    expect(controller.busy, isFalse);
  });
}
