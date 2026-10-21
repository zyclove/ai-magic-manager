import 'dart:convert';
import 'package:device_observation/device_observation.dart';
import 'package:device_observation/src/journal.dart';
import 'package:test/test.dart';
import 'agent_test.dart' show MemoryStore, scope, Api, Source, initialNow;

class AtomicObservationStore extends MemoryStore
    implements ObservationCompareAndSet {
  int comparisons = 0;
  @override
  Future<bool> compareAndSet(
      {required String? expected, required String? replacement}) async {
    comparisons++;
    if (value != expected) return false;
    value = replacement;
    return true;
  }
}

void main() {
  final conflict = isA<ObservationFailure>()
      .having((e) => e.code, 'code', 'OBSERVATION_STATE_CONFLICT');
  test(
      'concurrent journal owners cannot overwrite usage or another report family',
      () async {
    final store = AtomicObservationStore();
    final seed = ObservationJournal(scope, store);
    await seed.load();
    seed.inventorySequence = 3;
    await seed.save();
    final front = ObservationJournal(scope, store),
        background = ObservationJournal(scope, store);
    await front.load();
    await background.load();
    background.usageSequence = 7;
    await background.save();
    front.permissionSequence = 2;
    await expectLater(front.save(), throwsA(conflict));
    expect(jsonDecode(store.value!)['usageSequence'], 7);
    expect(jsonDecode(store.value!)['permissionSequence'], 0);
    final fresh = ObservationJournal(scope, store);
    await fresh.load();
    fresh.permissionSequence = 2;
    await fresh.save();
    expect(jsonDecode(store.value!)['inventorySequence'], 3);
    expect(jsonDecode(store.value!)['usageSequence'], 7);
    expect(jsonDecode(store.value!)['permissionSequence'], 2);
  });
  test(
      'cleanup deletion cannot be resurrected by an older observation response',
      () async {
    final store = AtomicObservationStore();
    final journal = ObservationJournal(scope, store);
    await journal.load();
    await journal.save();
    final old = ObservationJournal(scope, store);
    await old.load();
    store.value = null;
    old.usageSequence = 1;
    await expectLater(old.save(), throwsA(conflict));
    expect(store.value, isNull);
  });
  test('storage must be loaded successfully before any atomic journal save',
      () async {
    final store = AtomicObservationStore();
    await expectLater(ObservationJournal(scope, store).save(),
        throwsA(isA<ObservationFailure>()));
    expect(store.comparisons, 0);
    store.value = 'corrupt private record';
    final broken = ObservationJournal(scope, store);
    await expectLater(broken.load(), throwsA(isA<ObservationFailure>()));
    await expectLater(broken.save(), throwsA(isA<ObservationFailure>()));
    expect(store.value, 'corrupt private record');
  });
  test('exact original bytes rather than reserialized JSON are compared',
      () async {
    final store = AtomicObservationStore();
    final seed = ObservationJournal(scope, store);
    await seed.load();
    await seed.save();
    store.value = '  ${store.value}\n';
    final journal = ObservationJournal(scope, store);
    await journal.load();
    journal.usageSequence = 2;
    await journal.save();
    expect(jsonDecode(store.value!)['usageSequence'], 2);
  });
  test(
      'native change during collection stops foreground before sending a conflicting sequence',
      () async {
    final store = AtomicObservationStore(),
        api = Api(store)
          ..usageEnabled = true
          ..version = 1;
    final source = Source();
    source.beforeUsage = () async {
      final background = ObservationJournal(scope, store);
      await background.load();
      background.usageSequence = 7;
      await background.save();
    };
    final agent = ObservationAgent(
        scope: scope,
        store: store,
        api: api,
        source: source,
        nowMillis: () => initialNow);
    await expectLater(agent.synchronize(), throwsA(conflict));
    expect(api.reports, 0);
    expect(jsonDecode(store.value!)['usageSequence'], 7);
  });
}
