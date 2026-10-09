// Test-only synthetic source and plaintext cross-process store. Never a native
// or encrypted production adapter. JUnit supplies disposable loopback fixtures.
import 'dart:convert';
import 'dart:io';
import 'package:device_observation/device_observation.dart';
import 'package:device_policy/device_policy.dart';

void check(bool value) {
  if (!value) throw StateError('Fixture assertion failed');
}

class FixtureStore implements ObservationStore {
  final File file;
  FixtureStore(this.file);
  @override
  Future<String?> read() async =>
      await file.exists() ? file.readAsString() : null;
  @override
  Future<void> write(String value) =>
      file.writeAsString(value, flush: true).then((_) {});
}

class FixtureSource implements ObservationSource {
  final int now;
  int reads = 0;
  FixtureSource(this.now);
  @override
  Future<ObservationPlatformState> inspect() async =>
      const ObservationPlatformState(
          usageGranted: true, unlocked: true, profile: 'PRIMARY');
  @override
  Future<List<Map<String, dynamic>>> inventory() async {
    reads++;
    return [
      {
        'packageName': 'org.example.reader',
        'displayName': 'Fixture reader',
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
    reads++;
    return UsageSample(
        queryStart: queryStart,
        queryEnd: queryEnd,
        observedAt: now,
        timeZone: 'UTC',
        profile: 'PRIMARY',
        applications: [
          {
            'packageName': 'org.example.reader',
            'displayName': 'Fixture reader',
            'firstTimeStamp': queryStart,
            'lastTimeStamp': queryEnd,
            'foregroundMillis': 120000
          }
        ]);
  }

  @override
  Future<void> openUsageSettings() async =>
      throw StateError('Not a native fixture');
}

class DropAcknowledgement implements ObservationApi {
  final ObservationApi delegate;
  DropAcknowledgement(this.delegate);
  @override
  Future<Map<String, dynamic>> settings() => delegate.settings();
  @override
  Future<Map<String, dynamic>> inventory(Map<String, dynamic> body) =>
      delegate.inventory(body);
  @override
  Future<Map<String, dynamic>> usage(Map<String, dynamic> body) async {
    await delegate
        .usage(body); // Server commits before the simulated lost response.
    throw const DeviceTransportFailure('NETWORK_TIMEOUT', outcomeUnknown: true);
  }

  @override
  void close() => delegate.close();
}

Future<void> run(List<String> args) async {
  check(args.length == 2 &&
      const ['off', 'lost', 'replay', 'withdraw', 'regrant', 'revoked']
          .contains(args[1]));
  final fixture = File(args[0]),
      input = jsonDecode(await File(args[0]).readAsString()) as Map;
  final root = Uri.parse(input['apiRoot'] as String), mode = args[1];
  check(input['testOnly'] == true &&
      root.scheme == 'http' &&
      root.host == '127.0.0.1' &&
      root.path == '/api/v1');
  final store =
      FixtureStore(File('${fixture.parent.path}/observation-state.json'));
  final saved = File('${fixture.parent.path}/lost-pending.json');
  if (mode == 'regrant') await store.write(await saved.readAsString());
  final source = FixtureSource(input['now']);
  final transport = ObservationHttpApi(DeviceConfigurationTransport(
      apiRoot: root,
      credential: () async => input['credential'] as String,
      allowLoopbackHttp: true));
  final agent = ObservationAgent(
      scope: ObservationScope(
          input['tenantId'], input['deviceId'], input['registrationId']),
      store: store,
      api: mode == 'lost' ? DropAcknowledgement(transport) : transport,
      source: source,
      nowMillis: () => input['now']);
  try {
    if (mode == 'lost' || mode == 'revoked') {
      try {
        await agent.synchronize();
        throw StateError('Expected a transport failure');
      } on DeviceTransportFailure catch (failure) {
        check(mode == 'lost' ? failure.outcomeUnknown : failure.status == 401);
      }
      final restored = await agent.restore();
      check(mode == 'lost'
          ? restored.pendingReports == 1 && source.reads == 2
          : restored.pendingReports == 0 &&
              restored.authorization == null &&
              source.reads == 0);
      if (mode == 'lost') {
        await saved.writeAsString((await store.read())!, flush: true);
      }
    } else {
      final view = await agent.synchronize();
      check(view.pendingReports == 0 && view.onlineConfirmed);
      if (mode == 'off' || mode == 'withdraw') {
        check(source.reads == 0 && view.authorization!.usageEnabled == false);
      } else if (mode == 'replay') {
        check(source.reads == 0 && view.lastUsageAt != null);
      } else {
        check(source.reads == 2 &&
            view.authorization!.version == 3 &&
            view.lastUsageAt != null);
      }
    }
    stdout.writeln('PASS observation device $mode');
  } finally {
    agent.close();
  }
}

Future<void> main(List<String> args) async {
  try {
    await run(args);
  } catch (_) {
    stderr.writeln('FAIL isolated observation device fixture');
    exitCode = 1;
  }
}
