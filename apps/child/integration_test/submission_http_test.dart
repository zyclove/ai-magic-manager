import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:child/core/environment.dart';
import 'package:child/core/session.dart';
import 'package:child/core/submission_receiver.dart';
import 'package:child/platform/secret_store.dart';
import 'package:child/ui/child_app.dart';
import 'package:device_access/device_access.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';

/// Private, per-run Android encrypted identity namespace. The identity manager,
/// ES256 enrollment, HTTP authentication and native persistence are production
/// implementations; no global identity record or real account is overwritten.
class _ScopedSecrets implements DeviceSecretStore {
  final AndroidAccessBindingStore store;
  final String key;
  _ScopedSecrets(this.store, this.key);
  @override
  Future<String?> read() => store.read(key);
  @override
  Future<void> write(String value) => store.write(key, value);
}

/// All requests reach the real Spring server. Only after draining a committed
/// 201/200 do we hold completion, allowing the host to kill the Android process.
class _InterruptAfterCommit extends http.BaseClient {
  final http.Client delegate = http.Client();
  final String phase;
  final Future<void> Function(String, http.BaseRequest) checkpoint;
  final statuses = <String>[];
  int posts = 0;
  _InterruptAfterCommit(this.phase, this.checkpoint);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'POST') posts++;
    final response = await delegate.send(request);
    final suffix = request.url.path.split('/').last;
    statuses.add('${request.method}:$suffix:${response.statusCode}');
    if ((phase == 'submit' &&
            suffix == 'access-submissions' &&
            response.statusCode == 201) ||
        (phase == 'cancel' &&
            suffix == 'cancel' &&
            response.statusCode == 200)) {
      await response.stream.drain<void>();
      await checkpoint(suffix, request);
      debugPrint('ANDROID_HTTP_CRASH_POINT ${jsonEncode({
            'phase': phase,
            'pid': pid,
            'committedStatus': response.statusCode,
            'realResponseDrained': true,
          })}');
      return Completer<http.StreamedResponse>().future;
    }
    return response;
  }

  @override
  void close() => delegate.close();
}

String _digest(Uint8List bytes) => base64Encode(SHA256Digest().process(bytes));
Future<String?> _fileDigest(File file) async =>
    await file.exists() ? _digest(await file.readAsBytes()) : null;
final _owners = <Object>[];

/// Dedicated debug AVD only. No secret is a dart-define or public driver report.
/// The host writes one private input file; the app consumes and deletes it.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android registers and recovers real Spring submissions',
      (tester) async {
    const phase = String.fromEnvironment('ANDROID_HTTP_PHASE');
    const leaf = String.fromEnvironment('ANDROID_HTTP_INPUT');
    expect({
      'enroll',
      'submit',
      'recover',
      'cancel',
      'cancel-recover',
      'expired',
      'offline',
      'revoked',
      'blocked',
      'cleanup'
    }, contains(phase));
    expect(RegExp(r'^android-http-[0-9a-f]{32}\.json$').hasMatch(leaf), isTrue);
    final directory = await getApplicationSupportDirectory();
    final input = File(path.join(directory.path, leaf));
    final fixture =
        jsonDecode(await input.readAsString()) as Map<String, dynamic>;
    await input.delete();
    expect(fixture['schemaVersion'], 1);
    final apiRoot = Uri.parse(fixture['apiRoot'] as String);
    expect(apiRoot.scheme, 'http');
    expect(apiRoot.host, '127.0.0.1');
    final environment =
        ChildEnvironment(apiRoot: apiRoot, allowLoopbackHttp: true);
    final native = AndroidIdentityStore();
    final bindings = AndroidAccessBindingStore();
    final originalIdentity = await native.read();
    final observations = AndroidObservationStore();
    final originalObservation = await observations.read();
    final configuration =
        File(path.join(directory.path, 'configuration-v1.db'));
    final originalConfiguration = await _fileDigest(configuration);
    final runId = fixture['runId'] as String,
        tenant = fixture['tenantId'] as String;
    String storageKey(String purpose) => policy.DevicePolicyScope(
            issuer: '$purpose|$apiRoot|$runId',
            tenantId: tenant,
            deviceId: runId,
            registrationId: runId)
        .storageKey;
    final identityKey = storageKey('android-http-identity-v1');
    final oracleKey = storageKey('android-http-oracle-v1');
    final secrets = _ScopedSecrets(bindings, identityKey);
    final savedOracle = await bindings.read(oracleKey);
    final oracle = savedOracle == null
        ? <String, dynamic>{'runId': runId}
        : Map<String, dynamic>.from(jsonDecode(savedOracle) as Map);
    expect(oracle['runId'], runId);
    if (phase == 'enroll') {
      expect(savedOracle, isNull);
      expect(await secrets.read() == null, isTrue,
          reason: 'Refuse to overwrite a prior native HTTP identity.');
    } else if (phase != 'cleanup') {
      expect(savedOracle, isNotNull,
          reason: 'Requires prior native HTTP state.');
      expect(await secrets.read() != null, isTrue);
    }
    Future<void> save() => bindings.write(oracleKey, jsonEncode(oracle));
    if (phase == 'enroll') await save();
    final handoff = File(path.join(directory.path, '$leaf.handoff'));
    final identityApi =
        DeviceIdentityApi(apiRoot: apiRoot, allowLoopbackHttp: true);
    final identity = DeviceIdentityManager(
        api: identityApi,
        secrets: secrets,
        nowMillis: () => DateTime.now().millisecondsSinceEpoch);
    final client = _InterruptAfterCommit(phase, (suffix, request) async {
      final body = request is http.Request ? request.body : '';
      if (suffix == 'access-submissions') {
        oracle['createKey'] = request.headers['idempotency-key'];
        oracle['createBody'] = body;
      } else {
        expect(request.headers['if-match'], '"0"');
        oracle['cancelKey'] = request.headers['idempotency-key'];
        oracle['cancelRequestId'] =
            request.url.pathSegments[request.url.pathSegments.length - 2];
      }
      await save();
    });
    ChildSubmissionReceiver? receiver;
    final session = ChildSession(
        identity: identity,
        submissionFactory: (view) async => receiver = ChildSubmissionReceiver(
            environment: environment,
            identity: view,
            credential: identity.activeCredential,
            nowMillis: () => DateTime.now().millisecondsSinceEpoch,
            transportFactory: () => DeviceAccessTransport(
                apiRoot: apiRoot,
                credential: identity.activeCredential,
                allowLoopbackHttp: true,
                client: client)));
    Future<void> idle() async {
      final deadline = DateTime.now().add(const Duration(seconds: 35));
      while (!session.initialized || session.busy) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Android HTTP session deadline');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    Future<void> tap(String label, {bool first = false}) async {
      final finder = first ? find.text(label).first : find.text(label).last;
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await idle();
    }

    Future<void> create(String app, String reason) async {
      await tap('申请临时访问');
      await tap(app);
      await tester.enterText(
          find.byKey(const Key('submission-reason')), reason);
      await tester.enterText(find.byKey(const Key('submission-minutes')), '1');
      await tap('核对申请');
      expect(find.text('确认申请内容'), findsOneWidget);
      await tap('提交给监护人');
    }

    Future<void> unchanged() async {
      expect(await native.read() == originalIdentity, isTrue);
      expect(await observations.read() == originalObservation, isTrue);
      expect(await _fileDigest(configuration), originalConfiguration);
    }

    if (phase == 'cleanup') {
      expect(savedOracle != null, isTrue,
          reason:
              'Cleanup requires the exact run marker, never a broad reset.');
      DeviceIdentityView? view;
      if (await secrets.read() != null) view = await identity.view();
      final keys = <String>[
        'access_context_v1_$identityKey',
        'access_context_v1_$oracleKey'
      ];
      File? file;
      if (view != null) expect(view.tenantId, tenant);
      if (view?.deviceId != null && view?.registrationId != null) {
        if (fixture['deviceId'] != null) {
          expect(view!.deviceId, fixture['deviceId']);
        }
        if (fixture['registrationId'] != null) {
          expect(view!.registrationId, fixture['registrationId']);
        }
        final scope = DeviceAccessScope(
            issuer: 'child-submissions-v1|$apiRoot',
            tenantId: tenant,
            subjectId: fixture['subjectId'],
            deviceId: view!.deviceId!,
            registrationId: view.registrationId!);
        final contextKey = policy.DevicePolicyScope(
                issuer: scope.issuer,
                tenantId: tenant,
                deviceId: view.deviceId!,
                registrationId: view.registrationId!)
            .storageKey;
        file =
            File(path.join(directory.path, 'access-v1-${scope.storageKey}.db'));
        expect(await file.parent.resolveSymbolicLinks(),
            await directory.resolveSymbolicLinks());
        expect(path.basename(file.path), 'access-v1-${scope.storageKey}.db');
        if (fixture['requestId'] != null) expect(await file.exists(), isTrue);
        if (await file.exists()) await file.delete();
        keys.addAll([
          'access_key_v1_${scope.storageKey}',
          'access_context_v1_$contextKey'
        ]);
      }
      for (final key in keys) {
        await native.storage.delete(key: key);
      }
      await native.read();
      for (final key in keys) {
        expect(await native.storage.read(key: key) == null, isTrue);
      }
      if (file != null) expect(await file.exists(), isFalse);
      await unchanged();
      binding.reportData = {
        'phase': phase,
        'pid': pid,
        'fixtureRemoved': true,
        'globalRecordsUnchanged': true,
        'systemEnforced': false
      };
      session.dispose();
      identityApi.close();
      client.close();
      return;
    }

    await tester.pumpWidget(ChildApp(
        session: session,
        nativeAvailable: true,
        serviceLabel: apiRoot.toString(),
        osVersion: 'Android API34 acceptance'));
    await idle();
    if (phase == 'enroll') {
      expect(find.text('连接我的设备'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(0), '原生联调设备');
      await tester.enterText(
          find.byType(TextFormField).at(1), jsonEncode(fixture['ticket']));
      await tap('安全连接');
      expect(session.identityView != null, isTrue,
          reason: 'A valid guardian ticket must reach the real claim API.');
      expect(session.identityView!.phase, IdentityPhase.awaitingConfirmation);
      expect(session.credentialReady, isFalse);
      expect(
          RegExp(r'^[A-Z0-9]{8}$').hasMatch(session.pairingCode ?? ''), isTrue);
      final view = session.identityView!;
      oracle['deviceId'] = view.deviceId;
      oracle['registrationId'] = view.registrationId;
      await save();
      await handoff.writeAsString(
          jsonEncode({
            'deviceId': view.deviceId,
            'registrationId': view.registrationId,
            'pairingCode': session.pairingCode
          }),
          flush: true);
    } else {
      expect(session.identityView!.deviceId, fixture['deviceId']);
      expect(session.identityView!.registrationId, fixture['registrationId']);
      if (phase == 'submit') {
        expect(session.identityView!.phase, IdentityPhase.awaitingConfirmation);
        await tap('检查确认状态');
        expect(session.identityView!.phase, IdentityPhase.active);
        expect(session.identityView!.heartbeatSequence, 1);
      }
      if (phase == 'revoked') {
        expect(session.submissions.journal, isNull,
            reason:
                'Real revoked device must not expose cached business data.');
        // A separate real identity heartbeat makes the local authentication
        // block durable, hiding all child-side private scopes on future opens.
        await session.checkConnection();
        await idle();
        expect(session.identityView!.cloudAuthenticationBlocked, isTrue);
        expect(session.credentialReady, isFalse);
        expect(session.submissions.journal, isNull);
      } else if (phase == 'blocked') {
        expect(session.identityView!.cloudAuthenticationBlocked, isTrue);
        expect(session.credentialReady, isFalse);
        expect(session.submissions.journal, isNull);
        expect(client.posts, 0);
      } else {
        await tap('规则');
        expect(find.text('临时访问申请'), findsOneWidget);
        if (phase == 'submit') {
          expect(session.submissions.onlineConfirmed, isTrue);
          await create('原生阅读', 'Android真实服务阅读申请');
        } else if (phase == 'cancel') {
          expect(session.submissions.journal!.pending, isNull);
          await create('原生练习', 'Android真实服务练习申请');
          expect(session.submissions.journal!.pending, isNull);
          await tap('查看申请', first: true);
          await tap('取消申请');
          expect(find.text('确认取消这份申请？'), findsOneWidget);
          await tap('确认取消');
        } else if (phase == 'recover' || phase == 'cancel-recover') {
          final pending = session.submissions.journal!.pending!;
          expect(pending.phase, SubmissionOperationPhase.unknown);
          expect(client.posts, 0,
              reason: 'Initialization cannot retry mutations.');
          if (phase == 'recover') {
            expect(pending.key == oracle['createKey'], isTrue);
            expect(jsonEncode(pending.input!.toJson()) == oracle['createBody'],
                isTrue);
          } else {
            expect(pending.key == oracle['cancelKey'], isTrue);
            expect(pending.requestId, oracle['cancelRequestId']);
            expect(pending.version, 0);
          }
          await tap('按原操作重试');
          expect(find.text('确认原操作'), findsOneWidget);
          await tap('确认重试');
          expect(session.submissions.journal!.pending, isNull);
          expect(client.posts, 2);
          expect(
              client.statuses,
              containsAll(phase == 'recover'
                  ? ['POST:access-submissions:409', 'POST:recovery:200']
                  : ['POST:cancel:409', 'POST:cancel-recovery:200']));
        } else if (phase == 'offline') {
          expect(session.submissions.onlineConfirmed, isFalse);
          expect(session.submissions.journal!.pending, isNull);
          expect(client.posts, 0);
        }
        if (phase != 'submit' && phase != 'cancel') {
          final entries = session.submissions.journal!.entries;
          final approved = entries
              .singleWhere((e) => e.value.id == fixture['requestId'])
              .value;
          expect(
              approved.state, isIn(['APPROVED_PENDING_DELIVERY', 'EXPIRED']));
          expect(approved.absoluteNotAfter, fixture['absoluteNotAfter']);
          if (phase == 'offline') {
            expect(approved.state, oracle['approvedState']);
          } else {
            if (phase == 'expired') expect(approved.state, 'EXPIRED');
            if (approved.state == 'EXPIRED') {
              expect(
                  approved.absoluteNotAfter!,
                  lessThanOrEqualTo(
                      DateTime.now().millisecondsSinceEpoch + 1000));
            }
            oracle['approvedState'] = approved.state;
            await save();
          }
          if (phase == 'cancel-recover' ||
              phase == 'expired' ||
              phase == 'offline') {
            final cancelled = entries
                .singleWhere((e) => e.value.id == oracle['cancelRequestId'])
                .value;
            expect(cancelled.state, 'CANCELLED');
            expect(cancelled.version, 1);
          }
        }
      }
    }
    expect(session.systemEnforced, isFalse);
    expect(tester.takeException(), isNull);
    final prefs = await File(path.join(
            directory.parent.path, 'shared_prefs', 'aimanager_identity_v1.xml'))
        .readAsString();
    final rawIdentity = jsonDecode((await secrets.read())!) as Map;
    final markers = [
      'Android真实服务阅读申请',
      'Android真实服务练习申请',
      if (rawIdentity['credential'] is String)
        rawIdentity['credential'] as String,
      if (oracle['createKey'] is String) oracle['createKey'] as String,
      if (oracle['cancelKey'] is String) oracle['cancelKey'] as String
    ];
    for (final marker in markers) {
      expect(prefs.contains(marker), isFalse);
    }
    await unchanged();
    binding.reportData = {
      'phase': phase,
      'pid': pid,
      'realHttp': true,
      'mutationPosts': client.posts,
      'statuses': client.statuses,
      'cachedFirstState': oracle['approvedState'],
      'globalRecordsUnchanged': true,
      'nativePreferencesPlaintextAbsent': true,
      'systemEnforced': false
    };
    // No graceful close: the host proves PID death with the journal still owned.
    _owners.addAll([session, identityApi, client]);
    if (receiver != null) _owners.add(receiver!);
  });
}
