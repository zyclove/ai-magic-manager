import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:child/core/environment.dart';
import 'package:child/core/session.dart';
import 'package:child/core/submission_receiver.dart';
import 'package:child/platform/access_database_io.dart';
import 'package:child/platform/secret_store.dart';
import 'package:child/ui/design.dart';
import 'package:child/ui/submission_section.dart';
import 'package:device_access/device_access.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_policy/device_policy.dart' as policy;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/digests/sha256.dart';
import '../test/support/identity_fixture.dart';
import '../test/support/submission_fixture.dart';

const _origin = 'https://submission-storage-fixture.invalid/api/v1';
const _issuer = 'child-submissions-v1|$_origin';
const _now = IdentityFixture.now, _deadline = _now + 301000;
const _secondApp = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _secondRequest = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _reason = '原生阅读申请', _secondReason = '原生练习申请';
const _scope = DeviceAccessScope(
    issuer: _issuer,
    tenantId: IdentityFixture.tenant,
    subjectId: SubmissionFixture.subject,
    deviceId: IdentityFixture.device,
    registrationId: IdentityFixture.registration);
String _binding(String purpose) => policy.DevicePolicyScope(
        issuer: purpose,
        tenantId: IdentityFixture.tenant,
        deviceId: IdentityFixture.device,
        registrationId: IdentityFixture.registration)
    .storageKey;
final _bindingKey = _binding(_issuer);
final _oracleKey = _binding('$_issuer|native-oracle-v1');
final _identityKey = _binding('$_issuer|native-identity-v1');
const _phases = [
  'write_unknown',
  'restore_offline',
  'recover_original',
  'write_cancel_unknown',
  'recover_cancel',
  'reopen_final_offline',
  'reject_credentials',
  'verify_blocked',
  'remove_key',
  'verify_missing_key_cleanup',
  'cleanup'
];
// Keep completed-phase owners alive until the host kills the Android process.
// Explicit key-loss/cleanup phases close their files before probing/removing them.
final _retainedOwners = <Object>[];

Future<String?> _digest(File file) async => await file.exists()
    ? base64Encode(SHA256Digest().process(await file.readAsBytes()))
    : null;

/// A separate native encrypted test namespace; never overwrites the application's
/// identity record. Registration and heartbeat remain explicit cloud substitutes.
class _ScopedIdentity implements DeviceSecretStore {
  final AndroidAccessBindingStore bindings;
  _ScopedIdentity(this.bindings);
  @override
  Future<String?> read() => bindings.read(_identityKey);
  @override
  Future<void> write(String value) => bindings.write(_identityKey, value);
}

/// No sockets or real accounts. The production transport, receiver and journal
/// execute unchanged against these explicitly controlled service responses.
class _Cloud {
  final String phase;
  final Map<String, dynamic> oracle;
  final Future<void> Function() save;
  int calls = 0, posts = 0;
  bool comparedCreate = false, comparedCancel = false;
  _Cloud(this.phase, this.oracle, this.save);
  bool get offline => {
        'restore_offline',
        'reopen_final_offline',
        'verify_blocked',
        'remove_key',
        'verify_missing_key_cleanup'
      }.contains(phase);
  Map<String, dynamic> first() => SubmissionFixture.fact({
        'reason': _reason,
        'state': 'APPROVED_PENDING_DELIVERY',
        'grantedWindowSeconds': 300,
        'issuedAt': _now + 1000,
        'absoluteNotAfter': _deadline,
        'version': 1
      }).toJson();
  Map<String, dynamic> second() => SubmissionFixture.fact({
        'id': _secondRequest,
        'applicationId': _secondApp,
        'ruleIds': ['practice'],
        'reason': _secondReason,
        'createdAt': _now + 3000,
        'requestExpiresAt': _now + 1803000,
        'state': oracle['remoteCancelled'] == true ? 'CANCELLED' : 'PENDING',
        'version': oracle['remoteCancelled'] == true ? 1 : 0
      }).toJson();
  late final client = MockClient((request) async {
    calls++;
    expect(request.headers['authorization'] == 'Bearer ${'b' * 43}', isTrue);
    if (offline) {
      throw const SocketException('Controlled native fixture offline');
    }
    Object body;
    var status = 200;
    final route = request.url.path;
    if (route.endsWith('/access-context')) {
      if (phase == 'reject_credentials') {
        status = 401;
        body = {'errorCode': 'DEVICE_UNAUTHENTICATED'};
      } else {
        body = {
          'tenantId': IdentityFixture.tenant,
          'subjectId': SubmissionFixture.subject,
          'deviceId': IdentityFixture.device,
          'registrationId': IdentityFixture.registration
        };
      }
    } else if (route.endsWith('/options')) {
      body = {
        'items': [
          {
            'id': SubmissionFixture.policy,
            'name': '原生验收安排',
            'baseVersionId': SubmissionFixture.version,
            'commonRules': [],
            'applications': [
              {
                'id': SubmissionFixture.application,
                'displayName': '原生阅读空间',
                'rules': [
                  {'id': 'reading', 'kind': 'APP_LAUNCH'}
                ]
              },
              {
                'id': _secondApp,
                'displayName': '原生练习空间',
                'rules': [
                  {'id': 'practice', 'kind': 'APP_LAUNCH'}
                ]
              }
            ]
          }
        ],
        'nextCursor': null
      };
    } else if (request.method == 'POST') {
      posts++;
      if (route.endsWith('/cancel-recovery')) {
        comparedCancel =
            request.headers['idempotency-key'] == oracle['cancelKey'] &&
                request.headers['if-match'] == '"0"' &&
                route.contains(_secondRequest);
        expect(comparedCancel, isTrue);
        body = second();
      } else if (route.endsWith('/recovery')) {
        comparedCreate =
            request.headers['idempotency-key'] == oracle['createKey'] &&
                request.body == oracle['createBody'];
        expect(comparedCreate, isTrue);
        body = first();
      } else if (route.endsWith('/cancel')) {
        expect(route.contains(_secondRequest), isTrue);
        expect(request.headers['if-match'], '"0"');
        if (phase == 'write_cancel_unknown') {
          oracle['cancelKey'] = request.headers['idempotency-key'];
          oracle['remoteCancelled'] = true;
          await save();
          debugPrint('SUBMISSION_STORAGE_CRASH_POINT ${jsonEncode({
                'phase': phase,
                'pid': pid,
                'kind': 'CANCEL',
                'requestCallbackReachedAfterJournalWrite': true
              })}');
          return Completer<http.Response>().future;
        }
        expect(phase, 'recover_cancel');
        expect(
            request.headers['idempotency-key'] == oracle['cancelKey'], isTrue);
        status = 409;
        body = {'errorCode': 'IDEMPOTENCY_KEY_EXPIRED'};
      } else if (route.endsWith('/access-submissions')) {
        if (phase == 'write_unknown') {
          oracle['createKey'] = request.headers['idempotency-key'];
          oracle['createBody'] = request.body;
          oracle['createCreatedAt'] = _now;
          await save();
          debugPrint('SUBMISSION_STORAGE_CRASH_POINT ${jsonEncode({
                'phase': phase,
                'pid': pid,
                'kind': 'CREATE',
                'requestCallbackReachedAfterJournalWrite': true
              })}');
          return Completer<http.Response>().future;
        }
        if (phase == 'write_cancel_unknown') {
          expect(
              (jsonDecode(request.body) as Map)['applicationId'], _secondApp);
          oracle['secondCreated'] = true;
          await save();
          status = 201;
          body = second();
        } else {
          expect(phase, 'recover_original');
          expect(request.headers['idempotency-key'] == oracle['createKey'],
              isTrue);
          expect(request.body == oracle['createBody'], isTrue);
          status = 409;
          body = {'errorCode': 'IDEMPOTENCY_KEY_EXPIRED'};
        }
      } else {
        throw StateError('Unsupported native fixture mutation');
      }
    } else if (route.endsWith('/$_secondRequest')) {
      body = second();
    } else if (route.endsWith('/access-submissions')) {
      body = {
        'items': [
          if (phase != 'write_unknown') first(),
          if (oracle['secondCreated'] == true) second()
        ],
        'nextCursor': null
      };
    } else {
      throw StateError('Unsupported native fixture query');
    }
    return http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});
  });
}

/// Dedicated debug emulator only; host proves PID death and stable installation
/// between phases. Android SDK storage/Keystore/durability and encrypted Sembast
/// are real. These fixtures do not establish real service or OS enforcement.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native submission intents survive independent process launches',
      (tester) async {
    const phase = String.fromEnvironment('SUBMISSION_STORE_PHASE');
    expect(_phases.contains(phase), isTrue);
    final native = AndroidIdentityStore();
    final observations = AndroidObservationStore();
    final bindings = AndroidAccessBindingStore();
    final identityBefore = await native.read();
    final observationBefore = await observations.read();
    final directory = await getApplicationSupportDirectory();
    final configuration =
        File(path.join(directory.path, 'configuration-v1.db'));
    final configurationBefore = await _digest(configuration);
    final database =
        File(path.join(directory.path, 'access-v1-${_scope.storageKey}.db'));
    final others = <String, String?>{};
    await for (final file in directory.list()) {
      if (file is File &&
          path.basename(file.path).startsWith('access-v1-') &&
          file.path != database.path) others[file.path] = await _digest(file);
    }
    final serialized = await bindings.read(_oracleKey);
    late final Map<String, dynamic> oracle;
    if (phase == 'write_unknown') {
      expect(
          serialized == null &&
              await bindings.read(_bindingKey) == null &&
              await bindings.read(_identityKey) == null &&
              !await database.exists(),
          isTrue,
          reason: 'Refuse to overwrite any existing native request fixture.');
      oracle = {'fixture': 'native-child-submissions-v1', 'schemaVersion': 1};
      await bindings.write(_oracleKey, jsonEncode(oracle));
    } else {
      expect(serialized != null, isTrue,
          reason: 'Requires durable state from the preceding native process.');
      oracle = Map<String, dynamic>.from(jsonDecode(serialized!) as Map);
      expect(
          oracle['fixture'] == 'native-child-submissions-v1' &&
              oracle['schemaVersion'] == 1,
          isTrue);
      expect(await database.exists(), isTrue);
    }
    Future<void> save() => bindings.write(_oracleKey, jsonEncode(oracle));
    final cloud = _Cloud(phase, oracle, save);
    final identity = IdentityFixture(nativeSecrets: _ScopedIdentity(bindings));
    identity.clock = _now + _phases.indexOf(phase) * 1000;
    ChildSubmissionReceiver? receiver;
    final session = ChildSession(
        identity: identity.identity,
        nowMillis: () => identity.clock,
        submissionFactory: (view) async => receiver = ChildSubmissionReceiver(
            environment: ChildEnvironment(apiRoot: Uri.parse(_origin)),
            identity: view,
            credential: identity.identity.activeCredential,
            nowMillis: () => identity.clock,
            transportFactory: () => DeviceAccessTransport(
                apiRoot: Uri.parse(_origin),
                credential: identity.identity.activeCredential,
                client: cloud.client)));
    Future<void> idle() async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (session.busy) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Native session deadline exceeded');
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

    Future<void> create(String application, String reason) async {
      await tap('申请临时访问');
      await tap(application);
      await tester.enterText(
          find.byKey(const Key('submission-reason')), reason);
      await tap('核对申请');
      expect(find.text('确认申请内容'), findsOneWidget);
      await tap('提交给监护人');
      expect(find.byType(Dialog), findsNothing);
    }

    var missingKeyVerified = false;
    var sessionDisposed = false;
    const retainForProcessDeath = phase != 'remove_key' &&
        phase != 'verify_missing_key_cleanup' &&
        phase != 'cleanup';
    try {
      if (phase == 'write_unknown') {
        await identity.activate();
      } else {
        identity.confirmed = true;
      }
      if (phase != 'cleanup') {
        await session.initialize();
        await idle();
        expect(session.credentialReady, isTrue);
      }
      await tester.pumpWidget(MaterialApp(
          theme: childTheme(),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: SubmissionSection(
                          session: session, available: true))))));
      await tester.pumpAndSettle();
      expect(session.systemEnforced, isFalse);
      if (phase == 'write_unknown') {
        await create('原生阅读空间', _reason);
        final pending = session.submissions.journal!.pending!;
        expect(pending.phase, SubmissionOperationPhase.unknown);
        expect(pending.key == oracle['createKey'], isTrue);
        expect(jsonEncode(pending.input!.toJson()) == oracle['createBody'],
            isTrue);
        oracle['createCreatedAt'] = pending.createdAt;
        await save();
        expect(cloud.posts, 1);
      } else if (phase == 'restore_offline') {
        final pending = session.submissions.journal!.pending!;
        expect(pending.key == oracle['createKey'], isTrue);
        expect(pending.createdAt, oracle['createCreatedAt']);
        expect(jsonEncode(pending.input!.toJson()) == oracle['createBody'],
            isTrue);
        expect(session.submissions.onlineConfirmed, isFalse);
        expect(find.text('结果待确认'), findsOneWidget);
        expect(find.text('放弃本次操作'), findsNothing);
        expect(await session.discardSubmission(), isFalse);
        expect(session.submissions.journal!.pending!.key == oracle['createKey'],
            isTrue);
        expect(cloud.posts, 0);
      } else if (phase == 'recover_original' || phase == 'recover_cancel') {
        final pending = session.submissions.journal!.pending!;
        expect(pending.phase, SubmissionOperationPhase.unknown);
        if (phase == 'recover_cancel') {
          expect(pending.kind, 'CANCEL');
          expect(pending.key == oracle['cancelKey'], isTrue);
          expect(pending.requestId, _secondRequest);
          expect(pending.version, 0);
        } else {
          expect(pending.key == oracle['createKey'], isTrue);
        }
        expect(cloud.posts, 0,
            reason: 'Opening the app cannot retry mutations.');
        await tap('按原操作重试');
        expect(find.text('确认原操作'), findsOneWidget);
        await tap('确认重试');
        expect(find.byType(Dialog), findsNothing);
        expect(session.submissions.journal!.pending, isNull);
        expect(cloud.posts, 2);
        expect(
            phase == 'recover_original'
                ? cloud.comparedCreate
                : cloud.comparedCancel,
            isTrue);
      } else if (phase == 'write_cancel_unknown') {
        expect(session.submissions.journal!.pending, isNull);
        await create('原生练习空间', _secondReason);
        expect(session.submissions.journal!.entries.first.value.id,
            _secondRequest);
        await tap('查看申请', first: true);
        await tap('取消申请');
        expect(find.text('确认取消这份申请？'), findsOneWidget);
        expect(cloud.posts, 1);
        await tap('确认取消');
        final pending = session.submissions.journal!.pending!;
        expect(pending.phase, SubmissionOperationPhase.unknown);
        expect(pending.kind, 'CANCEL');
        expect(pending.key == oracle['cancelKey'], isTrue);
        expect(pending.version, 0);
        expect(find.text('放弃本次操作'), findsNothing);
        expect(cloud.posts, 2);
      } else if (phase == 'reopen_final_offline') {
        expect(session.submissions.onlineConfirmed, isFalse);
        expect(session.submissions.journal!.pending, isNull);
        expect(session.submissions.journal!.entries.length, 2);
        final cancelled = session.submissions.journal!.entries
            .singleWhere((e) => e.value.id == _secondRequest)
            .value;
        expect(cancelled.state, 'CANCELLED');
        expect(cancelled.version, 1);
        expect(find.text('已取消'), findsOneWidget);
        expect(cloud.posts, 0);
      } else if (phase == 'reject_credentials' || phase == 'verify_blocked') {
        expect(session.submissions.journal, isNull);
        expect(find.text('原生阅读空间'), findsNothing);
        expect(find.text('原生练习空间'), findsNothing);
        final row = jsonDecode((await bindings.read(_bindingKey))!) as Map;
        expect(row['phase'], 'BLOCKED');
        expect(cloud.posts, 0);
      }
      final saved = session.submissions.journal?.entries ??
          const <SubmissionCacheEntry>[];
      if (saved.isNotEmpty &&
          phase != 'write_unknown' &&
          phase != 'restore_offline') {
        final approved = saved
            .singleWhere((e) => e.value.id == SubmissionFixture.request)
            .value;
        expect(approved.absoluteNotAfter, _deadline);
        expect(approved.state, 'APPROVED_PENDING_DELIVERY');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      if (!retainForProcessDeath) {
        session.dispose();
        sessionDisposed = true;
        await receiver?.close();
        receiver = null;
      }
      if (phase == 'remove_key') {
        oracle['databaseBeforeMissingKey'] = await _digest(database);
        await save();
        expect(
            await native.storage
                    .read(key: 'access_key_v1_${_scope.storageKey}') !=
                null,
            isTrue);
        await native.storage.delete(key: 'access_key_v1_${_scope.storageKey}');
        await native
            .read(); // Native commit barrier after the exact test-key delete.
      }
      if (phase == 'remove_key' || phase == 'verify_missing_key_cleanup') {
        await expectLater(
            openAccessDatabase(_scope.storageKey, requireExisting: true),
            throwsA(isA<AccessFailure>()
                .having((e) => e.code, 'code', 'ACCESS_KEY_UNAVAILABLE')));
        expect(
            await native.storage
                    .read(key: 'access_key_v1_${_scope.storageKey}') ==
                null,
            isTrue);
        expect(await _digest(database), oracle['databaseBeforeMissingKey']);
        missingKeyVerified = true;
      }
      const cleanup =
          phase == 'cleanup' || phase == 'verify_missing_key_cleanup';
      if (cleanup) {
        expect(
            path.basename(database.path), 'access-v1-${_scope.storageKey}.db');
        expect(await database.parent.resolveSymbolicLinks(),
            await directory.resolveSymbolicLinks());
        if (await database.exists()) await database.delete();
        for (final key in [
          'access_key_v1_${_scope.storageKey}',
          'access_context_v1_$_bindingKey',
          'access_context_v1_$_oracleKey',
          'access_context_v1_$_identityKey'
        ]) {
          await native.storage.delete(key: key);
        }
        await native.read();
        expect(
            await bindings.read(_bindingKey) == null &&
                await bindings.read(_oracleKey) == null &&
                await bindings.read(_identityKey) == null &&
                !await database.exists(),
            isTrue);
      } else {
        final raw = await database.readAsString();
        final prefs = await File(path.join(directory.parent.path,
                'shared_prefs', 'aimanager_identity_v1.xml'))
            .readAsString();
        final markers = [
          _reason,
          _secondReason,
          'b' * 43,
          oracle['createKey'] as String,
          if (oracle['cancelKey'] != null) oracle['cancelKey'] as String
        ];
        if (phase != 'remove_key') {
          markers.add(base64Encode(await AndroidAccessKeyStore()
              .keyFor(_scope.storageKey, existingDatabase: true)));
        }
        for (final marker in markers) {
          expect(!raw.contains(marker) && !prefs.contains(marker), isTrue,
              reason:
                  'Native payload, original keys and file key cannot appear in plaintext.');
        }
      }
      expect(await native.read() == identityBefore, isTrue);
      expect(await observations.read() == observationBefore, isTrue);
      expect(await _digest(configuration) == configurationBefore, isTrue);
      for (final entry in others.entries) {
        expect(await _digest(File(entry.key)), entry.value);
      }
      binding.reportData = {
        'phase': phase,
        'pid': pid,
        'httpCalls': cloud.calls,
        'mutationPosts': cloud.posts,
        'originalCreateCompared': cloud.comparedCreate,
        'originalCancelCompared': cloud.comparedCancel,
        'originalDeadlineUnchanged': true,
        'identityUnchanged': true,
        'observationUnchanged': true,
        'configurationUnchanged': true,
        'otherAccessScopesUnchanged': true,
        'plaintextAbsent': !cleanup,
        'missingKeyRejectedWithoutReset': missingKeyVerified,
        'fixtureRemoved': cleanup,
        'receiverRetainedForProcessDeath': retainForProcessDeath,
        'systemEnforced': false
      };
      debugPrint('SUBMISSION_STORAGE_RESULT ${jsonEncode(binding.reportData)}');
    } finally {
      if (retainForProcessDeath) {
        _retainedOwners.add(session);
        if (receiver != null) _retainedOwners.add(receiver!);
      } else {
        if (!sessionDisposed) session.dispose();
        await receiver?.close();
      }
      identity.close();
      cloud.client.close();
    }
  });
}
