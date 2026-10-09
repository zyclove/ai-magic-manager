import 'package:device_identity/device_identity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'core/environment.dart';
import 'core/rule_receiver.dart';
import 'core/session.dart';
import 'platform/secret_store.dart';
import 'ui/child_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.WARNING;
  Logger.root.onRecord.listen((record) => debugPrint(
      '${record.time.toUtc().toIso8601String()} ${record.level.name} ${record.loggerName} ${record.message}'));
  final nativeAvailable =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  ChildEnvironment? environment;
  try {
    environment = ChildEnvironment.fromBuild();
  } catch (_) {
    runApp(const ChildApp(deploymentInvalid: true));
    return;
  }
  if (environment == null) {
    runApp(const ChildApp());
    return;
  }
  final configured = environment;
  final api = DeviceIdentityApi(
      apiRoot: configured.apiRoot,
      allowLoopbackHttp: configured.allowLoopbackHttp);
  int clock() => DateTime.now().millisecondsSinceEpoch;
  // OS wall clock with persisted rollback detection, not hardware trusted time.
  final identity = DeviceIdentityManager(
      api: api, secrets: AndroidIdentityStore(), nowMillis: clock);
  final session = ChildSession(
      identity: identity,
      ruleReceiverFactory: (view) =>
          SignedRuleReceiver.open(configured, identity, view, clock));
  var osVersion = 'Android';
  if (nativeAvailable) {
    try {
      final facts = await const MethodChannel('com.aimanager.child/runtime')
          .invokeMapMethod<String, dynamic>('platformFacts');
      osVersion = facts?['osVersion'] as String? ?? osVersion;
    } catch (_) {
      /* Platform version is optional; no authority is derived from it. */
    }
  }
  runApp(ChildApp(
      session: session,
      serviceLabel: configured.apiRoot.toString(),
      nativeAvailable: nativeAvailable,
      osVersion: osVersion));
}
