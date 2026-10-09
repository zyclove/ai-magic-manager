import 'package:device_identity/device_identity.dart';
import 'package:device_policy/device_policy.dart';
import 'package:sembast/sembast.dart';
import '../platform/configuration_database.dart';
import 'environment.dart';
import 'session.dart';

/// Receives CONFIGURE_ONLY documents; never reports APPLIED/system enforcement.
class SignedRuleReceiver implements ChildRuleReceiver {
  final Database database;
  final ConfigurationJournal journal;
  final DeviceConfigurationSynchronizer synchronizer;
  SignedRuleReceiver._(this.database, this.journal, this.synchronizer);
  static Future<ChildRuleReceiver> open(
      ChildEnvironment environment,
      DeviceIdentityManager identity,
      DeviceIdentityView view,
      int Function() clock) async {
    if (environment.configurationKeys == null ||
        environment.configurationIssuer.isEmpty) {
      throw const ConfigurationFailure('CONFIGURATION_TRUST_UNAVAILABLE');
    }
    final verifier = ConfigurationVerifier(
        scope: DevicePolicyScope(
            issuer: environment.configurationIssuer,
            tenantId: view.tenantId,
            deviceId: view.deviceId!,
            registrationId: view.registrationId!),
        trustedKeys: environment.configurationKeys!,
        nowMillis: clock);
    final database = await openConfigurationDatabase();
    try {
      final journal =
          ConfigurationJournal(database: database, verifier: verifier);
      final transport = DeviceConfigurationTransport(
          apiRoot: environment.apiRoot,
          credential: identity.activeCredential,
          allowLoopbackHttp: environment.allowLoopbackHttp);
      return SignedRuleReceiver._(
          database,
          journal,
          DeviceConfigurationSynchronizer(
              journal: journal, transport: transport));
    } catch (_) {
      await database.close();
      rethrow;
    }
  }

  Future<ChildRules> _snapshot({bool hasMore = false}) async => ChildRules(
      configurations: List.unmodifiable((await journal.restore()).values),
      cursor: await journal.cursor(),
      pendingReceipts: (await journal.pendingReceipts()).length,
      hasMore: hasMore);
  @override
  Future<ChildRules> restore() => _snapshot();
  @override
  Future<ChildRules> synchronize() async {
    final result = await synchronizer.synchronize();
    return _snapshot(hasMore: result.hasMore);
  }

  @override
  Future<void> close() async {
    synchronizer.close();
    await database.close();
  }
}
