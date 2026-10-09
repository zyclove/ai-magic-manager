// Test-only cross-process store, deliberately NOT an encrypted production
// adapter. JUnit creates a restricted disposable directory and deletes all
// secret inputs/state on exit. Do not import this tool from an application.
import 'dart:convert';
import 'dart:io';
import 'package:device_identity/device_identity.dart';

class FixtureSecrets implements DeviceSecretStore {
  final File file;
  int writes = 0;
  int? failAt;
  FixtureSecrets(this.file);
  @override
  Future<String?> read() async =>
      await file.exists() ? file.readAsString() : null;
  @override
  Future<void> write(String record) async {
    writes++;
    if (writes == failAt) throw StateError('Intentional fixture write failure');
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(record, flush: true);
    await pending.rename(file.path);
  }
}

void check(bool condition) {
  if (!condition) throw StateError('HTTP identity fixture invariant failed');
}

Future<void> main(List<String> args) async {
  if (args.length != 2) throw ArgumentError('Fixture path and mode required');
  final fixture = File(args[0]);
  final input =
      Map<String, dynamic>.from(jsonDecode(await fixture.readAsString()));
  final root = Uri.parse(input['apiRoot']);
  if (input['testOnly'] != true ||
      root.scheme != 'http' ||
      root.host != '127.0.0.1') {
    throw ArgumentError('Only isolated loopback fixtures are permitted');
  }
  final api = DeviceIdentityApi(apiRoot: root, allowLoopbackHttp: true);
  final state = File('${fixture.parent.path}/identity-state.json');
  var store = FixtureSecrets(state);
  DeviceIdentityManager manager() => DeviceIdentityManager(
      api: api,
      secrets: store,
      nowMillis: () => DateTime.now().millisecondsSinceEpoch);
  try {
    switch (args[1]) {
      case 'claim-lost':
        store.failAt = 3;
        try {
          await manager().begin(
              EnrollmentTicket(
                  tenantId: input['tenantId'],
                  enrollmentId: input['enrollmentId'],
                  token: input['token'],
                  expiresAt: input['expiresAt']),
              displayName: 'Dart HTTP fixture',
              osVersion: '14');
          throw StateError('Fixture did not inject the expected failure');
        } on DeviceIdentityFailure catch (failure) {
          check(failure.code == 'SECURE_STORAGE_FAILED');
        }
        check((await manager().view()).phase == IdentityPhase.claimUncertain);
      case 'recover':
        await manager().recoverClaim();
        check((await manager().view()).phase ==
            IdentityPhase.awaitingConfirmation);
        check(await manager().activeCredential() == null);
        check(await manager().pairingCode() != null);
      case 'activate-rotate':
        final host = manager();
        await host.heartbeat(agentVersion: 'http-fixture', capabilities: []);
        final old = await host.activeCredential();
        check(old != null);
        await host.rotate();
        check(await host.activeCredential() == old);
        await host.heartbeat(agentVersion: 'http-fixture', capabilities: []);
        store.failAt = store.writes + 2;
        try {
          await host.activateRotation();
          throw StateError('Expected fixture storage failure');
        } on DeviceIdentityFailure catch (failure) {
          check(failure.code == 'SECURE_STORAGE_FAILED');
        }
        check((await host.view()).phase == IdentityPhase.activationUncertain);
        check(await host.activeCredential() == null);
        store = FixtureSecrets(state);
        await manager().activateRotation();
        final current = await manager().activeCredential();
        check(current != null && current != old);
        await manager()
            .heartbeat(agentVersion: 'http-fixture', capabilities: []);
        check((await manager().view()).heartbeatSequence == 3);
        check(!(await manager().view()).systemEnforced);
      case 'revoked':
        try {
          await manager()
              .heartbeat(agentVersion: 'http-fixture', capabilities: []);
          throw StateError('Revoked credential was accepted');
        } on DeviceIdentityFailure catch (failure) {
          check(failure.status == 401 && !failure.retryable);
        }
        final view = await manager().view();
        check(view.cloudAuthenticationBlocked &&
            view.heartbeatPending &&
            view.heartbeatSequence == 3);
        check(await manager().activeCredential() == null);
      default:
        throw ArgumentError('Unknown fixture mode');
    }
    stdout.writeln('PASS device identity ${args[1]}');
  } finally {
    api.close();
  }
}
