import 'dart:convert';
import 'dart:io';
import 'package:child/core/cleanup_runner.dart';
import 'package:child/core/environment.dart';
import 'package:child/core/session.dart' show parseRegistrationTicket;
import 'package:child/platform/access_database_io.dart';
import 'package:child/platform/configuration_database_io.dart';
import 'package:child/platform/device_keys.dart';
import 'package:child/platform/secret_store.dart';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'support/cleanup_https_certificate.dart';

final _accessScope = 'b' * 64;
const _cacheMarker = 'native-https-cleanup-private-cache';
const _unrelatedMarker = 'preserve-unrelated-native-https-file';
final _nativeAlias = RegExp(
    r'^aimanager\.device\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// One APK, separate process launches, and a dedicated empty debug installation.
/// The host supplies a real local HTTPS service and public certificate. Adult
/// authentication is a fixture; device registration, TLS, cleanup commands,
/// receipts, Android keys and encrypted storage use their production paths.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('HTTPS cleanup retains final acknowledgement across processes',
      (tester) async {
    final directory = await getApplicationSupportDirectory();
    final input = await _consumeInput(directory);
    final store = AndroidIdentityStore();
    await store.flushAgentFiles(directory.path);
    final endpoint = input.apiRoot
        .replace(path: '${input.apiRoot.path}/device-api/configurations');

    // A connection error is insufficient evidence: the same endpoint must
    // explicitly reject this process's initially untrusted certificate.
    await expectLater(
        _untrustedRequest(endpoint), throwsA(isA<HandshakeException>()));
    SecurityContext.defaultContext.setTrustedCertificatesBytes(
        cleanupTestCertificatePem(input.certificate));

    final keys = AndroidDeviceKeys();
    final api = DeviceIdentityApi(apiRoot: input.apiRoot);
    addTearDown(api.close);
    final identity = DeviceIdentityManager(
        api: api, secrets: store, keys: keys, nowMillis: _nowMillis);
    final oracleFile = File('${directory.path}/cleanup-https-oracle.json');
    final handoffFile = File('${directory.path}/cleanup-https-handoff.json');
    final markerFile = File('${directory.path}/unrelated-https-marker.txt');
    Map<String, dynamic> oracle;

    if (input.phase == 'enroll') {
      expect(await oracleFile.exists(), isFalse);
      expect(await handoffFile.exists(), isFalse);
      expect(await markerFile.exists(), isFalse);
      expect(await store.read() == null, isTrue,
          reason: 'Dedicated empty debug installation required');
      expect((await store.storage.readAll()).isEmpty, isTrue);
      await _databaseFilesAbsent(directory);
      final ticket = parseRegistrationTicket(jsonEncode(input.ticket));
      expect(ticket.tenantId == input.tenantId, isTrue);
      await identity.begin(ticket,
          displayName: 'Native HTTPS cleanup acceptance',
          osVersion: 'Android API34');
      final view = await identity.view();
      expect(view.phase == IdentityPhase.awaitingConfirmation, isTrue);
      expect(view.tenantId == input.tenantId, isTrue);
      expect(validUuid(view.deviceId), isTrue);
      expect(validUuid(view.registrationId), isTrue);
      final state = _jsonObject((await store.read())!);
      final handle = state['keyHandle'];
      expect(handle is String && _nativeAlias.hasMatch(handle), isTrue);
      final proof = await keys.cleanupProof(handle as String, input.tenantId,
          view.deviceId!, view.registrationId!, 'READ', null, _nowMillis());
      expect(validSecret(proof.keyThumbprint), isTrue);
      expect(proof.compact.isNotEmpty, isTrue);
      final pairing = await identity.pairingCode();
      expect(pairing != null && RegExp(r'^[A-Z0-9]{8}$').hasMatch(pairing),
          isTrue);
      await handoffFile.writeAsString(
          jsonEncode({
            'deviceId': view.deviceId,
            'registrationId': view.registrationId,
            'pairingCode': pairing,
          }),
          flush: true);
      oracle = {
        'runId': input.runId,
        'phase': 'enroll',
        'scope': {
          'tenantId': input.tenantId,
          'subjectId': input.subjectId,
          'deviceId': view.deviceId,
          'registrationId': view.registrationId,
        },
        'nativeKeyHandle': handle,
        'thumbprint': proof.keyThumbprint,
      };
      await markerFile.writeAsString(_unrelatedMarker, flush: true);
    } else {
      expect(await oracleFile.exists(), isTrue,
          reason: 'NATIVE_CLEANUP_HTTPS_MISSING_SEED');
      oracle = _jsonObject(await oracleFile.readAsString());
      _validateOracle(oracle, input);
      expect(await markerFile.readAsString() == _unrelatedMarker, isTrue);
      final scopeMap = oracle['scope'] as Map<String, dynamic>;
      final scope = CleanupScope(input.tenantId, scopeMap['deviceId'] as String,
          scopeMap['registrationId'] as String, oracle['thumbprint'] as String);
      if (input.phase == 'active') {
        final awaiting = await identity.view();
        expect(awaiting.phase == IdentityPhase.awaitingConfirmation, isTrue);
        _validateIdentityScope(awaiting, scope);
        // The host confirms the real pairing between these two processes.
        await identity.heartbeat(
            agentVersion: 'cleanup-https-test', capabilities: const []);
        final active = await identity.view();
        expect(active.phase == IdentityPhase.active, isTrue);
        _validateIdentityScope(active, scope);
        expect(await identity.activeCredential() != null, isTrue);
        await _originalKeyStillSigns(identity, oracle);
        await _databaseFilesAbsent(directory);
        await _seedCaches(directory, store);
        // The pairing code was needed only for the host's confirmation step.
        if (await handoffFile.exists()) await handoffFile.delete();
      } else {
        if (input.phase == 'cleanup') {
          final active = await identity.view();
          expect(active.phase == IdentityPhase.active, isTrue);
          _validateIdentityScope(active, scope);
          await _originalKeyStillSigns(identity, oracle);
          await _seededCachesPresent(directory, store);
          final credential = await identity.activeCredential();
          expect(credential != null, isTrue);
          expect(await _authenticatedStatus(endpoint, credential!), 401,
              reason: 'Ordinary device credential must already be revoked');
          expect(
              await _runner(input, identity, store).runOnce() ==
                  CleanupRunStage.keyRemoved,
              isTrue);
        }
        await _cleanupComplete(directory, store, keys, oracle, input, scope);
        if (input.phase == 'verify' || input.phase == 'negative') {
          expect(
              await _runner(input, identity, store).runOnce() == null, isTrue);
          // A no-op startup must also preserve the final acknowledgement.
          await _cleanupComplete(directory, store, keys, oracle, input, scope);
        }
      }
      oracle['phase'] = input.phase;
    }
    await oracleFile.writeAsString(jsonEncode(oracle), flush: true);
    expect(await markerFile.readAsString() == _unrelatedMarker, isTrue);
    expect(await File('${directory.path}/cleanup-https-input.json').exists(),
        isFalse);
    await store.flushForCleanup();
    await store.flushAgentFiles(directory.path);
    final completed = input.phase == 'cleanup' || input.phase == 'verify';
    final result = {
      'phase': input.phase,
      'pid': pid,
      'realTls': true,
      'untrustedCertificateRejected': true,
      'realAndroidKey': true,
      'cloudResponsesAreReal': true,
      'adultIdentityIsFixture': true,
      'cleanupCompleted': completed,
      'journalRetained': completed,
      'originalKeyDeleted': completed,
      'cachesDeleted': completed,
      'physicalWipeProven': false,
    };
    binding.reportData = result;
    debugPrint('CLEANUP_HTTPS_RESULT ${jsonEncode(result)}');
  });
}

int _nowMillis() => DateTime.now().millisecondsSinceEpoch;

ChildCleanupRunner _runner(_Input input, DeviceIdentityManager identity,
        AndroidIdentityStore store) =>
    ChildCleanupRunner(
        environment: ChildEnvironment(apiRoot: input.apiRoot),
        identity: identity,
        secureStore: store,
        ownersClosed: () => true,
        nowMillis: _nowMillis);

Future<void> _untrustedRequest(Uri endpoint) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request =
        await client.getUrl(endpoint).timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.maxRedirects = 0;
    await request.close().timeout(const Duration(seconds: 10));
  } finally {
    client.close(force: true);
  }
}

Future<int> _authenticatedStatus(Uri endpoint, String credential) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request =
        await client.getUrl(endpoint).timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.maxRedirects = 0;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $credential');
    final response = await request.close().timeout(const Duration(seconds: 10));
    var size = 0;
    await for (final part in response.timeout(const Duration(seconds: 10))) {
      size += part.length;
      if (size > 65536) fail('NATIVE_CLEANUP_HTTPS_RESPONSE_TOO_LARGE');
    }
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<void> _originalKeyStillSigns(
    DeviceIdentityManager identity, Map<String, dynamic> oracle) async {
  final stored = await identity.secrets.read();
  expect(stored != null, isTrue);
  final state = _jsonObject(stored!);
  expect(state['keyHandle'] == oracle['nativeKeyHandle'], isTrue);
  final proof = await identity.cleanupProof(action: 'READ');
  expect(proof.keyThumbprint == oracle['thumbprint'], isTrue);
  expect(proof.compact.isNotEmpty, isTrue);
}

void _validateIdentityScope(DeviceIdentityView view, CleanupScope scope) {
  expect(
      view.tenantId == scope.tenantId &&
          view.deviceId == scope.deviceId &&
          view.registrationId == scope.registrationId,
      isTrue);
}

Future<void> _seedCaches(
    Directory directory, AndroidIdentityStore store) async {
  final configuration = await openConfigurationDatabase();
  try {
    await stringMapStoreFactory
        .store('https-cleanup')
        .record('marker')
        .put(configuration, {'value': _cacheMarker});
  } finally {
    await configuration.close();
  }
  await File('${directory.path}/configuration-v1.db')
      .copy('${directory.path}/~configuration-v1.db');
  final access = await openAccessDatabase(_accessScope);
  try {
    await stringMapStoreFactory
        .store('https-cleanup')
        .record('marker')
        .put(access, {'value': _cacheMarker});
  } finally {
    await access.close();
  }
  await File('${directory.path}/access-v1-$_accessScope.db')
      .copy('${directory.path}/~access-v1-$_accessScope.db');
  for (final key in [
    'observation_record',
    'access_context_v1_$_accessScope',
    'help_request_v1_$_accessScope'
  ]) {
    await store.storage.write(key: key, value: _cacheMarker);
  }
  await store.flushForCleanup();
  await store.flushAgentFiles(directory.path);
  await _seededCachesPresent(directory, store);
}

List<String> get _databaseFiles => [
      'configuration-v1.db',
      '~configuration-v1.db',
      'access-v1-$_accessScope.db',
      '~access-v1-$_accessScope.db'
    ];

Future<void> _databaseFilesAbsent(Directory directory) async {
  for (final name in _databaseFiles) {
    expect(await File('${directory.path}/$name').exists(), isFalse);
  }
}

Future<void> _seededCachesPresent(
    Directory directory, AndroidIdentityStore store) async {
  for (final name in _databaseFiles) {
    expect(await File('${directory.path}/$name').exists(), isTrue);
    expect(await File('${directory.path}/$name').length() > 0, isTrue);
  }
  for (final key in [
    'observation_record',
    'access_context_v1_$_accessScope',
    'help_request_v1_$_accessScope'
  ]) {
    expect(await store.storage.read(key: key) == _cacheMarker, isTrue);
  }
  expect(await store.storage.read(key: 'access_key_v1_$_accessScope') != null,
      isTrue);
}

Future<void> _cleanupComplete(
    Directory directory,
    AndroidIdentityStore store,
    AndroidDeviceKeys keys,
    Map<String, dynamic> oracle,
    _Input input,
    CleanupScope scope) async {
  expect(await store.read() == null, isTrue);
  await _databaseFilesAbsent(directory);
  await expectLater(
      keys.cleanupProof(oracle['nativeKeyHandle'] as String, scope.tenantId,
          scope.deviceId, scope.registrationId, 'READ', null, _nowMillis()),
      throwsA(isA<DeviceIdentityFailure>()));
  final journalStore = AndroidCleanupRecordStore(scope);
  final rawJournal = await journalStore.read();
  expect(rawJournal != null, isTrue,
      reason: 'Final acknowledgement must remain after original key removal');
  final journal = _jsonObject(rawJournal!);
  expect(journal['operationId'] == input.operationId, isTrue);
  expect(
      await CleanupReceiptJournal.finalKeyRemovalReady(
          scope: scope, commandHash: input.commandHash!, store: journalStore),
      isTrue);
  final records = await store.storage.readAll();
  expect(
      records.length == 1 &&
          records.containsKey(AndroidCleanupRecordStore.keyForScope(scope)),
      isTrue);
  expect(await File('${directory.path}/cleanup-https-handoff.json').exists(),
      isFalse);
  expect(
      await File('${directory.path}/unrelated-https-marker.txt')
              .readAsString() ==
          _unrelatedMarker,
      isTrue);
  await store.flushForCleanup();
}

Map<String, dynamic> _jsonObject(String raw) {
  try {
    final value = jsonDecode(raw);
    if (value is Map<String, dynamic>) return value;
  } catch (_) {
    // Fixture/identity/journal contents must never be copied into test logs.
  }
  throw const FormatException('NATIVE_CLEANUP_HTTPS_JSON_INVALID');
}

void _validateOracle(Map<String, dynamic> oracle, _Input input) {
  expect(
      oracle.length == 5 &&
          oracle.keys.toSet().containsAll(
              {'runId', 'phase', 'scope', 'nativeKeyHandle', 'thumbprint'}),
      isTrue);
  expect(oracle['runId'] == input.runId, isTrue);
  final expected = {
    'active': 'enroll',
    'cleanup': 'active',
    'verify': 'cleanup',
    'negative': 'cleanup'
  }[input.phase];
  expect(oracle['phase'] == expected, isTrue);
  expect(
      oracle['nativeKeyHandle'] is String &&
          _nativeAlias.hasMatch(oracle['nativeKeyHandle'] as String),
      isTrue);
  expect(validSecret(oracle['thumbprint']), isTrue);
  final scope = oracle['scope'];
  expect(scope is Map<String, dynamic>, isTrue);
  if (scope is! Map<String, dynamic>) {
    fail('NATIVE_CLEANUP_HTTPS_SCOPE_INVALID');
  }
  expect(
      scope.length == 4 &&
          scope['tenantId'] == input.tenantId &&
          scope['subjectId'] == input.subjectId &&
          validUuid(scope['deviceId']) &&
          validUuid(scope['registrationId']),
      isTrue);
  if (input.deviceId != null) {
    expect(
        scope['deviceId'] == input.deviceId &&
            scope['registrationId'] == input.registrationId,
        isTrue);
  }
}

class _Input {
  final String phase, runId, tenantId, subjectId, certificate;
  final Uri apiRoot;
  final Map<String, dynamic>? ticket;
  final String? deviceId, registrationId, operationId, commandHash;
  _Input(Map<String, dynamic> value)
      : phase = value['phase'] as String,
        runId = value['runId'] as String,
        tenantId = value['tenantId'] as String,
        subjectId = value['subjectId'] as String,
        certificate = value['serverCertificateDerBase64'] as String,
        apiRoot = Uri.parse(value['apiRoot'] as String),
        ticket = value['ticket'] as Map<String, dynamic>?,
        deviceId = value['deviceId'] as String?,
        registrationId = value['registrationId'] as String?,
        operationId = value['operationId'] as String?,
        commandHash = value['commandHash'] as String?;
}

Future<_Input> _consumeInput(Directory directory) async {
  final file = File('${directory.path}/cleanup-https-input.json');
  expect(await file.exists(), isTrue,
      reason: 'NATIVE_CLEANUP_HTTPS_INPUT_REQUIRED');
  late List<int> bytes;
  try {
    if (await file.length() > 32768) {
      fail('NATIVE_CLEANUP_HTTPS_INPUT_TOO_LARGE');
    }
    bytes = await file.readAsBytes();
  } finally {
    // Enrollment tickets exist only in the consumed, app-private host fixture.
    await file.delete();
  }
  final value = _jsonObject(utf8.decode(bytes));
  final common = {
    'schemaVersion',
    'phase',
    'runId',
    'tenantId',
    'subjectId',
    'apiRoot',
    'serverCertificateDerBase64'
  };
  final phase = value['phase'];
  expect(
      const {'negative', 'enroll', 'active', 'cleanup', 'verify'}
          .contains(phase),
      isTrue);
  final expectedKeys = {
    ...common,
    if (phase == 'enroll') 'ticket',
    if (const {'active', 'cleanup', 'verify'}.contains(phase)) ...{
      'deviceId',
      'registrationId'
    },
    if (const {'cleanup', 'verify'}.contains(phase)) ...{
      'operationId',
      'commandHash'
    }
  };
  expect(
      value.length == expectedKeys.length &&
          value.keys.toSet().containsAll(expectedKeys),
      isTrue);
  expect(
      value['schemaVersion'] == 1 &&
          value['runId'] is String &&
          (value['runId'] as String).isNotEmpty &&
          (value['runId'] as String).length <= 128 &&
          validUuid(value['tenantId']) &&
          validUuid(value['subjectId']) &&
          value['apiRoot'] is String &&
          value['serverCertificateDerBase64'] is String,
      isTrue);
  if (phase == 'enroll') {
    expect(value['ticket'] is Map<String, dynamic>, isTrue);
  }
  if (const {'active', 'cleanup', 'verify'}.contains(phase)) {
    expect(validUuid(value['deviceId']) && validUuid(value['registrationId']),
        isTrue);
  }
  if (const {'cleanup', 'verify'}.contains(phase)) {
    expect(
        validUuid(value['operationId']) &&
            value['commandHash'] is String &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(value['commandHash'] as String),
        isTrue);
  }
  final input = _Input(value);
  expect(
      input.apiRoot.scheme == 'https' &&
          input.apiRoot.host == '127.0.0.1' &&
          input.apiRoot.hasPort &&
          input.apiRoot.port > 0 &&
          input.apiRoot.path == '/api/v1' &&
          input.apiRoot.userInfo.isEmpty &&
          !input.apiRoot.hasQuery &&
          !input.apiRoot.hasFragment,
      isTrue);
  try {
    final certificate = base64Decode(input.certificate);
    expect(certificate.isNotEmpty && certificate.length <= 16384, isTrue);
  } on FormatException {
    fail('NATIVE_CLEANUP_HTTPS_CERTIFICATE_INVALID');
  }
  return input;
}
