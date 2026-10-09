import 'dart:convert';
import 'package:child/platform/secret_store.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scope =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const plugin = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const runtime = MethodChannel('com.aimanager.child/runtime');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, String> records;
  late List<String> calls;
  late bool durable;
  setUp(() {
    records = {};
    calls = [];
    durable = true;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      expect(key, 'access_key_v1_$scope');
      expect((args['options'] as Map)['resetOnError'], 'false');
      calls.add(call.method);
      if (call.method == 'read') return records[key];
      if (call.method == 'write') {
        records[key] = args['value'] as String;
        return null;
      }
      fail('Key storage must never reset, enumerate or delete');
    });
    messenger.setMockMethodCallHandler(runtime, (call) async {
      expect(call.method, 'flushIdentity');
      calls.add('flush');
      return durable;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(runtime, null);
  });
  test('new key becomes durable and is read back before any database can open',
      () async {
    final store = AndroidAccessKeyStore(available: () => true);
    final key = await store.keyFor(scope, existingDatabase: false);
    expect(key.length, 32);
    expect(base64Decode(records.values.single), key);
    expect(calls, ['read', 'flush', 'write', 'flush', 'read', 'flush']);
    final restored = await store.keyFor(scope, existingDatabase: true);
    expect(restored, key);
    expect(calls.where((v) => v == 'write').length, 1);
  });
  test('missing key for existing database and malformed key never regenerate',
      () async {
    final store = AndroidAccessKeyStore(available: () => true);
    await expectLater(
        store.keyFor(scope, existingDatabase: true),
        throwsA(isA<AccessFailure>()
            .having((e) => e.code, 'code', 'ACCESS_KEY_UNAVAILABLE')));
    records['access_key_v1_$scope'] = 'corrupt';
    await expectLater(store.keyFor(scope, existingDatabase: false),
        throwsA(isA<AccessFailure>()));
    expect(records.values.single, 'corrupt');
    expect(calls.contains('write'), isFalse);
  });
  test(
      'failed persistence barrier and unavailable platform cannot return a key',
      () async {
    durable = false;
    await expectLater(
        AndroidAccessKeyStore(available: () => true)
            .keyFor(scope, existingDatabase: false),
        throwsA(isA<AccessFailure>()));
    expect(calls, ['read', 'flush']);
    calls.clear();
    await expectLater(
        AndroidAccessKeyStore(available: () => false)
            .keyFor(scope, existingDatabase: false),
        throwsA(isA<AccessFailure>()));
    expect(calls, isEmpty);
  });
  test(
      'concurrent creation across instances serializes and keeps one durable key',
      () async {
    final keys = await Future.wait(List.generate(
        8,
        (_) => AndroidAccessKeyStore(available: () => true)
            .keyFor(scope, existingDatabase: false)));
    for (final key in keys) {
      expect(key, keys.first);
    }
    expect(calls.where((v) => v == 'write').length, 1);
  });
  test('invalid path-like scope is rejected before touching secure storage',
      () async {
    await expectLater(
        AndroidAccessKeyStore(available: () => true)
            .keyFor('../wrong', existingDatabase: false),
        throwsA(isA<AccessFailure>()));
    expect(calls, isEmpty);
  });
  test('failed write barrier keeps the same key for a later verified recovery',
      () async {
    var flushes = 0;
    messenger.setMockMethodCallHandler(runtime, (_) async => ++flushes != 2);
    final store = AndroidAccessKeyStore(available: () => true);
    await expectLater(store.keyFor(scope, existingDatabase: false),
        throwsA(isA<AccessFailure>()));
    expect(calls, ['read', 'write']);
    final stored = records.values.single;
    final recovered = await store.keyFor(scope, existingDatabase: false);
    expect(base64Encode(recovered), stored);
    expect(calls.where((v) => v == 'write').length, 1);
  });
  test('SDK read-back mismatch fails without rewriting the persisted key',
      () async {
    messenger.setMockMethodCallHandler(plugin, (call) async {
      final args = call.arguments as Map;
      calls.add(call.method);
      if (call.method == 'read') {
        return records.isEmpty ? null : base64Encode(List.filled(32, 0));
      }
      if (call.method == 'write') {
        records[args['key'] as String] = args['value'] as String;
        return null;
      }
      fail('Unexpected storage operation');
    });
    await expectLater(
        AndroidAccessKeyStore(available: () => true)
            .keyFor(scope, existingDatabase: false),
        throwsA(isA<AccessFailure>()));
    expect(records.length, 1);
    expect(calls.where((v) => v == 'write').length, 1);
  });
}
