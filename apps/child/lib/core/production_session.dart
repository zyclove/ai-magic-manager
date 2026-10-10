import 'package:device_identity/device_identity.dart';
import 'package:device_observation/device_observation.dart' as observation;
import 'package:device_policy/device_policy.dart'
    show DeviceConfigurationTransport;
import 'package:http/http.dart' as http;
import 'package:sembast/sembast.dart';
import '../platform/configuration_database.dart';
import '../platform/observation_source.dart';
import '../platform/secret_store.dart';
import 'access_receiver.dart';
import 'environment.dart';
import 'rule_receiver.dart';
import 'session.dart';
import 'submission_receiver.dart';

/// Platform ports only: replacing a store/source cannot disable a business
/// factory or substitute a rule, approval, authentication or observation agent.
/// Construction performs no platform access, database opening or collection.
class ChildPlatformServices {
  final DeviceSecretStore identityStore;
  final observation.ObservationStore observationStore;
  final observation.ObservationSource observationSource;
  final Future<Database> Function() openConfigurations;
  const ChildPlatformServices(
      {required this.identityStore,
      required this.observationStore,
      required this.observationSource,
      required this.openConfigurations});

  factory ChildPlatformServices.android() => ChildPlatformServices(
      identityStore: AndroidIdentityStore(),
      observationStore: AndroidObservationStore(),
      observationSource: AndroidObservationSource(),
      openConfigurations: () => openConfigurationDatabase());
}

/// The single production composition shared by main and integration journeys.
/// Reports/UI remain outer consumers of the same session and platform source.
/// None of these components grants DPC authority or claims OS enforcement.
class ProductionChildRuntime {
  final ChildSession session;
  final observation.ObservationSource observationSource;
  ProductionChildRuntime._(this.session, this.observationSource);

  factory ProductionChildRuntime.create(
      {required ChildEnvironment environment,
      required bool nativeAvailable,
      ChildPlatformServices? platform,
      http.Client? identityClient,
      int Function()? nowMillis}) {
    final services = platform ?? ChildPlatformServices.android();
    // OS wall time with existing persisted rollback detection, not trusted
    // hardware time. A ticket never supplies an origin or a trust ring.
    final clock = nowMillis ?? () => DateTime.now().millisecondsSinceEpoch;
    final identity = DeviceIdentityManager(
        api: DeviceIdentityApi(
            apiRoot: environment.apiRoot,
            allowLoopbackHttp: environment.allowLoopbackHttp,
            client: identityClient),
        secrets: services.identityStore,
        nowMillis: clock);
    final session = ChildSession(
        identity: identity,
        nowMillis: clock,
        ruleReceiverFactory: nativeAvailable
            ? (view) => SignedRuleReceiver.open(
                environment, identity, view, clock,
                databaseOpener: services.openConfigurations)
            : null,
        submissionFactory: nativeAvailable
            ? (view) async => ChildSubmissionReceiver(
                environment: environment,
                identity: view,
                credential: identity.activeCredential,
                nowMillis: clock)
            : null,
        accessFactory: nativeAvailable
            ? (view, baseline) async => SignedAccessReceiver(
                environment: environment,
                identity: view,
                credential: identity.activeCredential,
                readBaseline: baseline,
                nowMillis: clock)
            : null,
        observations: nativeAvailable
            ? () async {
                try {
                  final facts = await services.observationSource.inspect();
                  return [
                    {
                      'key': 'usage.report',
                      'reportedSupported': facts.usageSupported,
                      'grantStatus': facts.usageGrantStatus
                    }
                  ];
                } catch (_) {
                  return [];
                }
              }
            : null,
        observationFactory: nativeAvailable
            ? (view) async => observation.ObservationAgent(
                scope: observation.ObservationScope(
                    view.tenantId, view.deviceId!, view.registrationId!),
                store: services.observationStore,
                source: services.observationSource,
                nowMillis: clock,
                api: observation.ObservationHttpApi(
                    DeviceConfigurationTransport(
                        apiRoot: environment.apiRoot,
                        credential: identity.activeCredential,
                        allowLoopbackHttp: environment.allowLoopbackHttp,
                        maxResponseBytes: 65536)))
            : null);
    return ProductionChildRuntime._(session, services.observationSource);
  }
}
