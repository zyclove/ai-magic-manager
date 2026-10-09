import 'dart:convert';
import 'dart:io';
import 'package:device_policy/device_policy.dart';
import 'package:sembast/sembast_io.dart';

/// Only for the isolated Spring test fixture. No credential is printed or
/// passed on the command line; the fixture file is removed by the JVM owner.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || !{'sync', 'revoked'}.contains(arguments[1])) {
    throw ArgumentError('Provide fixture path and test mode');
  }
  final file = File(arguments[0]);
  final data = jsonDecode(await file.readAsString());
  final root = Uri.parse(data['apiRoot']);
  if (root.scheme != 'http' || root.host != '127.0.0.1') {
    throw ArgumentError('Only an isolated loopback test fixture is allowed');
  }
  final scope = DevicePolicyScope(
      issuer: 'ai-manager',
      tenantId: data['tenantId'],
      deviceId: data['deviceId'],
      registrationId: data['registrationId']);
  final db = await databaseFactoryIo
      .openDatabase('${file.parent.path}/device-cache.db');
  final journal = ConfigurationJournal(
      database: db,
      verifier: ConfigurationVerifier(
          scope: scope,
          trustedKeys: Map<String, dynamic>.from(data['publicKeys']),
          nowMillis: () => DateTime.now().millisecondsSinceEpoch));
  final transport = DeviceConfigurationTransport(
      apiRoot: root,
      credential: () async => data['credential'],
      allowLoopbackHttp: true);
  final sync = DeviceConfigurationSynchronizer(
      journal: journal, transport: transport, pageSize: 1, maxPages: 5);
  try {
    if (arguments[1] == 'sync') {
      final result = await sync.synchronize();
      if (result.cursor != 2 ||
          result.pages != 2 ||
          result.storedConfigurations != 2 ||
          result.receiptsAcknowledged != 2 ||
          result.hasMore ||
          result.systemEnforced ||
          (await journal.restore()).length != 2 ||
          (await journal.pendingReceipts()).isNotEmpty) {
        throw StateError('Spring HTTP synchronization assertions failed');
      }
      stdout.writeln(
          'Spring HTTP -> Dart JOSE -> file transaction -> STORED: PASS');
    } else {
      bool denied = false;
      try {
        await sync.synchronize();
      } on DeviceTransportFailure catch (error) {
        denied = error.status == 401 &&
            error.code == 'DEVICE_UNAUTHENTICATED' &&
            !error.retryable;
      }
      if (!denied ||
          (await journal.restore()).length != 2 ||
          await journal.cursor() != 2) {
        throw StateError('Revocation/restoration assertions failed');
      }
      stdout.writeln(
          'Actual opaque credential revocation and cached recovery: PASS');
    }
  } finally {
    sync.close();
    await db.close();
  }
}
