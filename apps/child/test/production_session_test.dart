import 'package:child/core/access_receiver.dart';
import 'package:child/core/environment.dart';
import 'package:child/core/production_session.dart';
import 'package:child/core/rule_receiver.dart';
import 'package:child/core/submission_receiver.dart';
import 'package:device_observation/device_observation.dart' as observation;
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import '../../../packages/device_policy/test/fixtures.dart' as signatures;
import 'support/identity_fixture.dart';

class _ObservationStore implements observation.ObservationStore {
  String? value;
  int reads = 0;
  @override
  Future<String?> read() async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String value) async => this.value = value;
}

/// OS boundary substitute only. Business factories and journal implementations
/// below are the production classes; this is not evidence of Android querying.
class _Source implements observation.ObservationSource {
  int inspections = 0, collections = 0;
  bool unavailable = false;
  @override
  Future<observation.ObservationPlatformState> inspect() async {
    inspections++;
    if (unavailable) throw StateError('controlled unavailable platform');
    return const observation.ObservationPlatformState(
        usageGranted: false,
        usageGrantStatus: 'DENIED',
        unlocked: true,
        profile: 'PRIMARY');
  }

  @override
  Future<List<Map<String, dynamic>>> inventory() async {
    collections++;
    throw StateError('Unexpected collection');
  }

  @override
  Future<observation.UsageSample> usage(
      {required int queryStart, required int queryEnd}) async {
    collections++;
    throw StateError('Unexpected collection');
  }

  @override
  Future<void> openUsageSettings() async =>
      throw StateError('Unexpected settings launch');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('production construction is lazy and exposes every native base factory',
      () async {
    final source = _Source(), store = _ObservationStore();
    var databaseOpens = 0;
    final runtime = ProductionChildRuntime.create(
        environment: ChildEnvironment(
            apiRoot: Uri.parse('https://service.example/api/v1')),
        nativeAvailable: true,
        platform: ChildPlatformServices(
            identityStore: FixtureSecrets(),
            observationStore: store,
            observationSource: source,
            openConfigurations: () async {
              databaseOpens++;
              return databaseFactoryMemory.openDatabase('lazy');
            }));
    addTearDown(runtime.session.dispose);
    expect(runtime.session.ruleReceiverFactory, isNotNull);
    expect(runtime.session.accessFactory, isNotNull);
    expect(runtime.session.submissionFactory, isNotNull);
    expect(runtime.session.observationFactory, isNotNull);
    expect(runtime.session.observations, isNotNull);
    expect(identical(runtime.observationSource, source), isTrue);
    expect(source.inspections, 0);
    expect(source.collections, 0);
    expect(store.reads, 0);
    expect(databaseOpens, 0);
    expect(runtime.session.systemEnforced, isFalse);
  });

  test('unsupported platforms expose no Android factories or native I/O', () {
    final source = _Source(), store = _ObservationStore();
    final runtime = ProductionChildRuntime.create(
        environment: ChildEnvironment(
            apiRoot: Uri.parse('https://service.example/api/v1')),
        nativeAvailable: false,
        platform: ChildPlatformServices(
            identityStore: FixtureSecrets(),
            observationStore: store,
            observationSource: source,
            openConfigurations: () => throw StateError('Native I/O')));
    addTearDown(runtime.session.dispose);
    expect(runtime.session.ruleReceiverFactory, isNull);
    expect(runtime.session.accessFactory, isNull);
    expect(runtime.session.submissionFactory, isNull);
    expect(runtime.session.observationFactory, isNull);
    expect(runtime.session.observations, isNull);
    expect(source.inspections, 0);
    expect(source.collections, 0);
    expect(store.reads, 0);
  });

  test('all native factories construct the actual SDK backed receivers',
      () async {
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    final key = signatures.newKey(),
        source = _Source(),
        store = _ObservationStore();
    var databaseOpens = 0;
    final runtime = ProductionChildRuntime.create(
        environment: ChildEnvironment(
            apiRoot: Uri.parse('https://service.example/api/v1'),
            configurationIssuer: 'ai-manager',
            configurationKeys: signatures.publicRing(key)),
        nativeAvailable: true,
        identityClient: fixture.client,
        nowMillis: () => fixture.clock,
        platform: ChildPlatformServices(
            identityStore: fixture.secrets,
            observationStore: store,
            observationSource: source,
            openConfigurations: () async {
              databaseOpens++;
              return databaseFactoryMemory
                  .openDatabase('production-configuration');
            }));
    addTearDown(runtime.session.dispose);
    final session = runtime.session,
        view = await runtime.session.identity.view();
    final calls = fixture.calls;
    final rules = await session.ruleReceiverFactory!(view);
    expect(rules, isA<SignedRuleReceiver>());
    expect((await rules.restore()).configurations, isEmpty);
    await rules.close();
    final access = await session.accessFactory!(view, () async => []);
    expect(access, isA<SignedAccessReceiver>());
    await access.close();
    final requests = await session.submissionFactory!(view);
    expect(requests, isA<ChildSubmissionReceiver>());
    await requests.close();
    final observer = await session.observationFactory!(view);
    expect(observer, isA<observation.ObservationAgent>());
    await observer.restore();
    observer.close();
    expect(await session.observations!(), [
      {
        'key': 'usage.report',
        'reportedSupported': true,
        'grantStatus': 'DENIED'
      }
    ]);
    expect(databaseOpens, 1);
    expect(source.inspections, 1);
    expect(source.collections, 0);
    expect(fixture.calls, calls,
        reason:
            'Constructing factories cannot send HTTP or collect inventory.');
  });

  test(
      'platform inspection failure reports no invented capability or collection',
      () async {
    final source = _Source()..unavailable = true;
    final runtime = ProductionChildRuntime.create(
        environment: ChildEnvironment(
            apiRoot: Uri.parse('https://service.example/api/v1')),
        nativeAvailable: true,
        platform: ChildPlatformServices(
            identityStore: FixtureSecrets(),
            observationStore: _ObservationStore(),
            observationSource: source,
            openConfigurations: () => throw StateError('Unexpected I/O')));
    addTearDown(runtime.session.dispose);
    expect(await runtime.session.observations!(), isEmpty);
    expect(source.inspections, 1);
    expect(source.collections, 0);
  });
}
