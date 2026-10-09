import 'package:child/platform/secret_store.dart';
import 'package:device_observation/device_observation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('观察记录使用固定独立加密键且等待持久屏障，不改设备身份', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const plugin =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    const runtime = MethodChannel('com.aimanager.child/runtime');
    final calls = <String>[];
    var durable = true;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      expect((call.arguments as Map)['key'], 'observation_record');
      final options = (call.arguments as Map)['options'] as Map;
      expect(options['sharedPreferencesName'], 'aimanager_identity_v1');
      expect(options['resetOnError'], 'false');
      calls.add(call.method);
      return call.method == 'read' ? 'encrypted-plugin-returned-record' : null;
    });
    messenger.setMockMethodCallHandler(runtime, (call) async {
      calls.add('flush');
      return durable;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(plugin, null);
      messenger.setMockMethodCallHandler(runtime, null);
    });
    final store = AndroidObservationStore(available: () => true);
    await store.write('test-only');
    expect(calls, ['write', 'flush']);
    expect(await store.read(), 'encrypted-plugin-returned-record');
    expect(calls, ['write', 'flush', 'read', 'flush']);
    durable = false;
    await expectLater(
        store.write('test-only'), throwsA(isA<ObservationFailure>()));
  });
}
