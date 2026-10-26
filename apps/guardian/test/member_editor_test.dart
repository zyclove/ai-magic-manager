import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/member_access.dart';
import 'package:guardian/ui/member_editor.dart';
import 'package:guardian/ui/design.dart';

Future<void> open(WidgetTester tester, Future<Json> Function(Json) submit,
    {Json? member, bool retryUncertain = true,
    VoidCallback? reauth, void Function(Json?)? onResult}) async {
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
                            subjects: const {'a': '小明', 'b': '小雨'},
                            classes: const {'c1': '七年级一班', 'c2': '七年级二班'},
                            member: member,
                            onSubmit: submit,
                            retryUncertain: retryUncertain,
                            reauth: reauth,
                          ));
                    onResult?.call(result);
                  },
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
