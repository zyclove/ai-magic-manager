import 'package:child/platform/secret_store.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runtime = MethodChannel('com.aimanager.child/runtime');
  const plugin = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late String? nativeRecord, injectedRecord;
  late List<String> events;
  var nativeUnavailable = false;

  setUp(() {
    nativeRecord = 'original-native-record';
    injectedRecord = 'original-injected-record';
    nativeUnavailable = false;
    events = [];
    messenger.setMockMethodCallHandler(runtime, (call) async {
      events.add(call.method);
      if (nativeUnavailable) throw PlatformException(code: 'private cause');
      if (call.method == 'identityRead') return nativeRecord;
      if (call.method == 'flushIdentity') return true;
      if (call.method == 'identityCompareAndSet' ||
          call.method == 'identityDelete') {
        final args = call.arguments as Map;
        if (args['expected'] != nativeRecord) return false;
        nativeRecord =
            call.method == 'identityDelete' ? null : args['value'] as String?;
        return true;
      }
      throw StateError('Unexpected native operation');
    });
    messenger.setMockMethodCallHandler(plugin, (call) async {
      events.add('plugin:${call.method}');
      expect((call.arguments as Map)['key'], 'identity_record');
      if (call.method == 'read') return injectedRecord;
      if (call.method == 'write') {
        injectedRecord = (call.arguments as Map)['value'] as String;
      }
      if (call.method == 'delete') injectedRecord = null;
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(runtime, null);
    messenger.setMockMethodCallHandler(plugin, null);
  });

  test(
      'default identity reads the native record without a second storage owner',
      () async {
    final store = AndroidIdentityStore(available: () => true);
    expect(await store.read(), 'original-native-record');
    expect(events, ['identityRead']);
  });

  test(
      'default writes and deletion use native comparisons and reject stale records',
      () async {
    final store = AndroidIdentityStore(available: () => true);
    final atomic = store as DeviceSecretCompareAndSet;
    expect(
        await atomic.compareAndSet(
            expected: 'original-native-record', value: 'rotated-native-record'),
        isTrue);
    expect(
        await atomic.compareAndSet(
            expected: 'original-native-record', value: 'stale-response'),
        isFalse);
    expect(nativeRecord, 'rotated-native-record');
    expect(
        await atomic.compareAndSet(
            expected: 'original-native-record', value: null),
        isFalse);
    expect(nativeRecord, 'rotated-native-record');
    expect(
        await atomic.compareAndSet(
            expected: 'rotated-native-record', value: null),
        isTrue);
    expect(nativeRecord, isNull);
    expect(events, [
      'identityCompareAndSet',
      'identityCompareAndSet',
      'identityDelete',
      'identityDelete'
    ]);
  });

  test('default write and delete retain native storage durability boundary',
      () async {
    final store = AndroidIdentityStore(available: () => true);
    await store.write('updated-native-record');
    expect(nativeRecord, 'updated-native-record');
    await store.deleteIdentity();
    expect(nativeRecord, isNull);
    expect(events, [
      'identityRead',
      'identityCompareAndSet',
      'identityRead',
      'identityDelete'
    ]);
  });

  test('native bridge failures are sanitized and never fall back to the plugin',
      () async {
    final store = AndroidIdentityStore(available: () => true);
    nativeUnavailable = true;
    final failure = isA<DeviceIdentityFailure>()
        .having((value) => value.code, 'code', 'SECURE_STORAGE_FAILED');
    await expectLater(store.read(), throwsA(failure));
    final atomic = store as DeviceSecretCompareAndSet;
    await expectLater(atomic.compareAndSet(expected: null, value: 'new-record'),
        throwsA(failure));
    expect(events, ['identityRead', 'identityCompareAndSet']);
    expect(injectedRecord, 'original-injected-record');
  });

  test('explicit storage comparisons retain read and deletion flush barriers',
      () async {
    final store = AndroidIdentityStore(
        storage:
            const FlutterSecureStorage(aOptions: AndroidIdentityStore.options),
        available: () => true);
    final atomic = store as DeviceSecretCompareAndSet;
    expect(
        await atomic.compareAndSet(
            expected: 'original-injected-record',
            value: 'updated-injected-record'),
        isTrue);
    expect(
        await atomic.compareAndSet(
            expected: 'original-injected-record', value: 'stale-response'),
        isFalse);
    expect(injectedRecord, 'updated-injected-record');
    expect(
        await atomic.compareAndSet(
            expected: 'updated-injected-record', value: null),
        isTrue);
    expect(injectedRecord, isNull);
    expect(events, [
      'plugin:read',
      'flushIdentity',
      'plugin:write',
      'flushIdentity',
      'plugin:read',
      'flushIdentity',
      'plugin:read',
      'flushIdentity',
      'plugin:delete',
      'flushIdentity',
      'plugin:read',
      'flushIdentity'
    ]);
  });
}
