import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/invitations.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/member_center.dart';

import 'support/parent_operation_journal_fixture.dart';

const id = '00000000-0000-4000-8000-000000000001',
    classId = '00000000-0000-4000-8000-000000000002';
final secret = 'a' * 43;
Json input() => {
      'recipientEmail': 'teacher@example.test',
      'role': 'AUDITOR',
      'subjectId': null,
      'classIds': <String>[]
    };
Json invitation(
        {String state = 'PENDING',
        String role = 'AUDITOR',
        List<String> classes = const []}) =>
    {
      'id': id,
      'role': role,
      'subjectId': null,
      'classIds': classes,
      'expiresAt': 4102444800000,
      'state': state
    };
Json issued(String requestId, {String? token, Json? row}) =>
    {'requestId': requestId, 'invitation': row ?? invitation(), 'token': token};
http.Response response(Object? body, [int status = 200]) => body == null
    ? http.Response('', status)
    : http.Response.bytes(utf8.encode(jsonEncode(body)), status);
ParentApi apiFor(Future<http.Response> Function(http.Request) handle) =>
    ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(handle));

class Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    if (fail) throw StateError('disk');
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

class Session extends ParentSession {
  final ParentApi fixture;
  Session(this.fixture) {
    tenant = {'id': 'tenant', 'kind': 'ORGANIZATION'};
    profile = {'subject': 'owner'};
    role = 'OWNER';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  void change() {
    generation++;
    notifyListeners();
  }
}

InvitationOperationController make(ParentApi api, Storage storage,
        {bool Function()? current}) =>
    InvitationOperationController(
        api: api,
        tenant: 'tenant',
        actor: 'owner',
        store: InvitationOperationStore(storage: storage),
        isCurrent: current ?? () => true);

void main() {
  test(
      'invitation contracts reject owner scope timestamp and duplicate classes',
      () {
    expect(
        invitationRoles('FAMILY', 'OWNER'), ['GUARDIAN', 'AUDITOR', 'CHILD']);
    expect(invitationRoles('ORGANIZATION', 'ORG_ADMIN'),
        ['TEACHER', 'AUDITOR', 'CHILD']);
    expect(invitationRoles('ORGANIZATION', 'CHILD'), isEmpty);
    for (final row in [
      invitation(role: 'OWNER'),
      {...invitation(), 'expiresAt': 1.0},
      invitation(role: 'TEACHER', classes: [classId, classId]),
      {...invitation(), 'state': 'ACTIVE'}
    ]) {
      expect(() => readInvitation(row), throwsA(isA<ParentApiException>()));
    }
    expect(() => validateInvitationInput({...input(), 'recipientEmail': 'bad'}),
        throwsFormatException);
  });
  test(
      'lost issuance reply retries same key without retaining or reissuing a token',
      () async {
    final storage = Storage(), writes = <http.Request>[];
    final api = apiFor((r) async {
      if (r.url.path.endsWith('/issuances')) {
        writes.add(r);
        if (writes.length == 1) {
          throw http.ClientException('synthetic response loss');
        }
        return response(issued(r.headers['Idempotency-Key']!));
      }
      return response(
          issued(r.url.pathSegments[r.url.pathSegments.length - 2]));
    });
    var c = make(api, storage);
    await c.load();
    await c.issue(input());
    expect(c.error, isA<ParentApiException>());
    expect(c.committed, isFalse);
    c.dispose();
    c = make(api, storage);
    await c.load();
    expect(writes, hasLength(1));
    await c.recover(retry: true);
    expect(c.error, isNull);
    expect(c.committed, isTrue);
    expect(c.token, isNull);
    expect(writes[1].headers['Idempotency-Key'],
        writes[0].headers['Idempotency-Key']);
    expect(writes[1].body, writes[0].body);
    expect(c.latest!['id'], id);
    expect(storage.values.values.single, isNot(contains(secret)));
    expect(await c.acknowledge(), isTrue);
    expect(storage.values, isEmpty);
    c.dispose();
  });
  test(
      'successful token remains memory only and disappears after background even if reply is late',
      () async {
    final storage = Storage(), reply = Completer<http.Response>();
    String? key;
    final c = make(apiFor((r) {
      key = r.headers['Idempotency-Key'];
      return reply.future;
    }), storage);
    await c.load();
    final sending = c.issue(input());
    await Future<void>.delayed(Duration.zero);
    c.forgetToken();
    reply.complete(response(issued(key!, token: secret)));
    await sending;
    expect(c.error, isNull);
    expect(c.token, isNull);
    expect(c.committed, isTrue);
    expect(storage.values.values.single, isNot(contains(secret)));
    c.dispose();
  });
  test('normal first response exposes token until it is explicitly forgotten',
      () async {
    final storage = Storage();
    final c = make(
        apiFor((r) async =>
            response(issued(r.headers['Idempotency-Key']!, token: secret))),
        storage);
    await c.load();
    await c.issue(input());
    expect(c.token, secret);
    expect(storage.values.values.single, isNot(contains(secret)));
    c.forgetToken();
    expect(c.token, isNull);
    c.dispose();
  });
  test('recovery query cannot inject a token or replace the requested role',
      () async {
    for (final injected in [true, false]) {
      final storage = Storage();
      final c = make(apiFor((r) async {
        if (r.url.path.endsWith('/issuances')) {
          throw http.ClientException('lost');
        }
        return response(issued(
            r.url.pathSegments[r.url.pathSegments.length - 2],
            token: injected ? secret : null,
            row: invitation(role: injected ? 'AUDITOR' : 'ORG_ADMIN')));
      }), storage);
      await c.load();
      await c.issue(input());
      await c.recover();
      expect(c.error, isA<ParentApiException>());
      expect(c.committed, isFalse);
      expect(c.token, isNull);
      expect(await c.acknowledge(), isFalse);
      c.dispose();
    }
  });
  test('cancel recovery distinguishes acceptance from cancellation', () async {
    final storage = Storage();
    var state = 'ACCEPTED';
    final c = make(apiFor((r) async {
      if (r.method == 'DELETE') throw http.ClientException('lost');
      return response(invitation(state: state));
    }), storage);
    await c.load();
    await c.cancel(invitation());
    await c.recover();
    expect(c.latest!['state'], 'ACCEPTED');
    expect(c.committed, isFalse);
    expect(c.queried, isTrue);
    state = 'CANCELLED';
    await c.recover();
    expect(c.committed, isTrue);
    expect(await c.acknowledge(), isTrue);
    c.dispose();
  });
  test('unavailable result is not classified as committed', () async {
    final c = make(apiFor((r) async {
      if (r.url.path.endsWith('/issuances')) throw http.ClientException('lost');
      return response({'errorCode': 'INVITATION_RESULT_UNAVAILABLE'}, 404);
    }), Storage());
    await c.load();
    await c.issue(input());
    await c.recover();
    expect(c.error, isNull);
    expect(c.committed, isFalse);
    expect(c.queried, isTrue);
    expect(c.latest, isNull);
    c.dispose();
  });
  test(
      'storage failure blocks a write and identity change blocks token refresh dispatch',
      () async {
    var calls = 0;
    final storage = Storage()..fail = true;
    final c = make(apiFor((_) async {
      calls++;
      return response(null, 204);
    }), storage);
    await c.load();
    await c.issue(input());
    expect(calls, 0);
    expect(c.loaded, isFalse);
    c.dispose();
    var current = true;
    final token = Completer<String>();
    final d = make(
        ParentApi(() => token.future, baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((_) async {
          calls++;
          return response(null, 204);
        })),
        Storage(),
        current: () => current);
    await d.load();
    final pending = d.issue(input());
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('token');
    await pending;
    expect(calls, 0);
    d.dispose();
  });
  test('recovery storage rejects secret fields and never presents them',
      () async {
    final storage = Storage();
    final store = InvitationOperationStore(storage: storage);
    storage.values[store.key('tenant', 'owner')] = jsonEncode({
      'requestId': id,
      'operation': 'ISSUE',
      'input': input(),
      'token': secret
    });
    expect(() => store.load('tenant', 'owner'), throwsFormatException);
  });
  testWidgets(
      'recovered invitation can be voided directly without searching the list',
      (tester) async {
    final storage = Storage();
    final recoveryStore = InvitationOperationStore(storage: storage);
    await recoveryStore.save('tenant', 'owner',
        {'requestId': id, 'operation': 'ISSUE', 'input': input()});
    var deletes = 0;
    final session = Session(apiFor((r) async {
      if (r.method == 'DELETE') {
        deletes++;
        return response(null, 204);
      }
      if (r.url.path.endsWith('/query')) return response(issued(id));
      if (r.url.path.endsWith('/$id')) {
        return response(invitation(state: 'CANCELLED'));
      }
      return response({'items': [], 'nextCursor': null});
    }));
    await tester.pumpWidget(MaterialApp(
        home: InvitationCenter(session: session, store: recoveryStore)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对原操作'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('作废这份邀请'), 150);
    await tester.tap(find.text('作废这份邀请'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认作废'));
    await tester.pumpAndSettle();
    expect(deletes, 1);
    expect(jsonDecode(storage.values.values.single)['operation'], 'CANCEL');
    expect(find.textContaining('最近核对：已取消'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The same encrypted store partitions pending requests by tenant and actor.
    expect(await recoveryStore.load('tenant', 'another'), isNull);
  });
  testWidgets('guardian cannot fetch invitations', (tester) async {
    var calls = 0;
    final session = Session(apiFor((_) async {
      calls++;
      return response({});
    }))
      ..role = 'GUARDIAN';
    await tester.pumpWidget(MaterialApp(
        home: InvitationCenter(
            session: session,
            store: InvitationOperationStore(storage: Storage()))));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('邀请内容已隐藏。'), findsOneWidget);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets('invitation creation uses selected class at font scale $scale',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const font = String.fromEnvironment('UI_CAPTURE_FONT'),
          icons = String.fromEnvironment('UI_CAPTURE_ICONS');
      for (final e
          in {'LocalCaptureFont': font, 'MaterialIcons': icons}.entries) {
        if (e.value.isNotEmpty) {
          await tester.runAsync(() async {
            final loader = FontLoader(e.key)
              ..addFont(Future.value(
                  ByteData.sublistView(await File(e.value).readAsBytes())));
            await loader.load();
          });
        }
      }
      final writes = <http.Request>[];
      final storage = Storage();
      final session = Session(apiFor((r) async {
        if (r.url.path.endsWith('/issuances')) {
          writes.add(r);
          return response(issued(r.headers['Idempotency-Key']!,
              token: secret,
              row: invitation(role: 'TEACHER', classes: [classId])));
        }
        if (r.url.path.endsWith('/classes')) {
          return response({
            'items': [
              {
                'id': classId,
                'name': '一年级一班',
                'state': 'ACTIVE',
                'version': 0,
                'studentCount': 20,
                'createdAt': 1,
                'updatedAt': 1
              }
            ],
            'nextCursor': null
          });
        }
        return response({'items': [], 'nextCursor': null});
      }));
      final boundary = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                  useMaterial3: true,
                  colorSchemeSeed: const Color(0xFF315E86),
                  fontFamily: font.isEmpty ? null : 'LocalCaptureFont'),
              home: InvitationCenter(
                  session: session,
                  store: InvitationOperationStore(storage: storage)))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建邀请'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并创建'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.enterText(find.byType(TextField), 'teacher@example.test');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('按班级授权'));
      await tester.tap(find.text('按班级授权'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('选择班级（0/50）'));
      await tester.tap(find.text('选择班级（0/50）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一年级一班'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认 1 个班级'));
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('CAPTURE_INVITATION_UI') && scale == 1.0) {
        await tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('../../.local/parent-invitation-portrait.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('核对并创建'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认创建'));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(jsonDecode(writes.single.body), {
        ...input(),
        'role': 'TEACHER',
        'classIds': [classId]
      });
      expect(storage.values.values.single, isNot(contains(secret)));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.text(secret), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text(secret), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('session change closes create confirmation before a write',
      (tester) async {
    var writes = 0;
    final session = Session(apiFor((r) async {
      if (r.method != 'GET') writes++;
      return response({'items': [], 'nextCursor': null});
    }));
    session.tenant = {'id': 'tenant', 'kind': 'FAMILY'};
    await tester.pumpWidget(MaterialApp(
        home: InvitationCenter(
            session: session,
            store: InvitationOperationStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建邀请'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'parent@example.test');
    await tester.tap(find.text('核对并创建'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    session.change();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(writes, 0);
  });
}
