import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/member_access.dart';
import 'package:guardian/core/member_scope_directories.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/ui/member_editor.dart';
import 'package:guardian/ui/design.dart';

Future<void> open(WidgetTester tester, Future<Json> Function(Json) submit,
    {Json? member, bool retryUncertain = true,
    VoidCallback? reauth, void Function(Json?)? onResult,
    MemberScopeDirectories? directories, bool wait = true}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    final result = await showDialog<Json>(
                      context: context,
                      builder: (_) => MemberEditor(
                            kind: 'ORGANIZATION',
                            operatorRole: 'OWNER',
                            subjects: directories == null
                                ? const {'a': '小明', 'b': '小雨'} : const {},
                            classes: directories == null
                                ? const {'c1': '七年级一班', 'c2': '七年级二班'} : const {},
                            directories: directories,
                            member: member,
                            onSubmit: submit,
                            retryUncertain: retryUncertain,
                            reauth: reauth,
                          ));
                    onResult?.call(result);
                  },
                  child: const Text('打开'))))));
  await tester.tap(find.text('打开'));
  if (wait) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets('scope options load only when needed and leaving stops late pagination',
      (tester) async {
    final reads = <http.Request>[];
    final pending = Completer<http.Response>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(http.Response(
          '{"items":[],"nextCursor":null}', 200,
          headers: {'content-type': 'application/json; charset=utf-8'}));
    });
    final client = MockClient((request) async {
      reads.add(request);
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/tenants/fixture/classes');
      return pending.future;
    });
    addTearDown(client.close);
    final directories = MemberScopeDirectories(
        api: Api(() async => client, baseUrl: 'http://fixture.invalid/api/v1'),
        root: '/tenants/fixture', current: () => true);
    Json? sent;
    await open(tester, (body) async { sent = body; return body; },
        directories: directories);
    expect(reads, isEmpty);
    await tester.enterText(find.byKey(const Key('member-email')), 'audit@fixture.invalid');
    await tester.tap(find.byKey(const Key('member-role')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('教师').last);
    for (var frame = 0; frame < 6; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(reads, hasLength(1));
    expect(find.byKey(const Key('member-classes-loading')), findsOneWidget);
    await tester.tap(find.byKey(const Key('member-role')));
    // The pending indicator keeps animating while the menu is open.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('审计员').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('创建邀请'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(sent, {'recipientEmail': 'audit@fixture.invalid', 'role': 'AUDITOR'});
    expect(find.byType(MemberEditor), findsNothing);
    pending.complete(http.Response(jsonEncode({
      'items': [{'id': 'class-full', 'name': '晚到班级', 'state': 'ACTIVE'}],
      'nextCursor': 'must-not-load',
    }), 200, headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpAndSettle();
    expect(reads, hasLength(1));
    expect(directories.current, isFalse);
    expect(find.textContaining('晚到班级'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing original subject survives option failure and retry without changing an unknown write',
      (tester) async {
    final pending = Completer<http.Response>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(http.Response(
          '{"items":[],"nextCursor":null}', 200,
          headers: {'content-type': 'application/json; charset=utf-8'}));
    });
    var reads = 0;
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/tenants/fixture/subjects');
      reads++;
      if (reads == 1) return pending.future;
      return http.Response(jsonEncode({'items': [
        {'id': 'available-subject-full', 'nickname': '小雨', 'archived': false},
      ], 'nextCursor': null}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    addTearDown(client.close);
    final directories = MemberScopeDirectories(
        api: Api(() async => client, baseUrl: 'http://fixture.invalid/api/v1'),
        root: '/tenants/fixture', current: () => true);
    final sent = <Json>[];
    var authentications = 0;
    await open(tester, (body) async {
      sent.add(body);
      if (sent.length == 1) throw const ApiFailure(503, 'REQUEST_FAILED');
      return body;
    }, directories: directories, wait: false,
        reauth: () { authentications++; }, member: {
      'actorId': 'teacher', 'displayName': '林老师', 'role': 'TEACHER',
      'subjectId': 'original-subject-full', 'classIds': <String>[], 'version': 7,
    });
    for (var frame = 0; frame < 6; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(reads, 1);
    expect(tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('member-subject'))).initialValue, 'original-subject-full');
    expect(find.textContaining('original-subject-full'), findsWidgets);
    pending.complete(http.Response('{"errorCode":"REAUTH_REQUIRED"}', 401));
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('member-subject'))).initialValue, 'original-subject-full');
    final originalRetry = tester.widget<FailureView>(find.byType(FailureView)).retry!;
    await tester.ensureVisible(find.text('重新安全验证'));
    await tester.tap(find.text('重新安全验证'));
    await tester.pumpAndSettle();
    expect(authentications, 1);
    expect(reads, 1);
    expect(sent, isEmpty);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('member-subject'))).initialValue, 'original-subject-full');
    expect(sent, isEmpty);
    await tester.ensureVisible(find.byKey(const Key('member-subject')));
    await tester.tap(find.byKey(const Key('member-subject')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小雨').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存权限'));
    await tester.pumpAndSettle();
    originalRetry();
    await tester.pumpAndSettle();
    expect(reads, 2, reason: 'A retained option retry cannot refresh while a write is unknown.');
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(sent, [
      {'role': 'TEACHER', 'subjectId': 'available-subject-full'},
      {'role': 'TEACHER', 'subjectId': 'available-subject-full'},
    ]);
    expect(reads, 2);
    expect(tester.takeException(), isNull);
  });

  test('class-scoped teachers are never labelled as workspace-wide', () {
    expect(
        memberScope({
          'role': 'TEACHER',
          'classIds': ['c1', 'c2']
        }),
        '2 个班级');
  });
  group('member access snapshots', () {
    const actor = ' oidc|School.Alice/汉字 ';
    const key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const subjectA = '00000000-0000-4000-8000-000000000001';
    const subjectB = '00000000-0000-4000-8000-000000000002';
    const classA = '10000000-0000-4000-8000-000000000001';
    const classB = '10000000-0000-4000-8000-000000000002';
    const classC = '10000000-0000-4000-8000-000000000003';
    final target = MemberAccessTarget.fromRow({'actorId': actor, 'cursor': key});
    final invalid = throwsA(isA<ApiFailure>()
        .having((failure) => failure.status, 'status', 502)
        .having((failure) => failure.code, 'code', 'INVALID_MEMBER_ACCESS_RESPONSE'));
    Json access({String role = 'TEACHER', String? subjectId = subjectA,
        List<String> classIds = const [], int version = 7}) => {
      'actorId': actor, 'memberKey': key, 'role': role,
      'subjectId': subjectId, 'version': version, 'classIds': classIds,
    };
    MemberAccessSnapshot read(Object? raw, {MemberAccessSnapshot? previous}) =>
        MemberAccessSnapshot.read(raw, kind: 'ORGANIZATION', target: target,
            previous: previous);

    test('binds the exact non-UUID actor and deeply freezes access facts', () {
      final classes = [classB, classA];
      final raw = access(subjectId: null, classIds: classes);
      final snapshot = read(raw);
      classes.clear();
      raw['role'] = 'AUDITOR';
      expect(snapshot.actorId, actor);
      expect(snapshot.memberKey, key);
      expect(snapshot.role, 'TEACHER');
      expect(snapshot.classIds, [classA, classB]);
      expect(snapshot.toJson(), {
        'actorId': actor, 'memberKey': key, 'role': 'TEACHER',
        'subjectId': null, 'version': 7, 'classIds': [classA, classB],
      });
      expect(() => snapshot.classIds.add(classC), throwsUnsupportedError);
      expect(() => snapshot.toJson()['role'] = 'AUDITOR', throwsUnsupportedError);
      expect(() => (snapshot.toJson()['classIds'] as List).clear(),
          throwsUnsupportedError);
      expect(() => read({...access(), 'actorId': actor.trim()}), invalid);
      expect(() => MemberAccessTarget.fromRow({'actorId': '  ', 'cursor': key}),
          invalid);
      expect(() => MemberAccessTarget.fromRow({'actorId': actor, 'cursor': 'short'}),
          invalid);
      expect(MemberAccessTarget.fromRow({'actorId': '\u00a0', 'cursor': key}).actorId,
          '\u00a0', reason: 'Non-breaking space is not blank under Java isBlank.');
      expect(() => MemberAccessTarget.fromRow({'actorId': '\u001c', 'cursor': key}),
          invalid);
    });

    test('rejects malformed or incompatible current access responses', () {
      final missingSubject = access()..remove('subjectId');
      for (final raw in [
        {...access(), 'memberKey': 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'},
        missingSubject,
        {...access(), 'version': 7.5},
        {...access(), 'version': 9007199254740992},
        {...access(), 'profile': <String, dynamic>{}},
        access(subjectId: null),
        access(role: 'AUDITOR'),
        access(subjectId: null, classIds: [classA, classA]),
        access(subjectId: 'not-a-uuid'),
      ]) {
        expect(() => read(raw), invalid, reason: '$raw');
      }
      expect(() => MemberAccessSnapshot.read(access(), kind: 'FAMILY',
          target: target), invalid);
      expect(read(access(subjectId: null, classIds: [classA])).classIds, [classA],
          reason: 'Access facts do not depend on active directory options.');
    });

    test('allows newer GET facts but rejects rollback and same-version drift', () {
      final original = read(access());
      expect(read(access(subjectId: subjectB, version: 10), previous: original)
          .subjectId, subjectB);
      expect(read(access(), previous: original).version, 7);
      expect(() => read(access(version: 6), previous: original), invalid);
      expect(() => read(access(subjectId: subjectB), previous: original), invalid);
    });

    test('checks PATCH scope and the exact resulting version', () {
      final original = read(access());
      final subjectBody = <String, dynamic>{'role': 'TEACHER', 'subjectId': subjectB};
      expect(() => original.verifyUpdate(access(version: 8), body: subjectBody),
          invalid);
      expect(() => original.verifyUpdate(access(subjectId: subjectB, version: 9),
          body: subjectBody), invalid);
      expect(() => original.verifyUpdate(access(subjectId: subjectB),
          body: subjectBody), invalid);
      expect(() => original.verifyUpdate(access(subjectId: null,
          classIds: [classA, classC], version: 8),
          body: {'role': 'TEACHER', 'classIds': [classA, classB]}), invalid);
      expect(() => original.verifyUpdate(access(role: 'CHILD', version: 8),
          body: {'role': 'CHILD', 'subjectId': subjectA}), invalid);
      expect(() => original.verifyUpdate(access(role: 'OWNER', subjectId: null,
          version: 8), body: {'role': 'OWNER'}), invalid);
      expect(original.verifyUpdate(access(subjectId: subjectB, version: 8),
          body: subjectBody).subjectId, subjectB);
    });

    test('uses set semantics for class no-ops and defaults cleared scope', () {
      final original = read(access(subjectId: null, classIds: [classB, classA]));
      final body = <String, dynamic>{'role': 'TEACHER', 'classIds': [classA, classB]};
      expect(original.verifyUpdate(access(subjectId: null,
          classIds: [classB, classA]), body: body).version, 7);
      expect(() => original.verifyUpdate(access(subjectId: null,
          classIds: [classA, classB], version: 8), body: body), invalid);
      expect(() => original.verifyUpdate(access(subjectId: null,
          classIds: [classA, classB]),
          body: {'role': 'TEACHER', 'classIds': [classA, classA]}), invalid);
      final updated = original.verifyUpdate(access(role: 'AUDITOR',
          subjectId: null, version: 8), body: {'role': 'AUDITOR'});
      expect(updated.toJson(), {
        'actorId': actor, 'memberKey': key, 'role': 'AUDITOR',
        'subjectId': null, 'version': 8, 'classIds': <String>[],
      });
    });
  });
  testWidgets('class-scoped member selects multiple classes without a subject',
      (tester) async {
    Json? sent;
    await open(tester, (body) async {
      sent = body;
      return body;
    }, member: {
      'actorId': 'teacher',
      'role': 'TEACHER',
      'subjectId': null,
      'classIds': ['c1'],
      'version': 0
    });
    await tester.ensureVisible(find.text('七年级二班'));
    await tester.tap(find.text('七年级二班'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存权限'));
    await tester.pumpAndSettle();
    expect(sent, {
      'role': 'TEACHER',
      'classIds': ['c1', 'c2']
    });
  });
  testWidgets(
      'new invitations default to read-only access instead of administrator',
      (tester) async {
    await open(tester, (body) async => body);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byKey(const Key('member-role')))
            .initialValue,
        'AUDITOR');
  });
  test('role options enforce workspace, operator and age classification', () {
    expect(memberRoles('FAMILY', 'OWNER'), ['GUARDIAN', 'AUDITOR', 'CHILD']);
    expect(memberRoles('ORGANIZATION', 'ORG_ADMIN'),
        ['TEACHER', 'AUDITOR', 'CHILD']);
    expect(
        memberRoles('ORGANIZATION', 'OWNER', currentRole: 'CHILD'), ['CHILD']);
    expect(memberRoles('ORGANIZATION', 'OWNER', currentRole: 'TEACHER'),
        ['ORG_ADMIN', 'TEACHER', 'AUDITOR']);
    expect(memberRoles('FAMILY', 'OWNER', currentRole: 'OWNER'), isEmpty);
  });
  testWidgets('teacher invitation requires explicit scope and sends it',
      (tester) async {
    Json? sent;
    await open(tester, (body) async {
      sent = body;
      return body;
    });
    await tester.enterText(
        find.byKey(const Key('member-email')), 'teacher@example.test');
    await tester.tap(find.byKey(const Key('member-role')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('教师').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('member-scope-mode')));
    await tester.tap(find.byKey(const Key('member-scope-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单个档案').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建邀请'));
    await tester.pumpAndSettle();
    expect(sent, isNull);
    expect(find.text('请选择关联档案'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('member-subject')));
    await tester.tap(find.byKey(const Key('member-subject')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小明').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建邀请'));
    await tester.pumpAndSettle();
    expect(sent, {
      'recipientEmail': 'teacher@example.test',
      'role': 'TEACHER',
      'subjectId': 'a'
    });
  });
  testWidgets('unknown member edits keep immutable input through a later authentication rejection',
      (tester) async {
    final sent = <Json>[];
    var authentications = 0;
    await open(tester, (body) async {
      sent.add(body);
      if (sent.length == 1) throw const ApiFailure(503, 'REQUEST_FAILED');
      if (sent.length == 2) throw const ApiFailure(401, 'MFA_REQUIRED');
      return body;
    }, reauth: () { authentications++; }, member: {
      'actorId': 'teacher', 'displayName': '林老师', 'role': 'TEACHER',
      'subjectId': null, 'classIds': ['c1'], 'version': 0,
    });
    await tester.ensureVisible(find.text('七年级二班'));
    final originalToggle = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, '七年级二班')).onChanged!;
    await tester.tap(find.text('七年级二班'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存权限'));
    await tester.pumpAndSettle();
    expect(() => sent.first['role'] = 'AUDITOR', throwsUnsupportedError);
    expect(() => (sent.first['classIds'] as List).add('c3'), throwsUnsupportedError);
    originalToggle(false);
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(2));
    expect(tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('member-role'))).onChanged, isNull);
    originalToggle(false);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, '七年级二班')).value, isTrue);
    await tester.ensureVisible(find.text('重新安全验证'));
    await tester.tap(find.text('重新安全验证'));
    await tester.pumpAndSettle();
    expect(authentications, 1);
    expect(sent, hasLength(2));
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(sent, List.filled(3, {'role': 'TEACHER', 'classIds': ['c1', 'c2']}));
    expect(find.byType(MemberEditor), findsNothing);
  });
  testWidgets('uncertain invitations require an explicit review close without replay',
      (tester) async {
    var attempts = 0;
    Json? result;
    await open(tester, (_) async {
      attempts++;
      throw const ApiFailure(0, 'NETWORK_ERROR');
    }, retryUncertain: false, onResult: (value) { result = value; });
    await tester.enterText(
        find.byKey(const Key('member-email')), 'person@example.test');
    await tester.tap(find.text('创建邀请'));
    await tester.pumpAndSettle();
    expect(find.text('查看邀请记录'), findsOneWidget);
    expect(find.text('重试原提交'), findsNothing);
    await tester.tap(find.text('查看邀请记录'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('member-editor-unknown-close-notice')), findsOneWidget);
    expect(find.byType(MemberEditor), findsOneWidget);
    expect(result, isNull);
    final staleClose = tester.widget<ButtonStyleButton>(find.ancestor(
        of: find.text('关闭并核对记录'),
        matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton))).onPressed!;
    await tester.ensureVisible(find.text('继续核对原提交'));
    await tester.tap(find.text('继续核对原提交'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('member-editor-unknown-close-notice')), findsNothing);
    staleClose();
    await tester.pumpAndSettle();
    expect(find.byType(MemberEditor), findsOneWidget);
    expect(result, isNull);
    await tester.tap(find.text('查看邀请记录'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关闭并核对记录'));
    await tester.tap(find.text('关闭并核对记录'));
    await tester.pumpAndSettle();
    expect(result, {'reviewInvitations': true});
    expect(attempts, 1);
    expect(find.byType(MemberEditor), findsNothing);
  });

  testWidgets('conflicts and unavailable results stop the original member request with a readable draft',
      (tester) async {
    for (final terminal in const [
      ApiFailure(412, 'PRECONDITION_FAILED'),
      ApiFailure(409, 'IDEMPOTENCY_KEY_EXPIRED'),
      ApiFailure(410, 'IDEMPOTENCY_RESPONSE_ERASED'),
    ]) {
      var attempts = 0;
      Json? result;
      await open(tester, (_) async {
        attempts++;
        if (attempts == 1) throw const ApiFailure(503, 'REQUEST_FAILED');
        throw terminal;
      }, member: {
        'actorId': 'teacher', 'displayName': '林老师', 'role': 'TEACHER',
        'subjectId': null, 'classIds': ['c1'], 'version': 0,
      }, onResult: (value) { result = value; });
      await tester.ensureVisible(find.text('七年级二班'));
      await tester.tap(find.text('七年级二班'));
      await tester.pumpAndSettle();
      final originalSave = tester.widget<ButtonStyleButton>(
          find.byKey(const Key('member-editor-save'))).onPressed!;
      originalSave();
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试原提交'));
      await tester.pumpAndSettle();
      final draft = tester.widget<SelectableText>(
          find.byKey(const Key('member-editor-recovery-draft'))).data!;
      for (final expected in ['教师', '七年级一班', '编号：c1', '七年级二班', '编号：c2']) {
        expect(draft, contains(expected));
      }
      final failure = tester.widget<FailureView>(find.byType(FailureView)).error as ApiFailure;
      expect(failure.status, terminal.status);
      expect(failure.code, terminal.code);
      expect(find.text('重试原提交'), findsNothing);
      originalSave();
      await tester.pumpAndSettle();
      expect(attempts, 2);
      await tester.tap(find.byKey(const Key('member-editor-close')));
      await tester.pumpAndSettle();
      expect(result, {'refresh': true});
      expect(find.byType(MemberEditor), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
