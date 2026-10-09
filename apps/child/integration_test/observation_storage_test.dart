import 'dart:convert';
import 'dart:io' show pid;
import 'package:child/platform/secret_store.dart';
import 'package:device_observation/device_observation.dart';
import 'package:device_policy/device_policy.dart' show DeviceTransportFailure;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _scope = ObservationScope(
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333');
const _now = 1800000000000;

/// Synthetic source: this journey certifies native persistence, not OS queries.
class _Source implements ObservationSource {
  int inventoryReads = 0, usageReads = 0;
  @override
  Future<ObservationPlatformState> inspect() async =>
      const ObservationPlatformState(
          usageGranted: true, unlocked: true, profile: 'PRIMARY');
  @override
  Future<List<Map<String, dynamic>>> inventory() async {
    inventoryReads++;
    return [
      {
        'packageName': 'org.example.observationstoragefixture',
        'displayName': 'Synthetic storage fixture',
        'profile': 'PRIMARY',
        'signingDigests': ['a' * 64],
        'versionCode': 1,
        'systemApplication': false
      }
    ];
  }

  @override
  Future<UsageSample> usage(
      {required int queryStart, required int queryEnd}) async {
    usageReads++;
    return UsageSample(
        queryStart: queryStart,
        queryEnd: queryEnd,
        observedAt: _now,
        timeZone: 'UTC',
        profile: 'PRIMARY',
        applications: [
          {
            'packageName': 'org.example.observationstoragefixture',
            'displayName': 'Synthetic storage fixture',
            'firstTimeStamp': queryStart,
            'lastTimeStamp': queryEnd,
            'foregroundMillis': 1000
          }
        ]);
  }

  @override
  Future<void> openUsageSettings() async =>
      throw StateError('No native permission request in a storage fixture');
}

/// No network. The actual encrypted record must already contain the exact body
/// before this explicit test substitute returns or loses an acknowledgement.
class _Api implements ObservationApi {
  final AndroidObservationStore store;
  final String phase;
  int inventoryCalls = 0, usageCalls = 0;
  String? originalInventory, originalUsage;
  bool comparedOriginal = false;
  _Api(this.store, this.phase);
  @override
  Future<Map<String, dynamic>> settings() async => {
        'deviceId': _scope.deviceId,
        'registrationId': _scope.registrationId,
        'version': 1,
        'inventoryEnabled': true,
        'usageEnabled': true,
        'updatedAt': _now
      };
  Future<Map<String, dynamic>> submit(
      Map<String, dynamic> body, bool usage) async {
    final raw = await store.read();
    expect(raw != null, isTrue);
    final journal = jsonDecode(raw!) as Map;
    final pending = journal[usage ? 'pendingUsage' : 'pendingInventory'];
    // Compare booleans: failed assertions never dump a report or encrypted key.
    expect(jsonEncode(pending) == jsonEncode(body), isTrue,
        reason: 'Exact original request must be durable before upload.');
    if ((!usage && phase == 'replay_inventory') ||
        (usage && phase == 'replay_usage')) {
      final original = usage ? originalUsage : originalInventory;
      expect(original != null && original == jsonEncode(body), isTrue,
          reason: 'Replay must equal the snapshot read before synchronize, '
              'including the original report ID.');
      comparedOriginal = true;
    }
    expect(body['sequence'] == 1 && body['authorizationVersion'] == 1, isTrue);
    if (usage) {
      usageCalls++;
    } else {
      inventoryCalls++;
    }
    if ((!usage && phase == 'write_inventory') ||
        (usage && phase == 'replay_inventory')) {
      throw const DeviceTransportFailure('NETWORK_TIMEOUT',
          outcomeUnknown: true);
    }
    return {
      'registrationId': _scope.registrationId,
      'sequence': body['sequence'],
      if (usage) 'reportId': body['reportId'],
      'receivedAt': _now
    };
  }

  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> body) =>
      submit(body, false);
  @override
  Future<Map<String, dynamic>> usage(Map<String, dynamic> body) =>
      submit(body, true);
  @override
  void close() {}
}

/// Dedicated owned debug installation only. Launch each phase in a separate OS
/// process without clearing or uninstalling data; the host verifies PID death.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'encrypted observation pending survives separate process launches',
      (tester) async {
    const phase = String.fromEnvironment('OBSERVATION_STORE_PHASE');
    expect(
        const [
          'write_inventory',
          'replay_inventory',
          'replay_usage',
          'verify_cleared'
        ].contains(phase),
        isTrue);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Text('Native observation storage verification'))));
    final store = AndroidObservationStore();
    final identityStore = AndroidIdentityStore();
    final identityBefore = await identityStore.read();
    final source = _Source(), api = _Api(store, phase);
    // Separate immutable oracle, read before the agent can update its journal.
    // Comparing only the upload-time store could miss a regenerated report ID.
    final persisted = await store.read();
    if (persisted != null) {
      final original = jsonDecode(persisted) as Map;
      api.originalInventory = jsonEncode(original['pendingInventory']);
      api.originalUsage = jsonEncode(original['pendingUsage']);
    }
    final agent = ObservationAgent(
        scope: _scope,
        store: store,
        api: api,
        source: source,
        nowMillis: () => _now);
    addTearDown(agent.close);
    final before = await agent.restore();
    if (phase == 'write_inventory') {
      expect(await store.read() == null, isTrue,
          reason: 'Refuse to overwrite any existing observation record.');
      await expectLater(
          agent.synchronize(),
          throwsA(isA<DeviceTransportFailure>().having(
              (failure) => failure.outcomeUnknown, 'unknown result', isTrue)));
      expect(source.inventoryReads, 1);
      expect(source.usageReads, 0);
      expect(api.inventoryCalls, 1);
    } else if (phase == 'replay_inventory') {
      expect(before.pendingReports, 1,
          reason:
              'Requires the preceding process to persist inventory pending.');
      await expectLater(
          agent.synchronize(),
          throwsA(isA<DeviceTransportFailure>().having(
              (failure) => failure.outcomeUnknown, 'unknown result', isTrue)));
      expect(source.inventoryReads, 0);
      expect(source.usageReads, 1);
      expect(api.inventoryCalls, 1);
      expect(api.usageCalls, 1);
    } else if (phase == 'replay_usage') {
      expect(before.pendingReports, 1,
          reason:
              'Requires usage pending from the preceding independent process.');
      final result = await agent.synchronize();
      expect(result.pendingReports, 0);
      expect(source.inventoryReads + source.usageReads, 0);
      expect(api.inventoryCalls, 0);
      expect(api.usageCalls, 1);
    } else {
      expect(before.pendingReports, 0);
      expect(before.authorization?.version, 1);
      expect(before.inventoryCount == 1 && before.usageCount == 1, isTrue);
      expect(
          before.lastInventoryAt == _now && before.lastUsageAt == _now, isTrue);
      expect(source.inventoryReads + source.usageReads, 0);
      expect(api.inventoryCalls + api.usageCalls, 0);
    }
    final after = await agent.restore();
    if (phase == 'write_inventory' || phase == 'replay_inventory') {
      expect(after.pendingReports, 1);
    }
    expect(await identityStore.read() == identityBefore, isTrue,
        reason: 'Observation persistence must not alter the identity record.');
    debugPrint('OBSERVATION_STORAGE_RESULT ${jsonEncode({
          'phase': phase,
          'pid': pid,
          'pendingReports': after.pendingReports,
          'inventoryReads': source.inventoryReads,
          'usageReads': source.usageReads,
          'originalRequestCompared': api.comparedOriginal,
          'identityUnchanged': true
        })}');
  });
}
