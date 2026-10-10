import 'dart:convert';
import 'dart:io';
import 'package:child/core/environment.dart';
import 'package:child/core/production_session.dart';
import 'package:child/core/report_loader.dart';
import 'package:child/platform/access_database.dart';
import 'package:child/platform/configuration_database.dart';
import 'package:child/platform/observation_source.dart';
import 'package:child/platform/secret_store.dart';
import 'package:child/ui/child_app.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_observation/device_observation.dart' as observation;
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:usage_report_ui/usage_report_ui.dart';
import 'support/scoped_bindings.dart';

/// The existing native journey owns this installation, private input and run
/// marker. Only the OS/store ports are scoped; every business factory is the
/// production factory also used by main.dart. No local test server or fake
/// response is present in this Android process.
class _ScopedIdentity implements DeviceSecretStore {
  final AndroidAccessBindingStore store;
  final String key;
  _ScopedIdentity(this.store, this.key);
  @override
  Future<String?> read() => store.read(key);
  @override
  Future<void> write(String value) => store.write(key, value);
}

class _ScopedObservation implements observation.ObservationStore {
  final AndroidIdentityStore backend;
  final String key;
  _ScopedObservation(this.backend, this.key);
  @override
  Future<String?> read() async {
    final value = await backend.storage.read(key: key);
    await backend.read(); // Native durability barrier for the same pref file.
    return value;
  }

  @override
  Future<void> write(String value) async {
    if (utf8.encode(value).length > 1048576) {
      throw const observation.ObservationFailure('OBSERVATION_STORAGE_FAILED');
    }
    await backend.storage.write(key: key, value: value);
    await backend.read();
  }
}

final _owners = <Object>[];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('production child composes all native channels with real Spring',
      (tester) async {
    const phase = String.fromEnvironment('ANDROID_HTTP_PHASE');
    const leaf = String.fromEnvironment('ANDROID_HTTP_INPUT');
    expect(phase,
        isIn(const ['production', 'observation', 'observation-revoked']));
    expect(RegExp(r'^android-http-[0-9a-f]{32}\.json$').hasMatch(leaf), isTrue);
    final support = await getApplicationSupportDirectory();
    final privateInput = File(path.join(support.path, leaf));
    final fixture =
        jsonDecode(await privateInput.readAsString()) as Map<String, dynamic>;
    await privateInput.delete();
    expect(fixture['schemaVersion'], 1);
    final apiRoot = Uri.parse(fixture['apiRoot'] as String);
    expect(apiRoot.scheme, 'http');
    expect(apiRoot.host, '127.0.0.1');
    final runId = fixture['runId'] as String;
    final tenant = fixture['tenantId'] as String;
    final device = fixture['deviceId'] as String;
    final registration = fixture['registrationId'] as String;
    String storageKey(String purpose) => policy.DevicePolicyScope(
            issuer: '$purpose|$apiRoot|$runId',
            tenantId: tenant,
            deviceId: runId,
            registrationId: runId)
        .storageKey;
    final native = AndroidIdentityStore();
    final bindings = AndroidAccessBindingStore();
    final isolatedBindings = ScopedBindings(bindings, runId);
    final normalIdentity = await native.read();
    final normalObservation = await AndroidObservationStore().read();
    final normalConfiguration =
        File(path.join(support.path, 'configuration-v1.db'));
    final originalConfigBytes = await normalConfiguration.exists()
        ? await normalConfiguration.readAsBytes()
        : null;
    final oracle = await bindings.read(storageKey('android-http-oracle-v1'));
    expect(oracle, isNotNull, reason: 'Requires the earlier owned enrollment.');
    final secrets =
        _ScopedIdentity(bindings, storageKey('android-http-identity-v1'));
    expect(await secrets.read(), isNotNull);
    final privateDirectory =
        Directory(path.join(support.path, 'production-http-$runId'));
    if (phase == 'production') {
      expect(await privateDirectory.exists(), isFalse,
          reason: 'Never overwrite a previous acceptance run.');
      await privateDirectory.create();
    } else {
      expect(await privateDirectory.exists(), isTrue,
          reason: 'Observation must reuse the owned production scope.');
    }
    final source = AndroidObservationSource();
    final environment = ChildEnvironment(
        apiRoot: apiRoot,
        allowLoopbackHttp: true,
        configurationIssuer: fixture['configurationIssuer'] as String,
        configurationKeys:
            Map<String, dynamic>.from(fixture['configurationKeys'] as Map));
    final runtime = ProductionChildRuntime.create(
        environment: environment,
        nativeAvailable: true,
        platform: ChildPlatformServices(
            identityStore: secrets,
            observationStore: _ScopedObservation(native,
                'observation_joint_${storageKey('android-http-joint-v1')}'),
            observationSource: source,
            openConfigurations: () =>
                openConfigurationDatabase(directoryPath: privateDirectory.path),
            accessBindings: isolatedBindings,
            openAccess: (key) =>
                openAccessDatabase(key, directoryPath: privateDirectory.path),
            openSubmissions: (key, {required existingDatabase}) =>
                openAccessDatabase(key,
                    directoryPath: privateDirectory.path,
                    requireExisting: existingDatabase)));
    final session = runtime.session;
    expect(session.ruleReceiverFactory, isNotNull);
    expect(session.accessFactory, isNotNull);
    expect(session.submissionFactory, isNotNull);
    expect(session.observationFactory, isNotNull);
    final reports = DeviceChildReports(
        session: session,
        apiRoot: apiRoot,
        allowLoopbackHttp: true,
        inspect: runtime.observationSource.inspect);
    await tester.pumpWidget(ChildApp(
        session: session,
        nativeAvailable: true,
        serviceLabel: apiRoot.toString(),
        osVersion: 'Android API34 acceptance',
        reportFactory: (_) => reports));
    Future<void> idle() async {
      final deadline = DateTime.now().add(const Duration(seconds: 35));
      while (!session.initialized || session.busy) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Production Android session deadline');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    await idle();
    expect(session.identityView!.deviceId, device);
    expect(session.identityView!.registrationId, registration);
    if (phase == 'production') {
      expect(session.identityView!.phase, IdentityPhase.awaitingConfirmation);
      expect(await session.checkConnection(), isTrue);
      await idle();
      expect(session.identityView!.phase, IdentityPhase.active);
      expect(session.identityView!.heartbeatSequence, 1);
      expect(await session.synchronizeRules(), isTrue);
      await idle();
      expect(session.rules.configurations, hasLength(1));
      expect(session.rules.pendingReceipts, 0);
      expect(session.rules.configurations.single.document?['name'], '原生阅读安排');
      expect(session.systemEnforced, isFalse);
      expect(await session.synchronizeAccess(), isTrue);
      await idle();
      expect(session.access.contextReady, isTrue);
      expect(await session.refreshSubmissions(), isTrue);
      await idle();
      expect(session.submissions.contextReady, isTrue);
      expect(session.submissions.onlineConfirmed, isTrue);
    } else {
      expect(session.identityView!.phase, IdentityPhase.active);
      expect(session.identityView!.heartbeatSequence, 1);
    }
    final platform = await source.inspect();
    expect(platform.unlocked, isTrue);
    expect(platform.usageSupported, isTrue);
    final inventory = await source.inventory();
    expect(inventory, isNotEmpty);
    expect(
        inventory
            .any((app) => app['packageName'] == 'com.aimanager.child.debug'),
        isTrue);
    if (phase == 'production') {
      // Inspecting capabilities does not silently grant system or cloud access.
      expect(platform.usageGranted, isFalse);
    } else {
      // The host grants only this owned app real Android special access. The
      // guardian separately changes cloud consent through the management API.
      expect(platform.usageGranted, isTrue);
      expect(await session.refreshObservationAuthorization(), isTrue);
      await idle();
      expect(session.observationView.onlineConfirmed, isTrue);
      expect(session.observationView.authorization!.usageEnabled,
          phase == 'observation');
      expect(await session.synchronizeObservations(), isTrue);
      await idle();
      expect(session.observationView.pendingReports, 0);
      if (phase == 'observation') {
        expect(session.observationView.usageCount, greaterThan(0));
        expect(session.observationView.lastUsageAt, isNotNull);
      } else {
        expect(session.observationView.usageCount, 0);
        expect(session.observationView.lastUsageAt, isNull);
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final report = await reports
        .load(DeviceReportWindow(now - 3600000, now, 'UTC', 'DAY'));
    expect(report.devices.single.deviceId, device);
    expect(report.devices.single.status,
        phase == 'observation' ? 'OBSERVED' : 'NOT_AUTHORIZED');
    if (phase == 'production') {
      await tester.tap(find.text('规则').last);
      await tester.pumpAndSettle();
      expect(find.text('原生阅读安排'), findsOneWidget);
      expect(find.text('临时访问申请'), findsOneWidget);
    }
    await tester.tap(find.text('使用').last);
    await tester.pumpAndSettle();
    expect(find.text('我的使用情况'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(await native.read(), normalIdentity);
    expect(await AndroidObservationStore().read(), normalObservation);
    expect(await normalConfiguration.exists(), originalConfigBytes != null);
    if (originalConfigBytes != null) {
      expect(await normalConfiguration.readAsBytes(), originalConfigBytes);
    }
    binding.reportData = {
      'phase': phase,
      'pid': pid,
      'configurationCount': session.rules.configurations.length,
      'configurationReceiptPending': session.rules.pendingReceipts,
      'accessContextReady': session.access.contextReady,
      'submissionOnlineConfirmed': session.submissions.onlineConfirmed,
      'nativeUsageGranted': platform.usageGranted,
      'nativeApplicationCount': inventory.length,
      'reportStatus': report.devices.single.status,
      'authorizationVersion': session.observationView.authorization?.version,
      'usageCount': session.observationView.usageCount,
      'lastUsageAt': session.observationView.lastUsageAt,
      'globalRecordsUnchanged': true,
      'systemEnforced': false,
    };
    // The host terminates this PID; the exact scoped directory and keys are
    // removed by the owned final cleanup phase after subsequent requests.
    _owners.addAll([runtime, session, reports]);
  });
}
