import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:child/core/access.dart';
import 'package:child/core/environment.dart';
import 'package:child/core/session.dart';
import 'package:child/core/submission_receiver.dart';
import 'package:child/core/submissions.dart';
import 'package:child/platform/access_codec.dart';
import 'package:child/platform/access_database_io.dart';
import 'package:child/ui/child_app.dart';
import 'package:device_access/device_access.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

/// Explicit JVM-owned loopback acceptance driver, never imported by main.dart.
/// Registration/MFA and the file encryption key are controlled fixtures; request
/// HTTP, business transactions, production session/UI and encrypted IO are real.
/// Each phase starts a fresh Flutter process and reopens the same private files.
class _Bindings implements ChildAccessBindingStore, DeviceSecretStore {
  final Database database;
  final store = stringMapStoreFactory.store('bindings');
  _Bindings(this.database);
  @override
  Future<String?> read([String key = 'identity']) async =>
      (await store.record(key).get(database))?['value'] as String?;
  @override
  Future<void> write(String key, [String? value]) async {
    await store
        .record(value == null ? 'identity' : key)
        .put(database, {'value': value ?? key});
  }
}

/// Drain a real committed response, then simulate its loss at the client boundary.
/// All other requests and responses use the real loopback server unchanged.
class _FaultClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  bool loseCreateResponse;
  bool loseCancelResponse;
  final statuses = <String>[];
  _FaultClient(
      {required this.loseCreateResponse, this.loseCancelResponse = false});
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final result = await delegate.send(request);
    final suffix = request.url.path.split('/').last;
    statuses.add('${request.method}:$suffix:${result.statusCode}');
    if (loseCreateResponse &&
        request.method == 'POST' &&
        suffix == 'access-submissions' &&
        result.statusCode == 201) {
      loseCreateResponse = false;
      await result.stream.drain<void>();
      throw http.ClientException('Controlled response loss');
    }
    if (loseCancelResponse &&
        request.method == 'POST' &&
        suffix == 'cancel' &&
        result.statusCode == 200) {
      loseCancelResponse = false;
      await result.stream.drain<void>();
      throw http.ClientException('Controlled cancellation response loss');
    }
    return result;
  }

  @override
  void close() => delegate.close();
}

Future<void> _idle(WidgetTester tester, ChildSession session) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!session.initialized || session.busy) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Bounded child session deadline exceeded');
    }
    // IO completes on the real clock; continuations scheduled by initState and
    // button callbacks also need Flutter's simulated clock to make progress.
    await tester.pump(const Duration(milliseconds: 20));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
}

void main() {
  testWidgets('real Spring submission through product child session and UI',
      (tester) async {
    final path = Platform.environment['CHILD_SUBMISSION_HTTP_FIXTURE'];
    final mode = Platform.environment['CHILD_SUBMISSION_HTTP_MODE'];
    expect(path, isNotNull);
    expect({
      'submit',
      'approved',
      'revoked',
      'unauthenticated',
      'blocked',
      'cancel-submit',
      'cancel-recover'
    }, contains(mode));
    final file = File(path!);
    final data = jsonDecode((await tester.runAsync(file.readAsString))!)
        as Map<String, dynamic>;
    final root = Uri.parse(data['apiRoot'] as String);
    expect(root.scheme, 'http');
    expect(root.host, '127.0.0.1');
    final now = data['nowMillis'] as int;
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final priorOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final context = await tester.runAsync(() => databaseFactoryIo.openDatabase(
        '${file.parent.path}/child-context.db',
        codec: AccessDatabaseCodec(key, '0' * 64).sembastCodec));
    final bindings = _Bindings(context!);
    stdout.writeln('Child fixture: encrypted context opened');
    final client = _FaultClient(
        loseCreateResponse: mode == 'submit',
        loseCancelResponse: mode == 'cancel-submit');
    // Only initial registration/heartbeat are fixtures. Opaque authorization of
    // every request context, option, create, recovery and detail is server-owned.
    final identityClient = MockClient((request) async {
      final claim = request.url.path.endsWith('enrollment-claims');
      if (!claim && !request.url.path.endsWith('heartbeats')) {
        throw StateError('Unsupported identity fixture operation');
      }
      final response = claim
          ? {
              'deviceId': data['deviceId'],
              'registrationId': data['registrationId'],
              'credential': data['credential'],
              'expiresAt': now + 3600000,
              'pairingCode': '12345678',
              'confirmBefore': now + 600000,
              'state': 'AWAITING_CONFIRMATION'
            }
          : {
              'registrationId': data['registrationId'],
              'sequence': (jsonDecode(request.body) as Map)['sequence'],
              'receivedAt': now
            };
      return http.Response(jsonEncode(response), claim ? 201 : 200,
          headers: {'content-type': 'application/json'});
    });
    final identity = DeviceIdentityManager(
        api: DeviceIdentityApi(
            apiRoot: Uri.parse('https://registration-fixture.example/api/v1'),
            client: identityClient),
        secrets: bindings,
        nowMillis: () => now);
    ChildSubmissionReceiver? receiver;
    ChildSubmissionSnapshot? restored;
    final session = ChildSession(
        identity: identity,
        nowMillis: () => now,
        submissionFactory: (view) async {
          receiver = ChildSubmissionReceiver(
              environment:
                  ChildEnvironment(apiRoot: root, allowLoopbackHttp: true),
              identity: view,
              credential: identity.activeCredential,
              nowMillis: () => now,
              bindingStore: bindings,
              databaseOpener: (scope, {required existingDatabase}) =>
                  openAccessDatabase(scope,
                      requireExisting: existingDatabase,
                      directoryPath: file.parent.path,
                      keyProvider: (_, {required existingDatabase}) async =>
                          key),
              transportFactory: () => DeviceAccessTransport(
                  apiRoot: root,
                  credential: identity.activeCredential,
                  allowLoopbackHttp: true,
                  client: client));
          restored = await receiver!.restore();
          return receiver!;
        });
    Future<void> tap(String text) async {
      await tester.ensureVisible(find.text(text).last);
      await tester.tap(find.text(text).last);
      await tester.pump();
      await _idle(tester, session);
      await tester.pumpAndSettle();
    }

    Future<void> dialogClosed() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.byType(Dialog).evaluate().isNotEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Product dialog did not finish its operation');
        }
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      await tester.pumpAndSettle();
    }

    var appMounted = false;
    try {
      if (mode == 'submit' || mode == 'cancel-submit') {
        await tester.runAsync(() async {
          stdout.writeln('Child fixture: identity bootstrap started');
          await identity.begin(
              EnrollmentTicket(
                  tenantId: data['tenantId'],
                  enrollmentId: '22222222-2222-2222-2222-222222222222',
                  token: 'a' * 43,
                  expiresAt: now + 600000),
              displayName: '联调设备',
              osVersion: 'controlled fixture');
          await identity.heartbeat(
              agentVersion: 'http-acceptance', capabilities: const []);
          stdout.writeln('Child fixture: identity bootstrap completed');
        });
      }
      await tester
          .pumpWidget(ChildApp(nativeAvailable: true, session: session));
      appMounted = true;
      stdout.writeln('Child fixture: product UI mounted');
      await _idle(tester, session);
      await tester.pumpAndSettle();
      await tap('规则');
      expect(find.text('临时访问申请'), findsOneWidget);
      expect(session.systemEnforced, isFalse);
      if (mode == 'submit' || mode == 'cancel-submit') {
        expect(session.submissions.onlineConfirmed, isTrue);
        await tap('申请临时访问');
        await tap('阅读');
        await tester.enterText(
            find.byKey(const Key('submission-reason')), '完成阅读');
        await tap('核对申请');
        expect(find.text('确认申请内容'), findsOneWidget);
        expect(session.submissions.journal!.pending, isNull);
        await tap('提交给监护人');
        await dialogClosed();
        if (mode == 'cancel-submit') {
          expect(session.submissions.journal!.entries.single.value.state,
              'PENDING');
          expect(session.submissions.journal!.pending, isNull);
          await tap('查看申请');
          await tap('取消申请');
          expect(find.text('确认取消这份申请？'), findsOneWidget);
          expect(session.submissions.journal!.pending, isNull);
          expect(client.statuses.where((s) => s.startsWith('POST:cancel:')),
              isEmpty);
          await tap('确认取消');
          await dialogClosed();
          expect(session.submissions.journal!.pending!.kind, 'CANCEL');
          expect(session.submissions.journal!.pending!.version, 0);
          expect(client.statuses, contains('POST:cancel:200'));
        }
        final pending = session.submissions.journal!.pending!;
        expect(pending.phase, SubmissionOperationPhase.unknown);
        if (mode == 'submit') expect(pending.input!.reason, '完成阅读');
        expect(find.text('结果待确认'), findsOneWidget);
        expect(find.text('放弃本次操作'), findsNothing);
        expect(client.statuses, contains('POST:access-submissions:201'));
      } else if (mode == 'approved' || mode == 'cancel-recover') {
        final pending = restored!.journal!.pending!;
        expect(pending.phase, SubmissionOperationPhase.unknown);
        if (mode == 'approved') {
          expect(pending.input!.reason, '完成阅读');
        } else {
          expect(pending.kind, 'CANCEL');
          expect(pending.requestId, data['requestId']);
          expect(pending.version, 0);
        }
        expect(session.submissions.journal!.pending!.key, pending.key);
        await tap('按原操作重试');
        expect(find.text('确认原操作'), findsOneWidget);
        if (mode == 'approved') expect(find.text('完成阅读'), findsOneWidget);
        await tap('确认重试');
        await dialogClosed();
        expect(session.submissions.journal!.pending, isNull);
        final fact = session.submissions.journal!.entries.single.value;
        expect(fact.id, data['requestId']);
        if (mode == 'approved') {
          expect(fact.absoluteNotAfter, data['absoluteNotAfter']);
          expect(fact.state, 'APPROVED_PENDING_DELIVERY');
          expect(find.text('已批准，等待配置同步'), findsOneWidget);
          expect(
              client.statuses,
              containsAll(
                  ['POST:access-submissions:409', 'POST:recovery:200']));
        } else {
          expect(fact.state, 'CANCELLED');
          expect(fact.version, 1);
          expect(find.text('已取消'), findsOneWidget);
          expect(client.statuses,
              containsAll(['POST:cancel:409', 'POST:cancel-recovery:200']));
        }
      } else if (mode == 'revoked') {
        expect(restored!.journal!.entries.single.value.state,
            'APPROVED_PENDING_DELIVERY');
        final fact = session.submissions.journal!.entries.single.value;
        expect(fact.id, data['requestId']);
        expect(fact.absoluteNotAfter, data['absoluteNotAfter']);
        expect(fact.state, 'REVOKED');
        expect(find.text('已撤回'), findsOneWidget);
      } else {
        if (mode == 'unauthenticated') {
          expect(restored!.journal!.entries.single.value.state, 'REVOKED');
        } else {
          expect(restored!.contextReady, isFalse);
          expect(restored!.journal, isNull);
        }
        expect(session.submissions.journal, isNull);
        expect(session.submissionErrorCode, 'DEVICE_UNAUTHENTICATED');
        expect(find.text('已撤回'), findsNothing);
        expect(find.text('阅读'), findsNothing);
        expect(find.text('完成阅读'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      stdout.writeln('Child submission HTTP $mode: PASS');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (!appMounted) session.dispose();
        await receiver?.close();
        identityClient.close();
        client.close();
        await context.close();
      });
      HttpOverrides.global = priorOverrides;
    }
  });
}
