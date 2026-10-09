import 'package:child/platform/secret_store.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const plugin = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const runtime = MethodChannel('com.aimanager.child/runtime');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test(
      'context check intent uses its own encrypted key and durable SDK barrier',
      () async {
    final calls = <String>[];
    String? record;
    var durable = true;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      final args = call.arguments as Map;
      expect(args['key'], 'access_context_v1_$key');
      expect((args['options'] as Map)['resetOnError'], 'false');
      calls.add(call.method);
      if (call.method == 'write') {
        record = args['value'] as String;
        return null;
      }
      if (call.method == 'read') return record;
      fail('No enumeration, deletion or reset');
    });
    messenger.setMockMethodCallHandler(runtime, (call) async {
      expect(call.method, 'flushIdentity');
      calls.add('flush');
      return durable;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(plugin, null);
      messenger.setMockMethodCallHandler(runtime, null);
    });
    final store = AndroidAccessBindingStore(available: () => true);
    await store.write(key, 'synthetic-checking-intent');
    expect(await store.read(key), 'synthetic-checking-intent');
    expect(calls, ['write', 'flush', 'read', 'flush']);
    durable = false;
    await expectLater(
        store.write(key, 'synthetic-block'), throwsA(isA<AccessFailure>()));
  });
  test(
      'unavailable platform, invalid scope and oversized record fail before SDK',
      () async {
    final store = AndroidAccessBindingStore(available: () => true);
    await expectLater(store.read('../invalid'), throwsA(isA<AccessFailure>()));
    await expectLater(
        store.write(key, 'x' * 65537), throwsA(isA<AccessFailure>()));
    await expectLater(
        AndroidAccessBindingStore(available: () => false).read(key),
        throwsA(isA<AccessFailure>()));
  });
}
