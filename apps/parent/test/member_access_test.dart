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
import 'package:parent/core/member_access.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/member_center.dart';

final key = 'a' * 64;
const a = '00000000-0000-4000-8000-000000000001',
    b = '00000000-0000-4000-8000-000000000002';
Json member(
        {int version = 0,
        String role = 'AUDITOR',
        String? subject,
        List<String> classes = const []}) =>
    {
      'memberKey': key,
      'actorId': 'member-actor',
      'role': role,
      'subjectId': subject,
      'classIds': classes,
      'version': version
    };
Json row({String role = 'AUDITOR'}) => {
      ...member(role: role),
      'cursor': key,
      'displayName': '林老师',
      'subjectName': null,
      'subjectArchived': false,
      'verifiedEmail': 'teacher@example.invalid'
    }..remove('memberKey');
Json input() => {
      'operation': 'UPDATE',
      'version': 0,
      'role': 'TEACHER',
      'subjectId': null,
      'classIds': [b, a]
    };
Json changed() => member(version: 1, role: 'TEACHER', classes: [a, b]);
Json classroom(String id, String name) => {
      'id': id,
      'name': name,
      'state': 'ACTIVE',
      'version': 0,
      'studentCount': 2,
      'createdAt': 1,
      'updatedAt': 1
    };
http.Response response(Object? value, [int status = 200]) => value == null
    ? http.Response('', status)
    : http.Response.bytes(utf8.encode(jsonEncode(value)), status);
ParentApi apiFor(Future<http.Response> Function(http.Request) handler) =>
    ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(handler));

class Storage extends ParentDurableStorage {
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

void main() {
  test('role choices preserve adult child boundary and protected owners', () {
    expect(memberRoles('FAMILY', 'OWNER', 'GUARDIAN'), ['GUARDIAN', 'AUDITOR']);
    expect(memberRoles('ORGANIZATION', 'ORG_ADMIN', 'ORG_ADMIN'), isEmpty);
    expect(memberRoles('ORGANIZATION', 'OWNER', 'OWNER'), isEmpty);
    expect(memberRoles('ORGANIZATION', 'OWNER', 'CHILD'), ['CHILD']);
    expect(memberRoles('ORGANIZATION', 'OWNER', 'TEACHER'),
        ['ORG_ADMIN', 'TEACHER', 'AUDITOR']);
  });
  test(
      'scope and history contracts reject malformed or impossible combinations',
      () {
    validateMemberRow(row());
    expect(() => readMemberAccess({...member(), 'memberKey': '../other'}),
        throwsA(isA<ParentApiException>()));
    expect(
        () => validateMemberOperation({
              ...input(),
              'classIds': [a, a]
            }, member()),
        throwsFormatException);
    expect(
        () => validateMemberOperation(
            {...input(), 'role': 'CHILD', 'subjectId': a, 'classIds': []},
            member()),
        throwsFormatException);
    expect(
        () => validateMemberOperation({...input(), 'version': 0.0}, member()),
        throwsA(isA<ParentApiException>()));
    expect(
        () => validateMemberHistory({
              'id': a,
              'memberVersion': 1,
              'occurredAt': 9007199254740991,
              'changedByActorId': 'owner',
              'previousRole': 'AUDITOR',
              'previousSubjectId': null,
              'previousClassIds': [],
              'changeType': 'UPDATED',
              'role': 'TEACHER',
              'subjectId': null,
              'classIds': [a]
            }),
        throwsA(isA<ParentApiException>()));
  });
  test('lost update retries same body key version with normalized class result',
      () async {
    final calls = <http.Request>[];
    final api = apiFor((r) async {
      calls.add(r);
      if (calls.length == 1) throw http.ClientException('lost');
      if (r.method == 'PATCH') return response(changed());
      return response({
        'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
        'operation': 'UPDATE',
        'committedAccess': changed(),
        'revocationCommitted': false,
        'current': member(version: 2),
        'currentState': 'ACTIVE'
      });
    });
    final store = MemberOperationStore(storage: Storage());
    MemberOperationController make() => MemberOperationController(
        api: api, tenant: 't', actor: 'a', store: store, isCurrent: () => true);
    var c = make();
    await c.load();
    await c.submit(input(), member());
    expect(c.saved, isFalse);
    c.dispose();
    c = make();
    await c.load();
    expect(calls, hasLength(1));
    await c.recover(retry: true);
    expect(c.error, isNull);
    expect(c.committed!['role'], 'TEACHER');
    expect(c.latest!['role'], 'AUDITOR');
    expect(calls[0].body, calls[1].body);
    expect(calls[0].headers['Idempotency-Key'],
        calls[1].headers['Idempotency-Key']);
    expect(calls[1].headers['If-Match'], '"0"');
    expect(await c.acknowledge(), isTrue);
    c.dispose();
  });
  test('revoke recovery preserves historical success when member has rejoined',
      () async {
    final api = apiFor((r) async {
      if (r.method == 'DELETE') throw http.ClientException('lost');
      return response({
        'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
        'operation': 'REVOKE',
        'committedAccess': null,
        'revocationCommitted': true,
        'current': member(version: 2),
        'currentState': 'ACTIVE'
      });
    });
    final store = MemberOperationStore(storage: Storage());
    MemberOperationController make() => MemberOperationController(
        api: api, tenant: 't', actor: 'a', store: store, isCurrent: () => true);
    var c = make();
    await c.load();
    await c.submit({'operation': 'REVOKE', 'version': 0}, member());
    c.dispose();
    c = make();
    await c.load();
    await c.recover();
    expect(c.error, isNull);
    expect(c.saved, isTrue);
    expect(c.currentState, 'ACTIVE');
    expect(c.committed, isNull);
    expect(await c.acknowledge(), isTrue);
    c.dispose();
  });
  test('wrong recovery member cannot be presented as committed', () async {
    final api = apiFor((r) async {
      if (r.method == 'PATCH') throw http.ClientException('lost');
      return response({
        'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
        'operation': 'UPDATE',
        'committedAccess': {...changed(), 'actorId': 'another'},
        'revocationCommitted': false,
        'current': changed(),
        'currentState': 'ACTIVE'
      });
    });
    final c = MemberOperationController(
        api: api,
        tenant: 't',
        actor: 'a',
        store: MemberOperationStore(storage: Storage()),
        isCurrent: () => true);
    await c.load();
    await c.submit(input(), member());
    await c.recover();
    expect(c.saved, isFalse);
    expect(c.error, isA<ParentApiException>());
    expect(c.queried, isFalse);
    c.dispose();
  });
  test('failed storage write prevents network', () async {
    var calls = 0;
    final c = MemberOperationController(
        api: apiFor((_) async {
          calls++;
          return response(null, 204);
        }),
        tenant: 't',
        actor: 'a',
        store: MemberOperationStore(storage: Storage()..fail = true),
        isCurrent: () => true);
    await c.load();
    await c.submit(input(), member());
    expect(calls, 0);
    expect(c.loaded, isFalse);
    c.dispose();
  });
  test('scope loss during token refresh prevents dispatch', () async {
    var current = true, calls = 0;
    final token = Completer<String>();
    final api =
        ParentApi(() => token.future, baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((_) async {
      calls++;
      return response(null, 204);
    }));
    final c = MemberOperationController(
        api: api,
        tenant: 't',
        actor: 'a',
        store: MemberOperationStore(storage: Storage()),
        isCurrent: () => current);
    await c.load();
    final sending = c.submit(input(), member());
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('token');
    await sending;
    expect(calls, 0);
    expect(c.pending, isNotNull);
    c.dispose();
  });
  testWidgets('guardian cannot load member directory', (tester) async {
    var calls = 0;
    final session = Session(apiFor((_) async {
      calls++;
      return response({});
    }))
      ..role = 'GUARDIAN';
    await tester.pumpWidget(MaterialApp(
        home: MemberCenter(
            session: session,
            store: MemberOperationStore(storage: Storage()))));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('成员内容已隐藏。'), findsOneWidget);
  });
  testWidgets('owner member has no edit or revoke action', (tester) async {
    final api = apiFor((r) async {
      if (r.url.path.endsWith('/access')) {
        return response(member(role: 'OWNER'));
      }
      return response({
        'items': r.url.path.endsWith('/members') ? [row(role: 'OWNER')] : [],
        'nextCursor': null
      });
    });
    await tester.pumpWidget(MaterialApp(
        home: MemberCenter(
            session: Session(api),
            store: MemberOperationStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('林老师'));
    await tester.pumpAndSettle();
    expect(find.text('调整角色与范围'), findsNothing);
    expect(find.text('撤销成员资格'), findsNothing);
  });
  for (final textScale in [1.0, 2.0]) {
    testWidgets(
        'member role editing selects exact scope at text scale $textScale',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final writes = <http.Request>[];
      var current = member();
      final api = apiFor((r) async {
        if (r.method == 'PATCH') {
          writes.add(r);
          current = changed();
          return response(current);
        }
        if (r.url.path.endsWith('/query')) {
          return response({
            'requestId': r.url.pathSegments[r.url.pathSegments.length - 2],
            'operation': 'UPDATE',
            'committedAccess': current,
            'revocationCommitted': false,
            'current': current,
            'currentState': 'ACTIVE'
          });
        }
        if (r.url.path.endsWith('/access')) return response(current);
        if (r.url.path.endsWith('/classes')) {
          return response({
            'items': [classroom(a, '一班'), classroom(b, '二班')],
            'nextCursor': null
          });
        }
        return response({
          'items': r.url.path.endsWith('/members') ? [row()] : [],
          'nextCursor': null
        });
      });
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const fontFile = String.fromEnvironment('UI_CAPTURE_FONT'),
          iconFile = String.fromEnvironment('UI_CAPTURE_ICONS');
      for (final entry in {
        'LocalCaptureFont': fontFile,
        'MaterialIcons': iconFile
      }.entries) {
        if (entry.value.isNotEmpty) {
          await tester.runAsync(() async {
            final loader = FontLoader(entry.key)
              ..addFont(Future.value(
                  ByteData.sublistView(await File(entry.value).readAsBytes())));
            await loader.load();
          });
        }
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                  useMaterial3: true,
                  colorSchemeSeed: const Color(0xFF315E86),
                  fontFamily: fontFile.isEmpty ? null : 'LocalCaptureFont'),
              home: MemberCenter(
                  session: Session(api),
                  store: MemberOperationStore(storage: Storage())))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('林老师'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('调整角色与范围'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('教师').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('按班级授权'));
      await tester.tap(find.text('按班级授权'));
      await tester.pumpAndSettle();
      // A missing scope remains editable without reloading the original member scope.
      await tester.ensureVisible(find.text('核对并保存'));
      await tester.tap(find.text('核对并保存'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      expect(find.text('请选择有效学生或班级；移除已归档和不可用的范围。'), findsOneWidget);
      await tester.ensureVisible(find.text('选择班级（0/50）'));
      await tester.tap(find.text('选择班级（0/50）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一班'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('二班'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认 2 个班级'));
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('CAPTURE_MEMBER_UI') && textScale == 1.0) {
        await tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('../../.local/parent-member-portrait.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.ensureVisible(find.text('核对并保存'));
      await tester.tap(find.text('核对并保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
      await tester.pumpAndSettle();
      expect(writes, hasLength(1));
      expect(jsonDecode(writes.single.body), {
        'role': 'TEACHER',
        'subjectId': null,
        'classIds': [a, b]
      });
      expect(writes.single.headers['If-Match'], '"0"');
      expect(find.text('原操作已保存'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('session generation closes revoke confirmation before dispatch',
      (tester) async {
    var writes = 0;
    final session = Session(apiFor((r) async {
      if (r.method != 'GET') writes++;
      if (r.url.path.endsWith('/access')) return response(member());
      return response({
        'items': r.url.path.endsWith('/members') ? [row()] : [],
        'nextCursor': null
      });
    }));
    await tester.pumpWidget(MaterialApp(
        home: MemberCenter(
            session: session,
            store: MemberOperationStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('林老师'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销成员资格'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    session.change();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(writes, 0);
  });
}
