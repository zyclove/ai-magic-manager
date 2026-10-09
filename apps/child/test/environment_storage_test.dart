import 'package:child/core/environment.dart';
import 'package:child/platform/secret_store.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'deployment is HTTPS, immutable and has only an explicit loopback exception',
      () {
    for (final root in [
      'http://foreign.example/api/v1',
      'https://user:pass@example.com/api/v1',
      'https://example.com/api/v1?token=x',
      'https://example.com/api/v1#x',
      'https://example.com'
    ]) {
      expect(() => ChildEnvironment(apiRoot: Uri.parse(root)),
          throwsFormatException);
    }
    expect(
        ChildEnvironment(apiRoot: Uri.parse('https://example.com/api/v1'))
            .apiRoot
            .host,
        'example.com');
    expect(
        ChildEnvironment(
                apiRoot: Uri.parse('http://127.0.0.1/api/v1'),
                allowLoopbackHttp: true)
            .allowLoopbackHttp,
        isTrue);
    expect(
        () => ChildEnvironment(
            apiRoot: Uri.parse('http://foreign.example/api/v1'),
            allowLoopbackHttp: true),
        throwsFormatException);
  });
  test(
      'encrypted write waits for durability barrier; failure never becomes success',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const plugin =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    const runtime = MethodChannel('com.aimanager.child/runtime');
    final events = <String>[];
    var barrier = true;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      if (call.method == 'write') {
        final options = (call.arguments as Map)['options'] as Map;
        expect(options['resetOnError'], 'false');
        expect(options['migrateOnAlgorithmChange'], 'true');
        expect(options['sharedPreferencesName'], 'aimanager_identity_v1');
        expect((call.arguments as Map)['key'], 'identity_record');
        events.add('encrypted-write');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(runtime, (call) async {
      expect(call.method, 'flushIdentity');
      expect(call.arguments, isNull);
      events.add('durability-barrier');
      return barrier;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(plugin, null);
      messenger.setMockMethodCallHandler(runtime, null);
    });
    final store = AndroidIdentityStore(available: () => true);
    await store.write('test-only-record');
    expect(events, ['encrypted-write', 'durability-barrier']);
    expect(await store.read(), isNull);
    expect(events.last, 'durability-barrier');
    barrier = false;
    await expectLater(
        store.write('test-only-record'), throwsA(isA<DeviceIdentityFailure>()));
    expect(events.length, 5);
    await expectLater(store.read(), throwsA(isA<DeviceIdentityFailure>()));
  });
  test('unsupported platforms never use web or plaintext credential storage',
      () async {
    final store = AndroidIdentityStore(available: () => false);
    await expectLater(store.read(), throwsA(isA<DeviceIdentityFailure>()));
    await expectLater(
        store.write('test-only'), throwsA(isA<DeviceIdentityFailure>()));
  });
}
