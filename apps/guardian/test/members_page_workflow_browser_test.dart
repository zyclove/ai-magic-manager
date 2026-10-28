@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/members_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/member_editor.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;

import 'device_management_entry_test.dart' show EntrySession, settleReads, tenantId;

const _root = '/api/v1/tenants/$tenantId';
const _members = '$_root/members';
const _invitations = '$_root/invitations';
const _actor = '91111111-1111-4111-8111-111111111111';
const _memberKey = 'cdae61d9d11dab69a7e498ec778e0a4392e5b8090e8553044d4b0d803c808712';
const _secondActor = '93333333-3333-4333-8333-333333333333';
const _secondKey = '0ee5bbe2a599732829551114f7f0728e204f3c0489c02319a5de6d8b0f50ee38';
const _class = '95555555-5555-4555-8555-555555555555';
const _invitation = '96666666-6666-4666-8666-666666666666';

Json _access({bool second = false}) => {
      'actorId': second ? _secondActor : _actor,
      'memberKey': second ? _secondKey : _memberKey,
      'role': second ? 'TEACHER' : 'AUDITOR',
      'subjectId': null,
      'classIds': second ? [_class] : <String>[],
      'version': 7,
    };

Json _member({bool second = false}) => {
      ..._access(second: second),
      'cursor': second ? _secondKey : _memberKey,
      'displayName': second ? '陈老师' : '林老师',
      'verifiedEmail': second ? 'chen@fixture.invalid' : 'lin@fixture.invalid',
      'profileUpdatedAt': '2026-10-26T00:00:00Z',
    };

http.Response _reply(Object? body, {int status = 200}) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

http.Response _page(List<Json> rows, {String? cursor}) =>
    _reply({'items': rows, 'nextCursor': cursor});

class _MemberSession extends EntrySession {
  _MemberSession(super.handler) {
    tenant = {...tenant!, 'name': '测试机构', 'kind': 'ORGANIZATION'};
  }
  @override
  void login({bool stepUp = false}) {}
  @override
  void account() {}
  @override
  void logout() {}
}

class _Fixture {
  final bool unknownRemoval;
  final Map<int, Json> accessOverrides;
  final Json patchOverride;
  final requests = <http.Request>[];
  final classes = Completer<http.Response>();
  bool invitationCancelled = false;
  late final session = _MemberSession(handle);

  _Fixture({this.unknownRemoval = false,
      this.accessOverrides = const {}, this.patchOverride = const {}});

  List<http.Request> reads(String path) => requests.where(
      (request) => request.method == 'GET' && request.url.path == path).toList();
  List<http.Request> get writes =>
      requests.where((request) => request.method != 'GET').toList();

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET') {
      if (path == _members) {
        return request.url.queryParameters['cursor'] == null
            ? _page([_member()], cursor: _memberKey)
            : _page([_member(second: true)]);
      }
      if (path == '$_members/$_memberKey/access') {
        return _reply({..._access(), ...?accessOverrides[reads(path).length]});
      }
      if (path == '$_members/$_secondKey/access') {
        return _reply(_access(second: true));
      }
      if (path == '$_members/$_memberKey/access-history') {
        return _page([{
          'id': '97777777-7777-4777-8777-777777777777',
          'memberVersion': 7, 'previousRole': 'TEACHER', 'role': 'AUDITOR',
          'previousSubjectId': null, 'previousClassIds': <String>[],
          'subjectId': null, 'classIds': <String>[],
          'changedByActorId': 'adult-a', 'occurredAt': '2026-10-25T00:00:00Z',
        }]);
      }
      if (path == '$_root/classes') {
        expect(request.url.queryParameters['includeArchived'], 'true');
        return classes.future;
      }
      if (path == _invitations) {
        return _page([{
          'id': _invitation, 'role': 'TEACHER', 'subjectId': null,
          'classIds': <String>[],
          'state': invitationCancelled ? 'CANCELLED' : 'PENDING',
          'expiresAt': '2030-01-01T00:00:00Z',
        }]);
      }
    }
    if (request.method == 'PATCH' && path == '$_members/$_memberKey/access') {
      return _reply({..._access(), ...(jsonDecode(request.body) as Json),
        'version': 8, ...patchOverride});
    }
    if (request.method == 'DELETE' && path == '$_invitations/$_invitation') {
      invitationCancelled = true;
      return http.Response('', 204);
    }
    if (request.method == 'DELETE' && path == '$_members/$_memberKey/access') {
      if (unknownRemoval) {
        return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
      }
      return http.Response('', 204);
    }
    throw StateError('Unexpected member workflow request: ${request.method} $path');
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    if (!classes.isCompleted) classes.complete(_page([]));
    await settleReads(tester);
    session.transport.close();
    session.dispose();
  }
}

Widget _host(_Fixture fixture, {Key? pageKey, Future<bool> Function()? invite}) => MaterialApp(
    theme: consoleTheme(), home: Scaffold(body: SingleChildScrollView(
        child: MembersPage(key: pageKey, session: fixture.session,
            invite: ({accessChanges, hasAccess}) async => await invite?.call() ?? false))));

Finder _button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
Finder get _topDialog => find.byType(AlertDialog).last;
Finder _dialogButton(String label) =>
    find.descendant(of: _topDialog, matching: _button(label));
Finder get _confirm => find.descendant(of: _topDialog,
    matching: find.byWidgetPredicate((widget) => widget is FilledButton));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 24 && !ready(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: 'The bounded member workflow step must finish.');
}

bool _routeReady(WidgetTester tester, Finder content) {
  if (content.evaluate().length != 1) return false;
  final route = ModalRoute.of(tester.element(content));
  return route?.isCurrent == true &&
      route?.animation?.status == AnimationStatus.completed;
}

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('member access and update receipts stay bound to the selected member',
      (tester) async {
    _wide(tester);
    final invalidResponse = find.byWidgetPredicate((widget) =>
        widget is FailureView && widget.error is ApiFailure &&
        (widget.error as ApiFailure).code == 'INVALID_MEMBER_ACCESS_RESPONSE');
    for (final scenario in <({String name, int? rejectRead,
        Json overrides, bool succeeds})>[
      (name: 'initial actor mismatch', rejectRead: 1,
        overrides: {'actorId': _secondActor}, succeeds: false),
      (name: 'initial member key mismatch', rejectRead: 1,
        overrides: {'memberKey': _secondKey}, succeeds: false),
      (name: 'identity drift before editing', rejectRead: 2,
        overrides: {'actorId': _secondActor}, succeeds: false),
      (name: 'update subject mismatch', rejectRead: null,
        overrides: {'subjectId': _class}, succeeds: false),
      (name: 'update classes mismatch', rejectRead: null,
        overrides: {'classIds': [_class]}, succeeds: false),
      (name: 'update version skips a revision', rejectRead: null,
        overrides: {'version': 10}, succeeds: false),
      (name: 'matching update receipt', rejectRead: null,
        overrides: {}, succeeds: true),
    ]) {
      final rejectRead = scenario.rejectRead;
      final fixture = _Fixture(
          accessOverrides: {if (rejectRead != null) rejectRead: scenario.overrides},
          patchOverride: rejectRead == null ? scenario.overrides : const {});
      try {
        await tester.pumpWidget(_host(fixture));
        await _until(tester, () => find.text('林老师').evaluate().length == 1);
        await _tap(tester, find.text('林老师'));
        if (rejectRead == 1) {
          await _until(tester, () => invalidResponse.evaluate().length == 1);
          expect(find.text('成员详情'), findsNothing, reason: scenario.name);
        } else {
          await _until(tester, () => _routeReady(tester, find.text('成员详情')));
          await _tap(tester, _dialogButton('调整权限'));
          if (rejectRead == 2) {
            await _until(tester, () => invalidResponse.evaluate().length == 1);
          } else {
            await _until(tester, () => _routeReady(tester, find.byType(MemberEditor)));
            await _tap(tester, find.byKey(const Key('member-role')));
            await _until(tester, () => _routeReady(tester, find.text('机构管理员').hitTestable()));
            await _tap(tester, find.text('机构管理员').last);
            final save = find.byKey(const Key('member-editor-save'));
            await _until(tester, () => find.text('机构管理员').evaluate().length == 1 &&
                tester.widget<FilledButton>(save).onPressed != null);
            await _tap(tester, save);
            if (scenario.succeeds) {
              await _until(tester, () => find.text('成员权限已更新。').evaluate().length == 1 &&
                  fixture.reads(_members).length == 2);
              expect(find.byType(MemberEditor), findsNothing);
              expect(fixture.reads(_members), hasLength(2));
            } else {
              await _until(tester, () => invalidResponse.evaluate().length == 1);
              expect(find.byType(MemberEditor), findsOneWidget, reason: scenario.name);
              expect(tester.widget<DropdownButtonFormField<String>>(
                  find.byKey(const Key('member-role'))).onChanged, isNull,
                  reason: 'An unverified update keeps the original input locked.');
              expect(find.text('重试原提交'), findsOneWidget);
              expect(find.text('成员权限已更新。'), findsNothing);
              expect(fixture.reads(_members), hasLength(1));
            }
            expect(fixture.writes, hasLength(1), reason: scenario.name);
            final patch = fixture.writes.single;
            expect(patch.method, 'PATCH');
            expect(patch.url.path, '$_members/$_memberKey/access');
            expect(patch.headers['if-match'], '"7"');
            expect(patch.headers['idempotency-key'], isNotEmpty);
            expect(jsonDecode(patch.body), {'role': 'ORG_ADMIN'});
          }
        }
        if (rejectRead != null) {
          expect(fixture.reads('$_members/$_memberKey/access'), hasLength(rejectRead));
          expect(find.byType(MemberEditor), findsNothing, reason: scenario.name);
          expect(find.text('调整权限'), findsNothing);
          expect(fixture.writes, isEmpty, reason: scenario.name);
          expect(fixture.reads(_members), hasLength(1));
        } else {
          expect(fixture.reads('$_members/$_memberKey/access'), hasLength(2));
        }
        expect(fixture.reads('$_root/classes'), isEmpty);
        expect(tester.takeException(), isNull, reason: scenario.name);
      } finally {
        await fixture.cleanup(tester);
      }
    }
  });

  testWidgets('an observed newer access version reconciles the member list',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture(accessOverrides: {1: {'version': 8}});
    addTearDown(() => fixture.cleanup(tester));
    await tester.pumpWidget(_host(fixture));
    await settleReads(tester);
    await _tap(tester, find.text('林老师'));
    await _until(tester, () => _routeReady(tester, find.text('成员详情')));
    expect(fixture.reads(_members), hasLength(1));
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => fixture.reads(_members).length == 2 &&
        find.byType(AlertDialog).evaluate().isEmpty);
    expect(fixture.writes, isEmpty);
    expect(find.byType(MemberEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invite review signals retain cancelled lists and open invitations once',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture();
    addTearDown(() => fixture.cleanup(tester));
    final results = List.generate(3, (_) => Completer<bool>());
    addTearDown(() {
      for (final result in results) {
        if (!result.isCompleted) result.complete(false);
      }
    });
    var invites = 0;
    await tester.pumpWidget(_host(fixture,
        invite: () => results[invites++].future));
    await settleReads(tester);
    await _tap(tester, _button('加载更多'));
    await settleReads(tester);
    final search = find.byType(TextField);
    await tester.enterText(search, '老师');
    await tester.pump();
    final filter = find.byWidgetPredicate((widget) => widget is SegmentedButton<bool>);
    final oldFilter = tester.widget<SegmentedButton<bool>>(filter).onSelectionChanged!;
    await _tap(tester, _button('邀请成员'));
    await tester.pump();
    expect(invites, 1);
    expect(tester.widget<SegmentedButton<bool>>(filter).onSelectionChanged, isNull);
    oldFilter({true});
    await tester.pump();
    expect(fixture.reads(_invitations), isEmpty);
    results[0].complete(false);
    await _until(tester,
        () => tester.widget<ButtonStyleButton>(_button('邀请成员')).onPressed != null);
    expect(fixture.reads(_members), hasLength(2));
    expect(tester.widget<TextField>(search).controller!.text, '老师');
    expect(find.text('陈老师'), findsOneWidget);
    await _tap(tester, _button('邀请成员'));
    await tester.pump();
    expect(invites, 2);
    results[1].complete(true);
    await _until(tester, () => fixture.reads(_invitations).length == 1 &&
        tester.widget<ButtonStyleButton>(_button('邀请成员')).onPressed != null);
    expect(fixture.reads(_members), hasLength(2),
        reason: 'Opening invitations must not first refresh the retired member list.');
    expect(tester.widget<SegmentedButton<bool>>(filter).selected, {true});
    oldFilter({false});
    await tester.pump();
    expect(tester.widget<SegmentedButton<bool>>(filter).selected, {true});
    await tester.enterText(search, _invitation);
    await tester.pump();
    await _tap(tester, _button('邀请成员'));
    await tester.pump();
    expect(invites, 3);
    results[2].complete(false);
    await _until(tester,
        () => tester.widget<ButtonStyleButton>(_button('邀请成员')).onPressed != null);
    expect(tester.widget<TextField>(search).controller!.text, _invitation);
    expect(fixture.reads(_invitations), hasLength(1));
    expect(fixture.reads(_members), hasLength(2));
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('member read-only subflows keep loaded pages and invitation cancellation refreshes',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture();
    addTearDown(() => fixture.cleanup(tester));
    await tester.pumpWidget(_host(fixture));
    await settleReads(tester);
    await _tap(tester, _button('加载更多'));
    await settleReads(tester);
    expect(fixture.reads(_members), hasLength(2));
    expect(fixture.reads(_members).last.url.queryParameters['cursor'], _memberKey);
    final search = find.byType(TextField);
    await tester.enterText(search, '老师');
    await tester.pump();
    await _tap(tester, find.text('林老师'));
    await settleReads(tester);
    expect(fixture.reads('$_root/classes'), isEmpty);
    await _tap(tester, _dialogButton('权限变更记录'));
    await settleReads(tester);
    expect(fixture.reads('$_members/$_memberKey/access-history'), hasLength(1));
    await _tap(tester, _dialogButton('查看详情'));
    await settleReads(tester);
    expect(find.text('权限变更详情'), findsOneWidget);
    await _tap(tester, _dialogButton('关闭'));
    await settleReads(tester);
    expect(fixture.reads('$_members/$_memberKey/access-history'), hasLength(1));
    await _tap(tester, _dialogButton('关闭'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('关闭'));
    await settleReads(tester);
    expect(fixture.reads(_members), hasLength(2));
    expect(tester.widget<TextField>(search).controller!.text, '老师');
    expect(find.text('陈老师'), findsOneWidget);

    await _tap(tester, find.text('陈老师'));
    await _until(tester, () => fixture.reads('$_root/classes').length == 1 &&
        find.text('成员详情').evaluate().length == 1);
    expect(find.text('班级编号：$_class'), findsOneWidget);
    expect(find.text('正在读取班级名称；成员资料已可查看。'), findsOneWidget);
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
    fixture.classes.complete(_page([{'id': _class, 'name': '迟到班级资料', 'state': 'ACTIVE'}]));
    await settleReads(tester);
    expect(find.textContaining('迟到班级资料'), findsNothing);
    expect(fixture.reads(_members), hasLength(2));
    expect(tester.widget<TextField>(search).controller!.text, '老师');

    await _tap(tester, find.text('邀请记录'));
    await settleReads(tester);
    await _tap(tester, _button('查看详情'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('取消邀请'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('取消'));
    await settleReads(tester);
    expect(fixture.writes, isEmpty);
    await _tap(tester, _dialogButton('关闭'));
    await settleReads(tester);
    expect(fixture.reads(_invitations), hasLength(1));
    await _tap(tester, _button('查看详情'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('取消邀请'));
    await settleReads(tester);
    await _tap(tester, _confirm);
    await settleReads(tester);
    expect(fixture.writes, hasLength(1));
    expect(fixture.writes.single.method, 'DELETE');
    expect(fixture.writes.single.url.path, '$_invitations/$_invitation');
    expect(fixture.reads(_invitations), hasLength(2));
    expect(fixture.reads(_members), hasLength(2));
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('member removal confirmation retires under a cover and unknown DELETE only refreshes',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture(unknownRemoval: true);
    addTearDown(() => fixture.cleanup(tester));
    await tester.pumpWidget(_host(fixture));
    await settleReads(tester);
    await _tap(tester, find.text('林老师'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('撤销访问'));
    await settleReads(tester);
    final text = tester.widgetList<Text>(find.descendant(
        of: _topDialog, matching: find.byType(Text)))
        .map((widget) => widget.data ?? '').join('\n');
    for (final expected in ['林老师', _actor, _memberKey, '7', '邀请', '临时', '预览']) {
      expect(text, contains(expected));
    }
    final heldConfirm = tester.widget<FilledButton>(_confirm).onPressed!;
    final confirmation = ModalRoute.of(tester.element(_confirm))!
        as OwnedDialogRoute<bool>;
    final dialogContext = tester.element(_topDialog);
    unawaited(showDialog<void>(context: dialogContext, builder: (context) => AlertDialog(
        title: const Text('独立覆盖通知'), actions: [TextButton(
            onPressed: () => Navigator.of(context).pop(), child: const Text('知道了'))])));
    await settleReads(tester);
    final generation = fixture.session.scopeGeneration;
    // Retire during an actual build without any Session notification. The
    // unrelated notification must survive removal of the covered confirmation.
    await tester.pumpWidget(_host(fixture,
        pageKey: const ValueKey('retired-under-cover')));
    await settleReads(tester);
    expect(fixture.session.scopeGeneration, generation);
    expect(confirmation.available, isFalse);
    expect(find.text('独立覆盖通知'), findsOneWidget);
    heldConfirm();
    await settleReads(tester);
    expect(fixture.writes, isEmpty);
    expect(find.text('独立覆盖通知'), findsOneWidget);
    await _tap(tester, _dialogButton('知道了'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('关闭'));
    await settleReads(tester);

    await tester.pumpWidget(_host(fixture, pageKey: const ValueKey('fresh-members')));
    await settleReads(tester);
    await _tap(tester, find.text('林老师'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('撤销访问'));
    await settleReads(tester);
    final before = fixture.reads(_members).length;
    await _tap(tester, _confirm);
    await settleReads(tester);
    expect(fixture.writes, hasLength(1));
    final removal = fixture.writes.single;
    expect(removal.method, 'DELETE');
    expect(removal.url.path, '$_members/$_memberKey/access');
    expect(removal.headers['if-match'], '"7"');
    expect(removal.headers['idempotency-key'], isNotEmpty);
    expect(fixture.reads(_members), hasLength(before));
    await _tap(tester, _dialogButton('关闭'));
    await settleReads(tester);
    expect(fixture.reads(_members), hasLength(before + 1));
    expect(fixture.writes, hasLength(1), reason: 'Closing an unknown removal never replays DELETE.');
    expect(fixture.requests.every((request) =>
        request.method == 'GET' || identical(request, removal)), isTrue);
    expect(tester.takeException(), isNull);
  });
}
