import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parent/platform/family_push_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.aimanager.parent/family-push');
  const platform = FamilyPushPlatform();
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('native state response must contain actual boolean permission facts',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async => {
                  'configured': true,
                  'permissionGranted': 'true',
                  'channelEnabled': true
                });
    await expectLater(platform.state(), throwsFormatException);
  });
  test('native token must be bounded nonempty SDK value', () async {
    for (final token in ['', 'bad token', 'token\nwith\nnewlines', 'x' * 513]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => token);
      await expectLater(platform.register(), throwsFormatException);
    }
  });
  test(
      'native click contains matched opaque installation plus strict event route',
      () async {
    const event = '00000000-0000-4000-8000-000000000001',
        installation = '00000000-0000-4000-8000-000000000002';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async => {
                  'deepLink': 'aimanager://notifications/$event',
                  'installationId': installation
                });
    final click = await platform.takeClick();
    expect(click?.eventId, event);
    expect(click?.installationId, installation);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async => {
                  'deepLink': 'aimanager://notifications/$event',
                  'installationId': 'other'
                });
    expect(await platform.takeClick(), null);
  });
  test('unsupported desktop does not invoke mobile SDK or report configured',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel,
            (call) async => throw StateError('mobile SDK must not run'));
    final state = await platform.state();
    expect(state.configured, false);
    await platform.deactivate();
    expect(await platform.takeClick(), null);
  });
}
