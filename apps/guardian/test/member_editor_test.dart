import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/member_access.dart';
import 'package:guardian/ui/member_editor.dart';
import 'package:guardian/ui/design.dart';

Future<void> open(WidgetTester tester, Future<Json> Function(Json) submit,
    {Json? member, bool retryUncertain = true}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showDialog<Json>(
                      context: context,
                      builder: (_) => MemberEditor(
                            kind: 'ORGANIZATION',
                            operatorRole: 'OWNER',
                            subjects: const {'a': '小明', 'b': '小雨'},
                            classes: const {'c1': '七年级一班', 'c2': '七年级二班'},
                            member: member,
                            onSubmit: submit,
                            retryUncertain: retryUncertain,
                          )),
                  child: const Text('打开'))))));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  test('class-scoped teachers are never labelled as workspace-wide', () {
    expect(
        memberScope({
          'role': 'TEACHER',
          'classIds': ['c1', 'c2']
        }),
        '2 个班级');
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
  testWidgets(
      'uncertain access edits freeze input and retry the original content',
      (tester) async {
    final sent = <Json>[];
    await open(tester, (body) async {
      sent.add(body);
      if (sent.length == 1) throw const ApiFailure(503, 'REQUEST_FAILED');
      return body;
    }, member: {
      'actorId': 'person',
      'displayName': '林老师',
      'role': 'TEACHER',
      'subjectId': 'a',
      'version': 0
    });
    await tester.tap(find.byKey(const Key('member-role')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('审计员').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存权限'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byKey(const Key('member-role')))
            .onChanged,
        isNull);
    await tester.tap(find.text('重试原提交'));
    await tester.pumpAndSettle();
    expect(sent, [
      {'role': 'AUDITOR'},
      {'role': 'AUDITOR'}
    ]);
  });
  testWidgets(
      'invitation transport uncertainty prevents duplicate token creation',
      (tester) async {
    await open(tester, (_) async => throw const ApiFailure(0, 'NETWORK_ERROR'),
        retryUncertain: false);
    await tester.enterText(
        find.byKey(const Key('member-email')), 'person@example.test');
    await tester.tap(find.text('创建邀请'));
    await tester.pumpAndSettle();
    expect(find.text('查看邀请记录'), findsOneWidget);
    expect(find.text('重试原提交'), findsNothing);
  });
}
