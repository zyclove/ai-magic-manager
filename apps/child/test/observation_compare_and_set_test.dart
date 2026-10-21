import 'package:child/platform/secret_store.dart';
import 'package:device_observation/device_observation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runtime = MethodChannel('com.aimanager.child/runtime');
  const plugin = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late String? record;
  late List<String> calls;
  bool unavailable = false;
  setUp(() {
    record = 'native observation record';
    calls = [];
    unavailable = false;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      throw StateError('default observations must have one native owner');
    });
    messenger.setMockMethodCallHandler(runtime, (call) async {
      calls.add(call.method);
      if (unavailable) throw PlatformException(code: 'private failure');
      if (call.method == 'observationRead') return record;
      if (call.method == 'observationCompareAndSet') {
        final args = call.arguments as Map;
        if (args['expected'] != record) return false;
        record = args['replacement'] as String?;
        return true;
      }
      throw StateError('unexpected operation');
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(runtime, null);
    messenger.setMockMethodCallHandler(plugin, null);
  });
  test('default observations use the same native record and atomic comparison',
      () async {
    final store = AndroidObservationStore(available: () => true);
    expect(await store.read(), record);
    expect(
        await (store as ObservationCompareAndSet)
            .compareAndSet(expected: record, replacement: 'new usage'),
        isTrue);
    expect(record, 'new usage');
    expect(
        await store.compareAndSet(
            expected: 'native observation record', replacement: 'stale'),
        isFalse);
    expect(record, 'new usage');
    expect(calls, [
      'observationRead',
      'observationCompareAndSet',
      'observationCompareAndSet'
    ]);
  });
  test('atomic deletion cannot be undone by a stale observation write',
      () async {
    final store = AndroidObservationStore(available: () => true);
    final original = await store.read();
    expect(await store.compareAndSet(expected: original, replacement: null),
        isTrue);
    expect(
        await store.compareAndSet(
            expected: original, replacement: 'old HTTP reply'),
        isFalse);
    expect(record, isNull);
  });
  test(
      'native failure has no alternate storage path or sensitive error payload',
      () async {
    final store = AndroidObservationStore(available: () => true);
    unavailable = true;
    await expectLater(
        store.read(),
        throwsA(isA<ObservationFailure>()
            .having((e) => e.code, 'code', 'OBSERVATION_STORAGE_FAILED')));
    await expectLater(
        store.compareAndSet(expected: record, replacement: 'value'),
        throwsA(isA<ObservationFailure>()));
    expect(record, 'native observation record');
  });
}
