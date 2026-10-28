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
  final String? historyCursor;
  final FutureOr<http.Response?> Function(http.Request)? responseOverride;
  final requests = <http.Request>[];
  final classes = Completer<http.Response>();
  bool invitationCancelled = false;
  late final session = _MemberSession(handle);

  _Fixture({this.unknownRemoval = false,
      this.accessOverrides = const {}, this.patchOverride = const {},
      this.responseOverride, this.historyCursor});

  List<http.Request> reads(String path) => requests.where(
      (request) => request.method == 'GET' && request.url.path == path).toList();
  List<http.Request> get writes =>
      requests.where((request) => request.method != 'GET').toList();

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final response = await responseOverride?.call(request);
    if (response != null) return response;
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
        }], cursor: historyCursor);
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
Finder get _refresh => find.byWidgetPredicate((widget) =>
    widget is IconButton && widget.tooltip == '刷新');
Finder _failure(String code) => find.byWidgetPredicate((widget) =>
    widget is FailureView && widget.error is ApiFailure &&
    (widget.error as ApiFailure).code == code);
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

bool _listReady(WidgetTester tester) => _refresh.evaluate().length == 1 &&
    tester.widget<IconButton>(_refresh).onPressed != null;

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
          expect(find.text('调整权限'), rejectRead == 1 ? findsNothing : findsOneWidget);
          if (rejectRead == 2) {
            expect(_routeReady(tester, find.text('成员详情')), isTrue);
          }
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

  testWidgets('member edit preparation retries in the same detail and pins the latest version',
      (tester) async {
    _wide(tester);
    final preparation = Completer<http.Response>();
    late final _Fixture fixture;
    fixture = _Fixture(responseOverride: (request) {
      if (request.method == 'GET' && request.url.path == '$_members/$_memberKey/access') {
        final count = fixture.reads(request.url.path).length;
        if (count == 2) return preparation.future;
        if (count == 3) return _reply({..._access(), 'version': 8});
      }
      if (request.method == 'PATCH') {
        return _reply({..._access(), ...(jsonDecode(request.body) as Json), 'version': 9});
      }
      return null;
    });
    addTearDown(() async {
      if (!preparation.isCompleted) preparation.complete(_reply(_access()));
      await fixture.cleanup(tester);
    });
    await tester.pumpWidget(_host(fixture));
    await _until(tester, () => find.text('林老师').evaluate().length == 1);
    await _tap(tester, find.text('林老师'));
    await _until(tester, () => _routeReady(tester, find.text('成员详情')));
    final detail = ModalRoute.of(tester.element(find.text('成员详情')));
    final heldAdjust = tester.widget<ButtonStyleButton>(_dialogButton('调整权限')).onPressed!;
    await _tap(tester, _dialogButton('调整权限'));
    await _until(tester, () => fixture.reads('$_members/$_memberKey/access').length == 2);
    heldAdjust();
    heldAdjust();
    await tester.pump();
    expect(fixture.reads('$_members/$_memberKey/access'), hasLength(2));
    expect(find.byType(MemberEditor), findsNothing);
    expect(fixture.reads(_members), hasLength(1));

    preparation.complete(_reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503));
    await _until(tester, () => _failure('SERVICE_UNAVAILABLE').evaluate().length == 1 &&
        tester.widget<ButtonStyleButton>(_dialogButton('调整权限')).onPressed != null);
    expect(ModalRoute.of(tester.element(find.text('成员详情'))), same(detail));
    expect(detail?.isCurrent, isTrue);
    expect(fixture.reads(_members), hasLength(1));
    await _tap(tester, _dialogButton('调整权限'));
    await _until(tester, () => _routeReady(tester, find.byType(MemberEditor)));
    expect(find.text('成员详情'), findsNothing);
    expect(_failure('SERVICE_UNAVAILABLE'), findsNothing);
    heldAdjust();
    await tester.pump();
    expect(fixture.reads('$_members/$_memberKey/access'), hasLength(3));
    await _tap(tester, find.byKey(const Key('member-role')));
    await _until(tester, () => _routeReady(tester, find.text('机构管理员').hitTestable()));
    await _tap(tester, find.text('机构管理员').last);
    final save = find.byKey(const Key('member-editor-save'));
    await _until(tester, () => find.text('机构管理员').evaluate().length == 1 &&
        tester.widget<FilledButton>(save).onPressed != null);
    await _tap(tester, save);
    await _until(tester, () => find.byType(MemberEditor).evaluate().isEmpty &&
        fixture.reads(_members).length == 2 && _listReady(tester));
    expect(fixture.writes, hasLength(1));
    expect(fixture.writes.single.method, 'PATCH');
    expect(fixture.writes.single.headers['if-match'], '"8"');
    expect(jsonDecode(fixture.writes.single.body), {'role': 'ORG_ADMIN'});
    expect(fixture.reads('$_members/$_memberKey/access'), hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retired member edit preparation cannot open an editor or retire a later cover',
      (tester) async {
    _wide(tester);
    for (final status in [200, 403]) {
      final preparation = Completer<http.Response>();
      late final _Fixture fixture;
      fixture = _Fixture(responseOverride: (request) {
        if (request.method == 'GET' && request.url.path == '$_members/$_memberKey/access' &&
            fixture.reads(request.url.path).length == 2) return preparation.future;
        return null;
      });
      try {
        await tester.pumpWidget(_host(fixture));
        await _until(tester, () => find.text('林老师').evaluate().length == 1);
        await _tap(tester, find.text('林老师'));
        await _until(tester, () => _routeReady(tester, find.text('成员详情')));
        final detailContext = tester.element(find.text('成员详情'));
        final detail = ModalRoute.of(detailContext)! as OwnedDialogRoute<void>;
        final heldAdjust = tester.widget<ButtonStyleButton>(_dialogButton('调整权限')).onPressed!;
        await _tap(tester, _dialogButton('调整权限'));
        await _until(tester, () => fixture.reads('$_members/$_memberKey/access').length == 2);
        unawaited(showDialog<void>(context: detailContext, builder: (context) => AlertDialog(
            title: const Text('独立覆盖通知'), actions: [TextButton(
                onPressed: () => Navigator.of(context).pop(), child: const Text('知道了'))])));
        await _until(tester, () => _routeReady(tester, find.text('独立覆盖通知')));
        var detailCompleted = false;
        unawaited(detail.completed.then<void>((_) {
          detailCompleted = true;
        }));
        detail.navigator!.removeRoute(detail);
        await _until(tester, () => detailCompleted && !detail.available &&
            find.text('成员详情').evaluate().isEmpty);
        preparation.complete(status == 200 ? _reply({..._access(), 'version': 8}) :
            _reply({'errorCode': 'FORBIDDEN'}, status: status));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
        heldAdjust();
        await tester.pump();
        expect(_routeReady(tester, find.text('独立覆盖通知')), isTrue);
        expect(find.text('成员详情'), findsNothing);
        expect(find.byType(MemberEditor), findsNothing);
        expect(fixture.reads(_members), hasLength(1));
        expect(fixture.reads('$_members/$_memberKey/access'), hasLength(2));
        expect(fixture.writes, isEmpty);
        await _tap(tester, _dialogButton('知道了'));
        await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty &&
            _listReady(tester));
        await _tap(tester, find.text('林老师'));
        await _until(tester, () => _routeReady(tester, find.text('成员详情')));
        heldAdjust();
        await tester.pump();
        expect(fixture.reads('$_members/$_memberKey/access'), hasLength(3));
        expect(find.byType(MemberEditor), findsNothing);
        expect(fixture.reads(_members), hasLength(1));
        expect(fixture.writes, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        if (!preparation.isCompleted) preparation.complete(_reply(_access()));
        await fixture.cleanup(tester);
      }
    }
  });

  testWidgets('a denied member continuation retires the page and old callbacks',
      (tester) async {
    _wide(tester);
    var denied = true;
    var invites = 0;
    final fixture = _Fixture(responseOverride: (request) {
      if (denied && request.method == 'GET' && request.url.path == _members &&
          request.url.queryParameters['cursor'] != null) {
        return _reply({'errorCode': 'SCOPE_DENIED'}, status: 403);
      }
      return null;
    });
    addTearDown(() => fixture.cleanup(tester));
    await tester.pumpWidget(_host(fixture, invite: () async {
      invites++;
      return false;
    }));
    await _until(tester, () => find.text('林老师').evaluate().length == 1);
    await tester.enterText(find.byType(TextField), '林老师');
    await tester.pump();
    final oldOpen = tester.widget<ButtonStyleButton>(_button('查看详情')).onPressed!;
    final oldCreate = tester.widget<ButtonStyleButton>(_button('邀请成员')).onPressed!;
    final oldMore = tester.widget<ButtonStyleButton>(_button('加载更多')).onPressed!;
    final oldRefresh = tester.widget<IconButton>(_refresh).onPressed!;
    final oldTab = tester.widget<SegmentedButton<bool>>(find.byWidgetPredicate(
        (widget) => widget is SegmentedButton<bool>)).onSelectionChanged!;
    final generation = fixture.session.scopeGeneration;
    await _tap(tester, _button('加载更多'));
    final retired = find.text('工作空间或权限已变化，请重新打开成员管理。');
    await _until(tester, () => retired.evaluate().length == 1);
    expect(find.text('林老师'), findsNothing);
    expect(find.byType(TextField), findsNothing,
        reason: 'The retired page must also hide its private search draft.');
    denied = false;
    oldTab({true});
    oldOpen();
    oldCreate();
    oldRefresh();
    oldMore();
    await tester.pumpWidget(_host(fixture));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
    expect(retired, findsOneWidget);
    expect(find.text('林老师'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(fixture.reads(_members), hasLength(2));
    expect(fixture.reads(_invitations), isEmpty);
    expect(fixture.reads('$_members/$_memberKey/access'), isEmpty);
    expect(fixture.writes, isEmpty);
    expect(invites, 0);
    expect(fixture.session.scopeGeneration, generation);
    expect(tester.takeException(), isNull);
  });

  testWidgets('target access denial reconciles only that target and reauth keeps the page',
      (tester) async {
    _wide(tester);
    for (final reauth in [false, true]) {
      late final _Fixture fixture;
      fixture = _Fixture(responseOverride: (request) {
        if (request.method != 'GET') return null;
        if (request.url.path == '$_members/$_memberKey/access' &&
            fixture.reads(request.url.path).length == 1) {
          return _reply({'errorCode': reauth ? 'REAUTH_REQUIRED' : 'SCOPE_DENIED'},
              status: reauth ? 401 : 403);
        }
        if (!reauth && request.url.path == _members &&
            fixture.reads(_members).length > 1) {
          return _page([_member(second: true)]);
        }
        return null;
      });
      try {
        await tester.pumpWidget(_host(fixture));
        await _until(tester, () => find.text('林老师').evaluate().length == 1);
        final generation = fixture.session.scopeGeneration;
        await _tap(tester, find.text('林老师'));
        if (reauth) {
          await _until(tester, () => _failure('REAUTH_REQUIRED').evaluate().length == 1);
          expect(find.text('林老师'), findsOneWidget);
          expect(fixture.reads(_members), hasLength(1));
          await _tap(tester, _refresh);
          await _until(tester, () => fixture.reads(_members).length == 2 &&
              _failure('REAUTH_REQUIRED').evaluate().isEmpty);
        } else {
          await _until(tester, () => fixture.reads(_members).length == 2 &&
              find.text('陈老师').evaluate().length == 1);
          expect(find.text('林老师'), findsNothing);
          fixture.classes.complete(_page([]));
        }
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('工作空间或权限已变化，请重新打开成员管理。'), findsNothing);
        expect(fixture.session.scopeGeneration, generation);
        await _tap(tester, find.text(reauth ? '林老师' : '陈老师'));
        await _until(tester, () => _routeReady(tester, find.text('成员详情')));
        expect(tester.widget<ButtonStyleButton>(_dialogButton('调整权限')).onPressed,
            isNotNull, reason: 'A denied target must not lock management of readable members.');
        expect(fixture.reads(_members), hasLength(2));
        expect(fixture.writes, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.cleanup(tester);
      }
    }
  });

  testWidgets('history continuation denial retires three windows beneath an independent notice',
      (tester) async {
    _wide(tester);
    final historyRead = Completer<http.Response>();
    late final _Fixture fixture;
    const cursor = '97777777-7777-4777-8777-777777777777';
    fixture = _Fixture(historyCursor: cursor, responseOverride: (request) {
      if (request.method != 'GET') return null;
      if (request.url.path == '$_members/$_memberKey/access-history' &&
          request.url.queryParameters['cursor'] != null) {
        return historyRead.future;
      }
      if (request.url.path == _members && fixture.reads(_members).length > 1) {
        return _page([_member(second: true)]);
      }
      return null;
    });
    addTearDown(() => fixture.cleanup(tester));
    addTearDown(() {
      if (!historyRead.isCompleted) historyRead.complete(_page([]));
    });
    await tester.pumpWidget(_host(fixture));
    await _until(tester, () => find.text('林老师').evaluate().length == 1);
    await _tap(tester, find.text('林老师'));
    await _until(tester, () => _routeReady(tester, find.text('成员详情')));
    final memberRoute = ModalRoute.of(tester.element(_topDialog))!
        as OwnedDialogRoute<void>;
    await _tap(tester, _dialogButton('权限变更记录'));
    await _until(tester, () =>
        fixture.reads('$_members/$_memberKey/access-history').length == 1 &&
        find.text('v7').evaluate().length == 1 && _routeReady(tester, _topDialog));
    final historyRoute = ModalRoute.of(tester.element(_topDialog))!
        as OwnedDialogRoute<void>;
    await _tap(tester, _dialogButton('加载更多'));
    await _until(tester, () =>
        fixture.reads('$_members/$_memberKey/access-history').length == 2);
    expect(fixture.reads('$_members/$_memberKey/access-history').last
        .url.queryParameters['cursor'], cursor);
    await _tap(tester, _dialogButton('查看详情'));
    await _until(tester, () => _routeReady(tester, find.text('权限变更详情')));
    final historyDetailRoute = ModalRoute.of(tester.element(_topDialog))!
        as OwnedDialogRoute<void>;
    final generation = fixture.session.scopeGeneration;
    unawaited(showDialog<void>(context: tester.element(_topDialog),
        builder: (context) => AlertDialog(title: const Text('独立覆盖通知'),
            actions: [TextButton(onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'))])));
    await _until(tester, () => _routeReady(tester, find.text('独立覆盖通知')));
    historyRead.complete(_reply({'errorCode': 'SCOPE_DENIED'}, status: 403));
    await _until(tester, () => !memberRoute.available && !historyRoute.available &&
        !historyDetailRoute.available && fixture.reads(_members).length == 2 &&
        find.text('陈老师').evaluate().length == 1);
    expect(find.text('独立覆盖通知'), findsOneWidget);
    expect(find.text('成员详情'), findsNothing);
    expect(find.text('权限变更记录'), findsNothing);
    expect(find.text('权限变更详情'), findsNothing);
    expect(find.text('林老师'), findsNothing);
    expect(fixture.session.scopeGeneration, generation);
    expect(fixture.reads('$_members/$_memberKey/access-history'), hasLength(2));
    await _tap(tester, _dialogButton('知道了'));
    await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty &&
        find.text('陈老师').evaluate().length == 1);
    fixture.classes.complete(_page([]));
    await _tap(tester, find.text('陈老师'));
    await _until(tester, () => _routeReady(tester, find.text('成员详情')));
    expect(fixture.reads(_members), hasLength(2));
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a denied DELETE remains an operation failure and does not retire the page',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture(responseOverride: (request) =>
        request.method == 'DELETE' && request.url.path == '$_members/$_memberKey/access'
            ? _reply({'errorCode': 'SCOPE_DENIED'}, status: 403) : null);
    addTearDown(() => fixture.cleanup(tester));
    await tester.pumpWidget(_host(fixture));
    await _until(tester, () => find.text('林老师').evaluate().length == 1);
    await _tap(tester, find.text('林老师'));
    await _until(tester, () => _routeReady(tester, find.text('成员详情')));
    await _tap(tester, _dialogButton('撤销访问'));
    await _until(tester, () => _routeReady(tester, find.text('撤销成员访问')));
    await _tap(tester, _confirm);
    await _until(tester, () => _failure('SCOPE_DENIED').evaluate().length == 1 &&
        _routeReady(tester, find.text('成员详情')));
    expect(find.text('工作空间或权限已变化，请重新打开成员管理。'), findsNothing);
    expect(find.text('成员访问已撤销。'), findsNothing);
    expect(fixture.reads(_members), hasLength(1));
    expect(fixture.writes, hasLength(1));
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => fixture.reads(_members).length == 2 &&
        find.byType(AlertDialog).evaluate().isEmpty && _listReady(tester));
    await _tap(tester, find.text('林老师'));
    await _until(tester, () => _routeReady(tester, find.text('成员详情')));
    expect(tester.widget<ButtonStyleButton>(_dialogButton('调整权限')).onPressed, isNotNull);
    expect(fixture.writes, hasLength(1));
    expect(tester.takeException(), isNull);
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
        find.byType(AlertDialog).evaluate().isEmpty && _listReady(tester));
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
    await _until(tester, () => fixture.reads(_invitations).length == 2 &&
        find.byType(AlertDialog).evaluate().isEmpty && _listReady(tester));
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
    await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
    expect(find.text('成员详情'), findsNothing);

    await tester.pumpWidget(_host(fixture, pageKey: const ValueKey('fresh-members')));
    await settleReads(tester);
    await _tap(tester, find.text('林老师'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('撤销访问'));
    await settleReads(tester);
    final before = fixture.reads(_members).length;
    await _tap(tester, _confirm);
    await _until(tester, () => _failure('SERVICE_UNAVAILABLE').evaluate().length == 1 &&
        _routeReady(tester, find.text('成员详情')));
    expect(fixture.writes, hasLength(1));
    final removal = fixture.writes.single;
    expect(removal.method, 'DELETE');
    expect(removal.url.path, '$_members/$_memberKey/access');
    expect(removal.headers['if-match'], '"7"');
    expect(removal.headers['idempotency-key'], isNotEmpty);
    expect(fixture.reads(_members), hasLength(before));
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => fixture.reads(_members).length == before + 1 &&
        find.byType(AlertDialog).evaluate().isEmpty && _listReady(tester));
    expect(fixture.reads(_members), hasLength(before + 1));
    expect(fixture.writes, hasLength(1), reason: 'Closing an unknown removal never replays DELETE.');
    expect(fixture.requests.every((request) =>
        request.method == 'GET' || identical(request, removal)), isTrue);
    expect(tester.takeException(), isNull);
  });
}
