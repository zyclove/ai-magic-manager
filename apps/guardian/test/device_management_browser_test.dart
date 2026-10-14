@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/device_management.dart';
import 'device_management_test.dart' as fixture;

void main() {
  test('device DTO validation uses the same contract in the browser', () {
    final device = DeviceManagementRecord.fromJson(fixture.record(),
        deviceId: fixture.deviceId);
    expect(device.displayName, '学习平板');
    expect(device.registrationId, fixture.registrationId);
  });
  test('browser bound response completes the real controller read', () async {
    final value = fixture.Fixture();
    addTearDown(value.controller.dispose);
    await value.controller.initialize();
    expect(value.controller.error, isNull);
    expect(value.controller.device?.displayName, '学习平板');
    expect(value.requests.length, 1);
  }, timeout: const Timeout(Duration(seconds: 10)));
  testWidgets('bound streamed read finishes inside a browser widget frame',
      (tester) async {
    final value = fixture.Fixture();
    final loaded = value.controller.initialize();
    try {
      for (var frame = 0; frame < 6; frame++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(value.controller.error, isNull);
      expect(value.controller.device?.displayName, '学习平板');
      expect(value.controller.busy, isFalse);
    } finally {
      value.controller.dispose();
      await tester.pump(const Duration(seconds: 26));
      await loaded;
    }
  });
}
